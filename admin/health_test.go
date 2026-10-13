package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// a Health with one component, its alerts as the record of its events
func testHealth(version string) (*Health, *Alerter) {
	alerter := &Alerter{}
	h := newHealthFor(&App{alerter: alerter})
	h.checks = []check{{
		name:     "Sync server",
		health:   func(context.Context) error { return nil },
		version:  func(context.Context) (string, error) { return version, nil },
		upstream: "mozilla-services/syncstorage-rs",
	}}
	return h, alerter
}

func newHealthFor(app *App) *Health {
	return &Health{app: app, client: http.DefaultClient, latest: map[string]string{}, notified: map[string]bool{},
		alerted: map[string]time.Time{}, lastSignup: time.Now(), started: time.Now()}
}

func TestReleaseCheck(t *testing.T) {
	asked := 0
	github := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked++
		if r.URL.Path != "/repos/mozilla-services/syncstorage-rs/releases/latest" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"tag_name":"v99.0.0","name":"99"}`))
	}))
	defer github.Close()
	defer func(api string) { githubAPI = api }(githubAPI)
	githubAPI = github.URL

	h, alerter := testHealth("0.21.1")
	ctx := context.Background()
	h.checkAll(ctx)
	h.checkReleases(ctx)
	h.checkAll(ctx)
	if c := h.Components()[0]; c.Version != "0.21.1" || c.Latest != "v99.0.0" {
		t.Errorf("component %+v", c)
	}
	lines := alerter.take()
	if len(lines) != 1 || !strings.HasSuffix(lines[0], "update: mozilla-services/syncstorage-rs v99.0.0 is out (running 0.21.1)") {
		t.Errorf("events %q", lines)
	}
	// announced once
	h.checkReleases(ctx)
	if lines := alerter.take(); len(lines) != 0 || asked != 2 {
		t.Errorf("again: %q, asked %d", lines, asked)
	}

	// syncstorage-rs built without its version
	h, alerter = testHealth("TBD")
	h.checkAll(ctx)
	h.checkReleases(ctx)
	h.checkAll(ctx)
	if c := h.Components()[0]; c.Version != "" || c.Latest != "" {
		t.Errorf("TBD: %+v", c)
	}
	if lines := alerter.take(); len(lines) != 0 {
		t.Errorf("TBD: %q", lines)
	}
}

func TestHealthEvents(t *testing.T) {
	h, alerter := testHealth("0.21.1")
	down := true
	h.checks[0].health = func(context.Context) error {
		if down {
			return &url.Error{Op: "Get", URL: "http://syncstorage:8000/__heartbeat__", Err: context.DeadlineExceeded}
		}
		return nil
	}
	ctx := context.Background()
	h.checkAll(ctx)
	h.checkAll(ctx)
	if !h.syncUpSince.IsZero() {
		t.Errorf("down, up since %v", h.syncUpSince)
	}
	down = false
	before := time.Now()
	h.checkAll(ctx)
	since := h.syncUpSince
	h.checkAll(ctx)
	// the silence of the metrics counts from here
	if since.Before(before) || h.syncUpSince != since || h.silenceFrom() != since {
		t.Errorf("up since %v (%v), silence from %v", since, h.syncUpSince, h.silenceFrom())
	}
	lines := alerter.take()
	if len(lines) != 2 || !strings.Contains(lines[0], "health: Sync server is down: Get") || !strings.HasSuffix(lines[1], "health: Sync server is back up") {
		t.Errorf("events %q", lines)
	}
}

func TestNewAccountEvents(t *testing.T) {
	h, alerter := testHealth("")
	start := h.started
	before := Event{At: start.Add(-time.Second), Kind: "sign-up", Detail: "old@example.com"}
	first := Event{At: start.Add(time.Second), Kind: "sign-up", Detail: "alice@example.com"}
	h.newAccountEvents([]Event{before, first}, start.Add(2*time.Second))
	// committed after the last round, with a createdAt before it: still alerted, once
	late := Event{At: start.Add(1500 * time.Millisecond), Kind: "new device", Detail: "alice@example.com: laptop (desktop)"}
	h.newAccountEvents([]Event{first, late}, start.Add(3*time.Second))
	lines := alerter.take()
	if len(lines) != 2 || !strings.HasSuffix(lines[0], "sign-up: alice@example.com") || !strings.HasSuffix(lines[1], "new device: alice@example.com: laptop (desktop)") {
		t.Errorf("alerts %q", lines)
	}
	// forgotten once out of the window
	h.newAccountEvents(nil, start.Add(watchOverlap+time.Minute))
	if len(h.alerted) != 0 {
		t.Errorf("kept %v", h.alerted)
	}
}

// ADMIN_UPDATE_CHECK=false: never a request to GitHub, as run decides it
func TestReleaseCheckOptOut(t *testing.T) {
	asked := 0
	github := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked++
		w.Write([]byte(`{"tag_name":"v99.0.0"}`))
	}))
	defer github.Close()
	defer func(api string) { githubAPI = api }(githubAPI)
	githubAPI = github.URL
	ctx := context.Background()
	round := func(h *Health, now time.Time) {
		h.checkAll(ctx)
		if h.releasesDue(now) {
			h.checkReleases(ctx)
		}
		h.checkAll(ctx)
	}

	t.Setenv("ADMIN_UPDATE_CHECK", "false")
	h, alerter := testHealth("0.21.1")
	round(h, time.Now())
	round(h, time.Now().Add(13*time.Hour))
	if lines := alerter.take(); asked != 0 || len(lines) != 0 || h.Components()[0].Latest != "" {
		t.Errorf("opted out: asked %d, alerts %q, %+v", asked, lines, h.Components()[0])
	}

	// unset: one round, then none within 12 hours, again after
	os.Unsetenv("ADMIN_UPDATE_CHECK")
	h, alerter = testHealth("0.21.1")
	round(h, time.Now())
	round(h, time.Now().Add(time.Hour))
	if lines := alerter.take(); asked != 1 || len(lines) != 1 || !strings.Contains(lines[0], "update: ") {
		t.Errorf("asked %d, alerts %q", asked, lines)
	}
	round(h, time.Now().Add(13*time.Hour))
	if asked != 2 {
		t.Errorf("after 12 hours: asked %d", asked)
	}
}
