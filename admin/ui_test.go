package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHealthSummary(t *testing.T) {
	app := testApp()
	if app.healthSummary() != nil {
		t.Error("a summary without health checks")
	}
	app.health = &Health{started: time.Now(), components: []Component{{Name: "Sync server", Up: true}, {Name: "Accounts API"},
		{Name: "Public Sync URL", Warn: true, Error: "certificate expires in 3 days"}, {Name: "OAuth keys", Up: true, Hidden: true}, {Name: "Email", Hidden: true}}}
	got := *app.healthSummary()
	// the setup checks count when they fail only
	want := healthSummary{Total: 4, Up: 1, Down: 2, Warn: 1, FirstDown: "Accounts API", FirstWarn: "Public Sync URL"}
	if got != want {
		t.Errorf("%+v", got)
	}
}

func TestBackupTile(t *testing.T) {
	now := time.Now()
	ok := BackupStatus{Scope: "sync", Last: BackupRun{OK: true, Finished: now.Add(-time.Hour)}, LastOK: BackupRun{OK: true, Finished: now.Add(-time.Hour)}}
	old := BackupStatus{Scope: "accounts", Last: BackupRun{OK: true, Finished: now.Add(-72 * time.Hour)}, LastOK: BackupRun{OK: true, Finished: now.Add(-72 * time.Hour)}}
	failed := BackupStatus{Scope: "sync", Last: BackupRun{Finished: now.Add(-3 * time.Hour)}, LastOK: ok.LastOK}
	for _, c := range []struct {
		backups     []BackupStatus
		state, text string
	}{
		{nil, "warn", "None recorded yet"}, {[]BackupStatus{ok}, "ok", "Up to date"},
		{[]BackupStatus{ok, old}, "warn", "Last good one 3 days ago"}, {[]BackupStatus{old, failed}, "bad", "Failed 3 hours ago"},
	} {
		if state, text := backupTile(c.backups, now); state != c.state || text != c.text {
			t.Errorf("%v: %s %q", c.backups, state, text)
		}
	}
}

func TestEventLogHidesSignIns(t *testing.T) {
	app := testApp()
	f := &fakeFxa{}
	app.rec = fakeRecorder(f)
	var errs []string
	_, _, _, _, _, hide := app.eventPage(httptest.NewRequest("GET", "/activity?hide=sign-ins", nil), &errs)
	if !hide || len(errs) > 0 {
		t.Fatal(hide, errs)
	}
	q := f.queries[len(f.queries)-1]
	args := f.qargs[len(f.qargs)-1]
	if !strings.Contains(q, "AND NOT (kind = ? AND detail LIKE ?)") || args[1] != "admin" || args[2] != "signed in%" {
		t.Errorf("%s %v", q, args)
	}
	// off by default
	if _, _, _, _, _, hide := app.eventPage(httptest.NewRequest("GET", "/activity", nil), &errs); hide || strings.Contains(f.queries[len(f.queries)-1], "NOT") {
		t.Error("sign-ins hidden by default")
	}
	// the rows: a dot by kind, the admins' sign-ins muted
	var b strings.Builder
	data := map[string]any{"CSRF": "x", "Range": "24h", "Ranges": []string{"24h"}, "Kinds": eventKinds, "Since": time.Now(), "Received": time.Time{}, "Hide": true,
		"Events": []Event{{At: time.Now(), Kind: "admin", Detail: "signed in (password)"}, {At: time.Now(), Kind: "health", Detail: "x"}}}
	if err := templates.ExecuteTemplate(&b, "activity.html", data); err != nil {
		t.Fatal(err)
	}
	page := b.String()
	for _, want := range []string{`<tr data-kind="admin" class="routine"><td>`, `<tr data-kind="health"><td>`, `<input type="hidden" name="hide" value="sign-ins">`, `aria-current="true">Sign-ins hidden`} {
		if !strings.Contains(page, want) {
			t.Errorf("no %q", want)
		}
	}
}

func TestErrorPages(t *testing.T) {
	app := testApp()
	h := app.routes()
	get := func(path string, cookie *http.Cookie, accept string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "https://admin.example.com"+path, nil)
		if cookie != nil {
			req.AddCookie(cookie)
		}
		if accept != "" {
			req.Header.Set("Accept", accept)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	// scripts get the text as before
	if w := get("/nowhere", nil, ""); w.Code != 404 || w.Body.String() != "404 page not found\n" {
		t.Errorf("%d %q", w.Code, w.Body)
	}
	// a browser signed out: the page, no nav
	w := get("/nowhere", nil, "text/html,application/xhtml+xml")
	if page := w.Body.String(); w.Code != 404 || !strings.HasPrefix(w.Header().Get("Content-Type"), "text/html") || !strings.Contains(page, "<h1>Page not found</h1>") ||
		strings.Contains(page, `class="sidebar"`) || !strings.Contains(page, `href="/">Back to the Overview</a>`) {
		t.Errorf("%d %s", w.Code, page)
	}
	if !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") {
		t.Error("CSP")
	}
	// signed in: with the nav and its sign-out form
	c, s := passwordSession(t, app, h)
	w = get("/storage/purge", c, "text/html")
	if page := w.Body.String(); w.Code != 404 || !strings.Contains(page, `class="sidebar"`) || !strings.Contains(page, `name="csrf" value="`+s.csrf+`"`) ||
		!strings.Contains(page, "<title>Page not found · Firefox Sync admin</title>") {
		t.Errorf("%d %s", w.Code, page)
	}
}

func TestBreakEmail(t *testing.T) {
	if got := string(breakEmail(`a.b@ex<am>"ple.com`)); got != `a<wbr>.b@<wbr>ex&lt;am&gt;&#34;ple<wbr>.com` {
		t.Error(got)
	}
}

func TestActivityMetricsMissing(t *testing.T) {
	for _, silent := range []string{"", "Sync data changed at 13 Oct 2026 10:00 but no metrics arrived since the last ones at 13 Oct 2026 09:00"} {
		var b strings.Builder
		data := map[string]any{"CSRF": "x", "Range": "24h", "Ranges": []string{"24h"}, "Kinds": eventKinds, "Since": time.Now(), "Received": time.Now().Add(-time.Hour), "Silent": silent}
		if silent == "" {
			delete(data, "Silent")
		}
		if err := templates.ExecuteTemplate(&b, "activity.html", data); err != nil {
			t.Fatal(err)
		}
		page := b.String()
		if shown := strings.Contains(page, "Missing metrics</span> "+silent+": restart the Sync server"); shown != (silent != "") || !strings.Contains(page, "Last metrics received") {
			t.Errorf("silent %q: %v", silent, shown)
		}
	}
}

func TestActivityNothingReceived(t *testing.T) {
	// the box asking for a restart only when the stored history is empty too
	for _, history := range []bool{false, true} {
		var b strings.Builder
		data := map[string]any{"CSRF": "x", "Range": "24h", "Ranges": []string{"24h"}, "Kinds": eventKinds, "Since": time.Now(), "Received": time.Time{},
			"History": history, "Started": time.Now(), "Charts": []map[string]any{{"Title": "Sync requests", "Total": 75}}}
		if err := templates.ExecuteTemplate(&b, "activity.html", data); err != nil {
			t.Fatal(err)
		}
		page := b.String()
		if box := strings.Contains(page, `<p class="box">No metrics received`); box == history {
			t.Errorf("history %v: box %v", history, box)
		}
		if history && !strings.Contains(page, "the charts show the stored history") || !strings.Contains(page, "Sync requests <strong>75</strong>") {
			t.Errorf("history %v: %s", history, page)
		}
	}
}
