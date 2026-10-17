package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/smtp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// Email alerts to ADMIN_ALERT_EMAIL, through the SMTP server of the stack: what
// happened, collected and sent at most every ALERT_INTERVAL_SECONDS (10 minutes)

// event kinds worth an email. admin: sign-ins to the admin UI and every change made
// in it, so that the other admins (and you, from a stolen session) hear of it.
// blocked: an account of the accounts service locked out by the rate limits
// sign-up burst: more new accounts in an hour than ADMIN_SIGNUP_BURST
// backup: a backup failed or is too old, attention: the thresholds of the overview
// security: a password or a way to sign in of an account changed (securityevents.go)
var alertKinds = map[string]bool{"sign-up refused": true, "health": true, "update": true, "sign-in": true, "admin": true, "blocked": true, "sign-up burst": true,
	"backup": true, "attention": true, "security": true}

const (
	maxAlerts = 200
	// refused sign-ups come from anybody: they cannot push out the other kinds
	maxAlertsPerKind = 20
	maxAlertLine     = 256
	alertTime        = timeLayout
)

// Mailer sends plain text emails through the SMTP server of the stack (SMTP_*)
type Mailer struct {
	from                   string
	host, port, user, pass string
	implicitTLS            bool
	insecureAuth           bool
	rootCAs                *x509.CertPool // nil: the system's (the tests set their own)
}

type Alerter struct {
	Mailer
	to       string
	interval time.Duration

	mu      sync.Mutex
	pending []pendingAlert
	perKind map[string]int // lines of each kind added since the last take
	dropped map[string]int // and those left out, by kind
	taken   []pendingAlert // the batch being sent, for requeue
	tDrops  map[string]int // and its counts
	status  SendStatus
}

type pendingAlert struct{ kind, line string }

// SendStatus is the result of the last alert email, kept in memory: shown on the
// overview and in Prometheus
type SendStatus struct {
	At     time.Time // last attempt, zero: none yet
	Err    string    // its error, "" when it was sent
	LastOK time.Time // last email sent
}

func (al *Alerter) Status() SendStatus {
	al.mu.Lock()
	defer al.mu.Unlock()
	return al.status
}

func (al *Alerter) record(err error) {
	al.mu.Lock()
	defer al.mu.Unlock()
	al.status.At, al.status.Err = time.Now(), ""
	if err != nil {
		al.status.Err = err.Error()
	} else {
		al.status.LastOK = al.status.At
	}
}

// Waiting: alerts not sent yet
func (al *Alerter) Waiting() int {
	al.mu.Lock()
	defer al.mu.Unlock()
	return len(al.pending)
}

// requeue puts back the batch of the last take, which was not sent, before the new
// alerts: it goes out once the SMTP server works again. Of each kind the newest
// maxAlertsPerKind lines wait, at most maxAlerts in all; the rest are counted by kind
func (al *Alerter) requeue() {
	al.mu.Lock()
	defer al.mu.Unlock()
	if al.perKind == nil {
		al.perKind, al.dropped = map[string]int{}, map[string]int{}
	}
	for kind, n := range al.tDrops {
		al.dropped[kind] += n
	}
	all := append(al.taken, al.pending...)
	kept := map[string]int{}
	var keep []pendingAlert
	for i := len(all) - 1; i >= 0; i-- {
		a := all[i]
		if kept[a.kind] >= maxAlertsPerKind || len(keep) >= maxAlerts {
			al.dropped[a.kind]++
			continue
		}
		kept[a.kind]++
		keep = append(keep, a)
	}
	slices.Reverse(keep)
	al.pending, al.taken, al.tDrops = keep, nil, nil
}

// smtpServer: the SMTP server of the stack (SMTP_*), nil without SMTP_HOST. The
// placeholder of .env-example (<REPLACE_WITH_YOUR_SMTP_SERVER>) counts as unset: it
// stays there without self-hosted accounts
func smtpServer() *Mailer {
	host := env("SMTP_HOST", "")
	if host == "" || strings.ContainsAny(host, "<>") {
		return nil
	}
	return &Mailer{
		host: host, port: env("SMTP_PORT", "587"), user: env("SMTP_USER", ""), pass: env("SMTP_PASS", ""),
		implicitTLS:  env("SMTP_SECURE", "false") == "true",
		insecureAuth: env("SMTP_INSECURE_AUTH", "") != "",
	}
}

// newMailer: nil without SMTP_HOST or a sender (SMTP_SENDER, or fallback)
func newMailer(fallback string) *Mailer {
	m, from := smtpServer(), env("SMTP_SENDER", fallback)
	if m == nil || from == "" {
		return nil
	}
	m.from = from
	return m
}

func newAlerter() *Alerter {
	to := env("ALERT_EMAIL", "")
	if to == "" {
		return nil
	}
	m := newMailer("firefox-sync admin <" + to + ">")
	if m == nil {
		return nil
	}
	return &Alerter{Mailer: *m, to: to, interval: time.Duration(envInt("ALERT_INTERVAL_SECONDS", 600)) * time.Second}
}

func (a *App) alert(kind, detail string) {
	if a.alerter != nil {
		a.alerter.add(kind, detail)
	}
}

func (al *Alerter) add(kind, detail string) {
	al.mu.Lock()
	defer al.mu.Unlock()
	if al.perKind == nil {
		al.perKind, al.dropped = map[string]int{}, map[string]int{}
	}
	if al.perKind[kind] >= maxAlertsPerKind || len(al.pending) >= maxAlerts {
		al.dropped[kind]++
		return
	}
	al.perKind[kind]++
	al.pending = append(al.pending, pendingAlert{kind, formatTime(time.Now(), adminZone) + "  " + alertText(kind+": "+detail)})
}

// take empties the batch, with a count of what was left out
func (al *Alerter) take() []string {
	al.mu.Lock()
	defer al.mu.Unlock()
	lines := make([]string, 0, len(al.pending)+len(al.dropped))
	for _, a := range al.pending {
		lines = append(lines, a.line)
	}
	kinds := make([]string, 0, len(al.dropped))
	for kind := range al.dropped {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	for _, kind := range kinds {
		lines = append(lines, fmt.Sprintf("%s  %d more %s", formatTime(time.Now(), adminZone), al.dropped[kind], alertText(kind)))
	}
	al.taken, al.tDrops = al.pending, al.dropped
	al.pending, al.perKind, al.dropped = nil, nil, nil
	return lines
}

// alertText makes one short line of text that may come from anybody (the email of a
// refused sign-up): no line breaks to forge lines or headers with
func alertText(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
	if len(s) > maxAlertLine {
		cut := maxAlertLine
		for cut > 0 && !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut] + "..."
	}
	return s
}

func (al *Alerter) run(ctx context.Context) {
	tick := time.NewTicker(al.interval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		lines := al.take()
		if len(lines) == 0 {
			continue
		}
		err := al.send(lines)
		al.record(err)
		if err != nil {
			log.Printf("alert email: %v", err)
			al.requeue()
		}
	}
}

func (al *Alerter) send(lines []string) error {
	subject := "firefox-sync: " + lines[0][len(alertTime+"  "):]
	if len(lines) > 1 {
		subject = fmt.Sprintf("firefox-sync: %d events", len(lines))
	}
	body := "What happened on your firefox-sync server:\r\n\r\n" + strings.Join(lines, "\r\n") +
		"\r\n\r\nTimes in " + adminZone.String() + ". Details in the admin UI, Activity.\r\n"
	return al.Mailer.send(al.to, alertText(subject), body, time.Minute)
}

// dial connects and gets as far as an email can go without sending one: EHLO, TLS
// (STARTTLS, or TLS from the start with SMTP_SECURE) and AUTH, all within timeout
func (m *Mailer) dial(timeout time.Duration) (*smtp.Client, error) {
	addr := net.JoinHostPort(m.host, m.port)
	var conn net.Conn
	var err error
	dialer := &net.Dialer{Timeout: timeout / 4}
	if m.implicitTLS {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{ServerName: m.host, RootCAs: m.rootCAs})
	} else {
		conn, err = dialer.Dial("tcp", addr)
	}
	if err != nil {
		return nil, err
	}
	conn.SetDeadline(time.Now().Add(timeout))
	c, err := smtp.NewClient(conn, m.host)
	if err != nil {
		conn.Close()
		return nil, err
	}
	if err := c.Hello("localhost"); err != nil {
		c.Close()
		return nil, err
	}
	if !m.implicitTLS {
		if ok, _ := c.Extension("STARTTLS"); ok {
			if err := c.StartTLS(&tls.Config{ServerName: m.host, RootCAs: m.rootCAs}); err != nil {
				c.Close()
				return nil, err
			}
		}
	}
	if m.user != "" {
		_, encrypted := c.TLSConnectionState()
		if !encrypted && !m.insecureAuth {
			c.Close()
			return nil, fmt.Errorf("%s offers no TLS, not sending the password in clear", m.host)
		}
		if err := c.Auth(plainAuth{m.user, m.pass}); err != nil {
			c.Close()
			return nil, err
		}
	}
	return c, nil
}

// check signs in to the SMTP server and leaves, never MAIL: no email is sent
func (m *Mailer) check(timeout time.Duration) error {
	c, err := m.dial(timeout)
	if err != nil {
		return err
	}
	defer c.Close()
	return c.Quit()
}

// send one email to one address, within timeout. to and subject must be one line
func (m *Mailer) send(to, subject, body string, timeout time.Duration) error {
	if strings.ContainsAny(to+subject, "\r\n") {
		return fmt.Errorf("not one line")
	}
	if m.from == "" {
		return fmt.Errorf("no sender (FXA_SMTP_SENDER)")
	}
	msg := "From: " + m.from + "\r\nTo: " + to + "\r\nSubject: " + subject +
		"\r\nDate: " + time.Now().Format(time.RFC1123Z) + "\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + body
	c, err := m.dial(timeout)
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Mail(senderAddress(m.from)); err != nil {
		return err
	}
	if err := c.Rcpt(senderAddress(to)); err != nil {
		return err
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write([]byte(msg)); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	// the server has accepted it: a failed QUIT must not send it again
	if err := c.Quit(); err != nil {
		log.Printf("smtp %s: QUIT after the email was accepted: %v", m.host, err)
	}
	return nil
}

// "Name <a@b>" -> a@b
func senderAddress(from string) string {
	if i := strings.LastIndex(from, "<"); i >= 0 {
		return strings.TrimSuffix(from[i+1:], ">")
	}
	return from
}

// PLAIN without net/smtp's own check: send decides when it is safe
type plainAuth struct{ user, pass string }

func (p plainAuth) Start(*smtp.ServerInfo) (string, []byte, error) {
	return "PLAIN", []byte("\x00" + p.user + "\x00" + p.pass), nil
}

func (p plainAuth) Next([]byte, bool) ([]byte, error) { return nil, nil }

// sendMail sends one plain text email through the SMTP server of the stack
func (a *App) sendMail(to, subject, body string) error {
	if a.mailer == nil {
		return errors.New("no SMTP server (FXA_SMTP_HOST)")
	}
	return a.mailer.send(to, subject, body, 20*time.Second)
}

// testEmail sends one email to ADMIN_ALERT_EMAIL, or without it to the admin signed in
// with single sign-on: never to an address typed in the form
func (a *App) testEmail(w http.ResponseWriter, r *http.Request, s *session) {
	to := ""
	if a.alerter != nil {
		to = a.alerter.to
	} else if s.method == "oidc" {
		to = s.user
	}
	if to == "" {
		a.done(w, r, s, "", errors.New("no address for a test email: set ADMIN_ALERT_EMAIL, or sign in with single sign-on"))
		return
	}
	body := "This is a test email of the admin UI of your firefox-sync server, sent by " + auditWho(s) + " on " +
		formatTime(time.Now(), adminZone) + " (" + adminZone.String() + ").\r\n\r\nAlerts reach you this way.\r\n"
	err := a.sendMail(to, "firefox-sync: test email", body)
	if a.alerter != nil && to == a.alerter.to {
		a.alerter.record(err)
	}
	if err != nil {
		// tried: in the audit trail too, with the SMTP server's answer
		a.done(w, r, s, "Tried a test email to "+oneLine(to, 255), &partialError{fmt.Errorf("the test email to %s was not sent: %w", oneLine(to, 255), err)})
		return
	}
	a.done(w, r, s, "Sent a test email to "+oneLine(to, 255), nil)
}
