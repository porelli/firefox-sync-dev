package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"net"
	"net/smtp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// Email alerts to ADMIN_ALERT_EMAIL, through the SMTP server of the stack: what
// happened, collected and sent at most every ALERT_INTERVAL_SECONDS (10 minutes)

// event kinds worth an email: changes made in the admin UI are not (you made them)
var alertKinds = map[string]bool{"sign-up refused": true, "health": true, "update": true, "sign-in": true}

const (
	maxAlerts = 200
	// refused sign-ups come from anybody: they cannot push out the other kinds
	maxAlertsPerKind = 20
	maxAlertLine     = 256
	alertTime        = "2006-01-02 15:04"
)

type Alerter struct {
	to, from               string
	host, port, user, pass string
	implicitTLS            bool
	insecureAuth           bool
	interval               time.Duration
	rootCAs                *x509.CertPool // nil: the system's (the tests set their own)

	mu      sync.Mutex
	pending []string
	perKind map[string]int // lines of each kind in pending
	dropped map[string]int // and those left out
}

func newAlerter() *Alerter {
	to := env("ALERT_EMAIL", "")
	host := env("SMTP_HOST", "")
	if to == "" || host == "" {
		return nil
	}
	return &Alerter{
		to: to, from: env("SMTP_SENDER", "firefox-sync admin <"+to+">"),
		host: host, port: env("SMTP_PORT", "587"), user: env("SMTP_USER", ""), pass: env("SMTP_PASS", ""),
		implicitTLS:  env("SMTP_SECURE", "false") == "true",
		insecureAuth: env("SMTP_INSECURE_AUTH", "") != "",
		interval:     time.Duration(envInt("ALERT_INTERVAL_SECONDS", 600)) * time.Second,
	}
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
	al.pending = append(al.pending, time.Now().UTC().Format(alertTime)+"  "+alertText(kind+": "+detail))
}

// take empties the batch, with a count of what was left out
func (al *Alerter) take() []string {
	al.mu.Lock()
	defer al.mu.Unlock()
	lines := al.pending
	kinds := make([]string, 0, len(al.dropped))
	for kind := range al.dropped {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	for _, kind := range kinds {
		lines = append(lines, fmt.Sprintf("%s  %d more %s", time.Now().UTC().Format(alertTime), al.dropped[kind], alertText(kind)))
	}
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
		if err := al.send(lines); err != nil {
			log.Printf("alert email: %v", err)
		}
	}
}

func (al *Alerter) send(lines []string) error {
	subject := "firefox-sync: " + lines[0][len(alertTime+"  "):]
	if len(lines) > 1 {
		subject = fmt.Sprintf("firefox-sync: %d events", len(lines))
	}
	body := "What happened on your firefox-sync server (times in UTC):\r\n\r\n" + strings.Join(lines, "\r\n") +
		"\r\n\r\nDetails in the admin UI, Activity.\r\n"
	msg := "From: " + al.from + "\r\nTo: " + al.to + "\r\nSubject: " + alertText(subject) +
		"\r\nDate: " + time.Now().Format(time.RFC1123Z) + "\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + body

	addr := net.JoinHostPort(al.host, al.port)
	var conn net.Conn
	var err error
	dialer := &net.Dialer{Timeout: 15 * time.Second}
	if al.implicitTLS {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{ServerName: al.host, RootCAs: al.rootCAs})
	} else {
		conn, err = dialer.Dial("tcp", addr)
	}
	if err != nil {
		return err
	}
	conn.SetDeadline(time.Now().Add(time.Minute))
	c, err := smtp.NewClient(conn, al.host)
	if err != nil {
		conn.Close()
		return err
	}
	defer c.Close()
	if !al.implicitTLS {
		if ok, _ := c.Extension("STARTTLS"); ok {
			if err := c.StartTLS(&tls.Config{ServerName: al.host, RootCAs: al.rootCAs}); err != nil {
				return err
			}
		}
	}
	if al.user != "" {
		_, encrypted := c.TLSConnectionState()
		if !encrypted && !al.insecureAuth {
			return fmt.Errorf("%s offers no TLS, not sending the password in clear", al.host)
		}
		if err := c.Auth(plainAuth{al.user, al.pass}); err != nil {
			return err
		}
	}
	if err := c.Mail(senderAddress(al.from)); err != nil {
		return err
	}
	if err := c.Rcpt(al.to); err != nil {
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
	return c.Quit()
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
