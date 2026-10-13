package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"database/sql"
	"database/sql/driver"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// tlsServer: an https server on 127.0.0.1 with a certificate valid for lifetime, and
// a Health that trusts it
func tlsServer(t *testing.T, lifetime time.Duration, handler http.Handler) (*httptest.Server, *Health) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "127.0.0.1"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(lifetime),
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	srv := httptest.NewUnstartedServer(handler)
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	h := newHealthFor(&App{gateProbe: "probe-token"})
	h.rootCAs = pool
	h.client = &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
	return srv, h
}

var heartbeat = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/__heartbeat__" {
		w.Write([]byte("{}"))
		return
	}
	http.NotFound(w, r)
})

func TestCertificateExpiry(t *testing.T) {
	srv, h := tlsServer(t, 30*24*time.Hour+time.Hour, heartbeat)
	detail, err := h.publicURL(context.Background(), srv.URL)
	if err != nil || detail != "127.0.0.1: reachable, certificate expires in 30 days" {
		t.Errorf("%q %v", detail, err)
	}
	if notAfter := h.Certs()["127.0.0.1"]; time.Until(notAfter) < 29*24*time.Hour {
		t.Errorf("expiry %v", notAfter)
	}
	// a short-lived one: a problem, with the days left
	srv, h = tlsServer(t, 5*24*time.Hour+time.Hour, heartbeat)
	_, err = h.publicURL(context.Background(), srv.URL)
	var warn warning
	if !errors.As(err, &warn) || !strings.Contains(err.Error(), "certificate expires in 5 days") {
		t.Errorf("short-lived: %v", err)
	}
	app := testApp()
	app.health = h
	if text := prometheusText(t, app); !strings.Contains(text, `ffs_cert_expiry_seconds{host="127.0.0.1"} 4`) {
		t.Errorf("metrics: %s", text)
	}
	// a certificate the server does not trust, and a name that does not resolve
	srv, _ = tlsServer(t, 30*24*time.Hour, heartbeat)
	if _, err := newHealthFor(&App{}).publicURL(context.Background(), srv.URL); err == nil || !strings.Contains(err.Error(), "certificate not valid") {
		t.Errorf("untrusted: %v", err)
	}
	if _, err := h.publicURL(context.Background(), "https://ffs-test.invalid"); err == nil || !strings.Contains(err.Error(), "not reachable from the server") {
		t.Errorf("unknown name: %v", err)
	}
	// http and unset are not checked
	for _, u := range []string{"http://sync.example.com", "", "wss://pairing.example.com"} {
		if _, err := h.publicURL(context.Background(), u); !errors.Is(err, errSkip) {
			t.Errorf("%q: %v", u, err)
		}
	}
}

// a node no longer handed out (downed, or removed) leaves ffs_cert_expiry_seconds
func TestCertsOfNodesGone(t *testing.T) {
	srv, h := tlsServer(t, 30*24*time.Hour+time.Hour, heartbeat)
	fake := &fakeFxa{nodes: [][]driver.Value{{int64(1), srv.URL, int64(100), int64(0), int64(100), int64(0), int64(0)}}}
	h.app.sync = &SyncDB{db: sql.OpenDB(fake)}
	h.certs = map[string]time.Time{"old.example.com": time.Now()}
	if _, err := h.syncNodes(context.Background()); err != nil {
		t.Fatal(err)
	}
	if certs := h.Certs(); len(certs) != 1 || certs["127.0.0.1"].IsZero() {
		t.Errorf("%v", certs)
	}
	fake.mu.Lock()
	fake.nodes[0][5] = int64(1) // downed
	fake.mu.Unlock()
	if _, err := h.syncNodes(context.Background()); !errors.Is(err, errSkip) {
		t.Fatal(err)
	}
	if certs := h.Certs(); len(certs) != 0 {
		t.Errorf("kept: %v", certs)
	}
}

func TestCertificateThreshold(t *testing.T) {
	now := time.Now()
	for _, c := range []struct {
		left  time.Duration
		days  int
		state string
	}{{14*24*time.Hour + time.Minute, 14, "ok"}, {14*24*time.Hour - time.Minute, 13, "warn"}, {time.Hour, 0, "warn"}, {-time.Hour, 0, "expired"}} {
		days, err := certProblem(now.Add(c.left), now)
		var warn warning
		state := "ok"
		if errors.As(err, &warn) {
			state = "warn"
		} else if err != nil && strings.Contains(err.Error(), "expired") {
			state = "expired"
		}
		if days != c.days || state != c.state {
			t.Errorf("%v: %d days, %s (%v)", c.left, days, state, err)
		}
	}
}

func TestGateProbe(t *testing.T) {
	upstream := 0
	auth := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstream++
		if r.Header.Get(probeHeader) != "" {
			t.Error("probe header passed on")
		}
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer auth.Close()
	u, _ := url.Parse(auth.URL)
	// open sign-ups: the probe still creates nothing, it never reaches the accounts service
	gate := newGate(u, "", &fakeChecker{allowed: map[string]bool{"": true}}, nil, "probe-token")
	srv, h := tlsServer(t, 30*24*time.Hour, gate)
	detail, err := h.gateProbe(context.Background(), srv.URL)
	if err != nil || !strings.Contains(detail, "goes through the sign-up gate") || upstream != 0 {
		t.Errorf("%q %v, upstream %d", detail, err, upstream)
	}
	// only with the token of this process
	for _, token := range []string{"", "other-token"} {
		req := httptest.NewRequest(http.MethodPost, "/v1/account/create", strings.NewReader("{}"))
		if token != "" {
			req.Header.Set(probeHeader, token)
		}
		w := httptest.NewRecorder()
		gate.ServeHTTP(w, req)
		if w.Code == http.StatusNoContent || w.Header().Get(probeHeader) != "" {
			t.Errorf("token %q: %d %v", token, w.Code, w.Header())
		}
	}
	if upstream != 2 {
		t.Errorf("upstream %d", upstream)
	}
	// a reverse proxy that sends it to the accounts service: a problem
	srv, h = tlsServer(t, 30*24*time.Hour, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusBadRequest) }))
	_, err = h.gateProbe(context.Background(), srv.URL)
	var warn warning
	if !errors.As(err, &warn) || !strings.Contains(err.Error(), "does not reach the sign-up gate") {
		t.Errorf("bypassed: %v", err)
	}
}

func TestPublicChecksOptOut(t *testing.T) {
	t.Setenv("FXA_CONTENT_URL", "https://accounts.example.com")
	t.Setenv("FXA_AUTH_URL", "https://api.example.com")
	t.Setenv("FXA_PROFILE_URL", "http://profile.example.com")
	t.Setenv("FXA_OAUTH_SERVER_URL", "https://oauth.accounts.firefox.com/v1")
	names := func() string {
		var n []string
		for _, c := range newHealthFor(&App{fxa: &FxaDB{}}).publicChecksOf(&App{fxa: &FxaDB{}}) {
			n = append(n, c.name)
		}
		return strings.Join(n, ", ")
	}
	// the profile server is http: not checked
	if got := names(); got != "Public Sync URL, Public accounts pages, Public accounts API, Sign-up gate, "+oauthKeysCheck {
		t.Errorf("checks: %s", got)
	}
	// a failing one waits 5 rounds: an unreachable name would hold every round
	for _, c := range newHealthFor(&App{fxa: &FxaDB{}}).publicChecksOf(&App{fxa: &FxaDB{}}) {
		if c.every != time.Hour || c.retry != 5*time.Minute {
			t.Errorf("%s: every %v, retry %v", c.name, c.every, c.retry)
		}
	}
	for _, off := range []string{"0", "false"} {
		t.Setenv("ADMIN_PUBLIC_CHECK", off)
		if got := names(); got != "" {
			t.Errorf("ADMIN_PUBLIC_CHECK=%s: %s", off, got)
		}
	}
	// the stack's own accounts are not on the internet: checked anyway
	t.Setenv("FXA_OAUTH_SERVER_URL", "http://fxa-auth:9000/v1")
	if got := names(); got != oauthKeysCheck {
		t.Errorf("internal: %s", got)
	}
}

func TestOauthKeysURL(t *testing.T) {
	for in, want := range map[string]string{
		"http://fxa-auth:9000/v1":                "http://fxa-auth:9000/v1/jwks",
		"https://oauth.accounts.firefox.com/v1/": "https://oauth.accounts.firefox.com/v1/jwks",
		"http://mock_fxa:6000":                   "http://mock_fxa:6000/v1/jwks",
		"":                                       "",
	} {
		if got := oauthKeysURL(in); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
}
