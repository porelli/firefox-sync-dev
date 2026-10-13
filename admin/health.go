package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Health of the components, their versions, the sizes of the databases and the
// newest upstream releases, checked in the background every minute

type Component struct {
	Name    string
	Up      bool
	Error   string
	Version string
	Latest  string // newest upstream release, when newer than Version
	Checked time.Time
}

type check struct {
	name    string
	health  func(ctx context.Context) error
	version func(ctx context.Context) (string, error)
	// upstream repository (owner/name) whose releases are compared with the version
	upstream string
}

type Health struct {
	app    *App
	checks []check
	client *http.Client

	mu         sync.Mutex
	components []Component
	sizes      map[string]int64
	latest     map[string]string // upstream repository -> newest release
	latestAt   time.Time
	notified   map[string]bool // releases already announced
	lastSignup time.Time
	started    time.Time
	alerted    map[string]time.Time // new accounts and devices already alerted
}

// GitHub's API, for the release check (the tests use their own)
var githubAPI = "https://api.github.com"

// rows of new accounts and devices can commit a bit after their createdAt: each
// round looks back this much more, alerted ones are skipped
const watchOverlap = time.Minute

func httpCheck(client *http.Client, url string) func(ctx context.Context) error {
	return func(ctx context.Context) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		res, err := client.Do(req)
		if err != nil {
			return err
		}
		res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return fmt.Errorf("status %d", res.StatusCode)
		}
		return nil
	}
}

// versionOf reads {"version": "..."} from a /__version__ endpoint
func versionOf(client *http.Client, url string) func(ctx context.Context) (string, error) {
	return func(ctx context.Context) (string, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return "", err
		}
		res, err := client.Do(req)
		if err != nil {
			return "", err
		}
		defer res.Body.Close()
		var v struct {
			Version string `json:"version"`
		}
		if err := json.NewDecoder(io.LimitReader(res.Body, 1<<16)).Decode(&v); err != nil {
			return "", err
		}
		return v.Version, nil
	}
}

func newHealth(app *App) *Health {
	client := &http.Client{Timeout: 10 * time.Second}
	h := &Health{app: app, client: client, latest: map[string]string{}, notified: map[string]bool{}, alerted: map[string]time.Time{}}
	h.lastSignup, h.started = time.Now(), time.Now()
	sync := strings.TrimSuffix(env("SYNCSTORAGE_URL", "http://syncstorage:8000"), "/")
	h.checks = append(h.checks,
		check{name: "Sync server", health: httpCheck(client, sync+"/__heartbeat__"), version: versionOf(client, sync+"/__version__"), upstream: "mozilla-services/syncstorage-rs"},
		check{name: "Tokenserver database", health: app.sync.Ping, version: app.sync.Version},
	)
	if app.storage != nil && !app.sync.postgres {
		h.checks = append(h.checks, check{name: "Storage database", health: func(ctx context.Context) error { return app.storage.db.PingContext(ctx) }, version: app.storage.Version})
	}
	if app.fxa != nil {
		auth := strings.TrimSuffix(env("FXA_AUTH_UPSTREAM", "http://fxa-auth:9000"), "/")
		content := strings.TrimSuffix(env("FXA_CONTENT_INTERNAL_URL", "http://fxa-content:3030"), "/")
		profile := strings.TrimSuffix(env("FXA_PROFILE_INTERNAL_URL", "http://fxa-profile:1111"), "/")
		h.checks = append(h.checks,
			check{name: "Accounts API", health: httpCheck(client, auth+"/__heartbeat__"), version: versionOf(client, auth+"/__version__"), upstream: "mozilla/fxa"},
			check{name: "Accounts pages", health: httpCheck(client, content+"/__heartbeat__"), version: versionOf(client, content+"/__version__")},
			check{name: "Profile server", health: httpCheck(client, profile+"/__heartbeat__"), version: versionOf(client, profile+"/__version__")},
			check{name: "Accounts database", health: app.fxa.Ping, version: app.fxa.Version},
			check{name: "Accounts Redis", version: func(ctx context.Context) (string, error) { return redisVersion(ctx, app.fxa.redis) }, health: func(ctx context.Context) error {
				conn, err := dialRedis(ctx, app.fxa.redis)
				if err != nil {
					return err
				}
				defer conn.Close()
				_, err = conn.Do("PING")
				return err
			}},
		)
		// the optional pairing server (COMPOSE_PROFILES=pairing): its version is in the heartbeat,
		// not compared with the releases (the crate version lags behind the tags)
		if env("FXA_PAIRING_URL", "") != "" {
			pairing := strings.TrimSuffix(env("FXA_PAIRING_INTERNAL_URL", "http://fxa-pairing:8000"), "/")
			h.checks = append(h.checks, check{name: "Pairing server", health: httpCheck(client, pairing+"/__heartbeat__"),
				version: func(ctx context.Context) (string, error) {
					// our builds fill /__version__, Mozilla's say TBD there and have the crate version in the heartbeat
					if v, err := versionOf(client, pairing+"/__version__")(ctx); err == nil && v != "" && v != "TBD" {
						return v, nil
					}
					return versionOf(client, pairing+"/__heartbeat__")(ctx)
				}})
		}
	}
	// this program, at the top of the list
	h.checks = append([]check{{name: "Admin UI", health: func(context.Context) error { return nil },
		version: func(context.Context) (string, error) { return version, nil }}}, h.checks...)
	return h
}

func (h *Health) run(ctx context.Context) {
	tick := time.NewTicker(time.Duration(envInt("HEALTH_CHECK_SECONDS", 60)) * time.Second)
	defer tick.Stop()
	lastSizes := time.Time{}
	for {
		h.checkAll(ctx)
		h.watchAccounts(ctx)
		if time.Since(lastSizes) >= time.Hour {
			h.measureSizes(ctx)
			lastSizes = time.Now()
		}
		if env("ADMIN_UPDATE_CHECK", "true") != "false" && time.Since(h.latestAt) > 12*time.Hour {
			h.checkReleases(ctx)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func (h *Health) checkAll(ctx context.Context) {
	h.mu.Lock()
	previous := map[string]bool{}
	for _, c := range h.components {
		previous[c.Name] = c.Up
	}
	h.mu.Unlock()
	components := make([]Component, 0, len(h.checks))
	for _, c := range h.checks {
		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		comp := Component{Name: c.name, Checked: time.Now()}
		if err := c.health(cctx); err != nil {
			comp.Error = err.Error()
		} else {
			comp.Up = true
		}
		if c.version != nil && comp.Up {
			comp.Version, _ = c.version(cctx)
			if comp.Version == "TBD" { // syncstorage-rs built without its version
				comp.Version = ""
			}
		}
		cancel()
		h.mu.Lock()
		if latest := h.latest[c.upstream]; latest != "" && comp.Version != "" && newerVersion(latest, comp.Version) {
			comp.Latest = latest
		}
		h.mu.Unlock()
		if up, seen := previous[c.name]; seen && up != comp.Up {
			if comp.Up {
				h.app.event("health", c.name+" is back up")
			} else {
				h.app.event("health", c.name+" is down: "+comp.Error)
			}
		} else if !seen && !comp.Up {
			h.app.event("health", c.name+" is down: "+comp.Error)
		}
		components = append(components, comp)
	}
	h.mu.Lock()
	h.components = components
	h.mu.Unlock()
}

// watchAccounts turns new accounts and devices into events (and alerts)
func (h *Health) watchAccounts(ctx context.Context) {
	if h.app.fxa == nil {
		return
	}
	now := time.Now()
	events, err := h.app.fxa.Recent(ctx, h.lastSignup.Add(-watchOverlap))
	if err != nil {
		log.Printf("watching new accounts: %v", err)
		return
	}
	h.newAccountEvents(events, now)
}

// newAccountEvents alerts the events not alerted yet, since the start
func (h *Health) newAccountEvents(events []Event, now time.Time) {
	h.lastSignup = now
	for _, e := range events {
		key := e.Kind + "\x00" + e.Detail + "\x00" + strconv.FormatInt(e.At.UnixMilli(), 10)
		if e.At.Before(h.started) || !h.alerted[key].IsZero() {
			continue
		}
		h.alerted[key] = e.At
		h.app.alert(e.Kind, e.Detail)
	}
	// older than the next round looks
	for key, at := range h.alerted {
		if at.Before(now.Add(-watchOverlap)) {
			delete(h.alerted, key)
		}
	}
}

func (h *Health) measureSizes(ctx context.Context) {
	sizes := map[string]int64{}
	if n, err := h.app.sync.Size(ctx); err == nil {
		if h.app.sync.postgres {
			sizes["Sync (tokenserver and storage)"] = n
		} else {
			sizes["Tokenserver"] = n
		}
	} else {
		log.Printf("database size: %v", err)
	}
	if h.app.storage != nil && !h.app.sync.postgres {
		if n, err := h.app.storage.Size(ctx); err == nil {
			sizes["Sync storage"] = n
		} else {
			log.Printf("storage database size: %v", err)
		}
	}
	if h.app.fxa != nil {
		if n, err := h.app.fxa.Size(ctx); err == nil {
			sizes["Accounts"] = n
		} else {
			log.Printf("accounts database size: %v", err)
		}
	}
	h.mu.Lock()
	h.sizes = sizes
	h.mu.Unlock()
	for name, n := range sizes {
		h.app.rec.Gauge("db.size."+name, n)
	}
}

// checkReleases asks GitHub for the newest releases (ADMIN_UPDATE_CHECK=false: never)
func (h *Health) checkReleases(ctx context.Context) {
	h.latestAt = time.Now()
	for _, c := range h.checks {
		if c.upstream == "" {
			continue
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, githubAPI+"/repos/"+c.upstream+"/releases/latest", nil)
		req.Header.Set("Accept", "application/vnd.github+json")
		res, err := h.client.Do(req)
		if err != nil {
			log.Printf("release check %s: %v", c.upstream, err)
			continue
		}
		var release struct {
			Tag string `json:"tag_name"`
		}
		err = json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&release)
		res.Body.Close()
		if err != nil || release.Tag == "" {
			continue
		}
		h.mu.Lock()
		h.latest[c.upstream] = release.Tag
		announce := !h.notified[release.Tag]
		h.notified[release.Tag] = true
		h.mu.Unlock()
		if announce {
			for _, comp := range h.Components() {
				if comp.Name == c.name && comp.Version != "" && newerVersion(release.Tag, comp.Version) {
					h.app.event("update", fmt.Sprintf("%s %s is out (running %s)", c.upstream, release.Tag, comp.Version))
				}
			}
		}
	}
}

func (h *Health) Components() []Component {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]Component(nil), h.components...)
}

func (h *Health) Sizes() map[string]int64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	sizes := map[string]int64{}
	for k, v := range h.sizes {
		sizes[k] = v
	}
	return sizes
}

// newerVersion: is a (v1.348.0, 0.23.4) newer than b? Numeric parts, an optional v
func newerVersion(a, b string) bool {
	pa, pb := versionParts(a), versionParts(b)
	if pa == nil || pb == nil {
		return false
	}
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func versionParts(v string) []int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if i := strings.IndexAny(v, "-+ "); i >= 0 {
		v = v[:i]
	}
	var parts []int
	for _, p := range strings.Split(v, ".") {
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil
		}
		parts = append(parts, n)
	}
	return parts
}
