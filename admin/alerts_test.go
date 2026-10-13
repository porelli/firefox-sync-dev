package main

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"net"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeSMTP is a scripted SMTP server on 127.0.0.1: plaintext, STARTTLS (starttls)
// or TLS from the start (implicit), recording the commands and the message
type fakeSMTP struct {
	ln                 net.Listener
	tls                *tls.Config
	starttls, implicit bool
	authFail           bool // refuses every password
	quitFail           bool // drops the connection at QUIT

	mu       sync.Mutex
	commands []string
	rcpts    []string // the arguments of RCPT
	data     string
}

func newFakeSMTP(t *testing.T, starttls, implicit bool) (*fakeSMTP, *x509.CertPool) {
	// the test certificate of httptest: 127.0.0.1
	certs := httptest.NewUnstartedServer(nil)
	certs.StartTLS()
	pool := x509.NewCertPool()
	pool.AddCert(certs.Certificate())
	s := &fakeSMTP{tls: &tls.Config{Certificates: certs.TLS.Certificates}, starttls: starttls, implicit: implicit}
	certs.Close()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s.ln = ln
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go s.handle(conn)
		}
	}()
	return s, pool
}

func (s *fakeSMTP) handle(conn net.Conn) {
	defer func() { conn.Close() }()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	encrypted := false
	if s.implicit {
		conn, encrypted = tls.Server(conn, s.tls), true
	}
	r := bufio.NewReader(conn)
	reply := func(lines ...string) { conn.Write([]byte(strings.Join(lines, "\r\n") + "\r\n")) }
	reply("220 fake ESMTP")
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		line = strings.TrimRight(line, "\r\n")
		verb := strings.ToUpper(strings.SplitN(line, " ", 2)[0])
		s.mu.Lock()
		s.commands = append(s.commands, verb)
		s.mu.Unlock()
		switch verb {
		case "EHLO":
			if s.starttls && !encrypted {
				reply("250-fake", "250-STARTTLS", "250 AUTH PLAIN")
			} else {
				reply("250-fake", "250 AUTH PLAIN")
			}
		case "STARTTLS":
			reply("220 go ahead")
			conn, encrypted = tls.Server(conn, s.tls), true
			r = bufio.NewReader(conn)
		case "AUTH":
			if s.authFail {
				reply("535 5.7.8 authentication failed")
			} else {
				reply("235 ok")
			}
		case "MAIL", "RCPT":
			if verb == "RCPT" {
				s.mu.Lock()
				s.rcpts = append(s.rcpts, line[len("RCPT "):])
				s.mu.Unlock()
			}
			reply("250 ok")
		case "DATA":
			reply("354 go ahead")
			var b strings.Builder
			for {
				l, err := r.ReadString('\n')
				if err != nil {
					return
				}
				if l == ".\r\n" {
					break
				}
				b.WriteString(l)
			}
			s.mu.Lock()
			s.data = b.String()
			s.mu.Unlock()
			reply("250 ok")
		case "QUIT":
			if !s.quitFail {
				reply("221 bye")
			}
			return
		default:
			reply("502 no")
		}
	}
}

func (s *fakeSMTP) seen() ([]string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.commands...), s.data
}

func (s *fakeSMTP) alerter(pool *x509.CertPool) *Alerter {
	_, port, _ := net.SplitHostPort(s.ln.Addr().String())
	return &Alerter{to: "admin@example.com", Mailer: Mailer{from: "ffs <admin@example.com>", host: "127.0.0.1", port: port,
		user: "mailer", pass: "secret", rootCAs: pool}}
}

func line(text string) string { return time.Now().UTC().Format(alertTime) + "  " + text }

func TestAlertPasswordOnlyOverTLS(t *testing.T) {
	server, _ := newFakeSMTP(t, false, false)
	err := server.alerter(nil).send([]string{line("health: Sync server is down")})
	if err == nil || !strings.Contains(err.Error(), "offers no TLS") {
		t.Fatalf("sent without TLS: %v", err)
	}
	if commands, _ := server.seen(); strings.Contains(strings.Join(commands, " "), "AUTH") {
		t.Errorf("password sent in clear: %v", commands)
	}
}

func TestAlertSubject(t *testing.T) {
	server, _ := newFakeSMTP(t, false, false)
	al := server.alerter(nil)
	al.insecureAuth = true
	if err := al.send([]string{line("sign-up refused: mallory@example.org")}); err != nil {
		t.Fatal(err)
	}
	if _, data := server.seen(); !strings.Contains(data, "\r\nSubject: firefox-sync: sign-up refused: mallory@example.org\r\n") {
		t.Errorf("one line: %q", data)
	}
	if err := al.send([]string{line("health: Sync server is down"), line("health: Sync server is back up")}); err != nil {
		t.Fatal(err)
	}
	_, data := server.seen()
	if !strings.Contains(data, "\r\nSubject: firefox-sync: 2 events\r\n") || !strings.Contains(data, "health: Sync server is back up") {
		t.Errorf("two lines: %q", data)
	}
}

// once DATA is accepted the email is sent: a QUIT that fails must not send it again
func TestAlertQuitFails(t *testing.T) {
	server, _ := newFakeSMTP(t, false, false)
	server.quitFail = true
	al := server.alerter(nil)
	al.insecureAuth = true
	if err := al.send([]string{line("health: Sync server is down")}); err != nil {
		t.Fatalf("accepted, reported as failed: %v", err)
	}
	if _, data := server.seen(); !strings.Contains(data, "health: Sync server is down") {
		t.Errorf("%q", data)
	}
}

func TestAlertTLS(t *testing.T) {
	for _, c := range []struct {
		name               string
		starttls, implicit bool
	}{{"STARTTLS", true, false}, {"implicit TLS", false, true}} {
		server, pool := newFakeSMTP(t, c.starttls, c.implicit)
		al := server.alerter(pool)
		al.implicitTLS = c.implicit
		if err := al.send([]string{line("health: Sync server is down")}); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		commands, data := server.seen()
		got := strings.Join(commands, " ")
		if c.starttls && !strings.HasPrefix(got, "EHLO STARTTLS EHLO AUTH") || c.implicit && !strings.HasPrefix(got, "EHLO AUTH") {
			t.Errorf("%s: %s", c.name, got)
		}
		if !strings.Contains(data, "health: Sync server is down") {
			t.Errorf("%s: %q", c.name, data)
		}
	}
	// a certificate the system does not trust
	server, _ := newFakeSMTP(t, true, false)
	if err := server.alerter(nil).send([]string{line("x")}); err == nil {
		t.Error("untrusted certificate accepted")
	}
}

func TestAlertLinesFromOutside(t *testing.T) {
	app := &App{alerter: &Alerter{}}
	app.alert("sign-up refused", "x@example.org\rBcc: victim@example.com\nhealth: forged"+strings.Repeat("é", 40000))
	for i := 0; i < 2*maxAlertsPerKind; i++ {
		app.alert("sign-up refused", "mallory@example.org")
	}
	app.alert("health", "Sync server is down: refused")
	lines := app.alerter.take()
	if first := lines[0]; strings.ContainsAny(first, "\r\n") || len(first) > len(alertTime)+2+maxAlertLine+3 || !strings.HasSuffix(first, "é...") {
		t.Errorf("first line %q", first)
	}
	// the other kinds still get through, with a count of what was left out
	if len(lines) != maxAlertsPerKind+2 || !strings.HasSuffix(lines[maxAlertsPerKind], "health: Sync server is down: refused") ||
		!strings.HasSuffix(lines[maxAlertsPerKind+1], "  21 more sign-up refused") {
		t.Errorf("%d lines: %q", len(lines), lines[maxAlertsPerKind-1:])
	}
	if len(app.alerter.take()) != 0 {
		t.Error("batch not emptied")
	}
}

func TestGateEventOnlyForEmails(t *testing.T) {
	events := make(chan string, 2)
	u, _ := url.Parse("http://127.0.0.1:1")
	gate := newGate(u, "", &fakeChecker{}, func(kind, detail string) { events <- detail }, "")
	for body, want := range map[string]string{
		`{"email":"mallory@example.org"}`:                "mallory@example.org",
		`{"email":"x@y\rBcc: a@b"}`:                      "invalid email",
		`{"email":"` + strings.Repeat("a", 300) + `@b"}`: "invalid email",
	} {
		if w := create(gate, "/v1/account/create", body); w.Code != 400 {
			t.Fatalf("status %d", w.Code)
		}
		if got := <-events; got != want {
			t.Errorf("%s: %q", body, got)
		}
	}
}
