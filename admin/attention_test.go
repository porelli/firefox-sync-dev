package main

import (
	"bufio"
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestBackupStatuses(t *testing.T) {
	now := time.Now()
	at := func(h int) time.Time { return now.Add(-time.Duration(h) * time.Hour) }
	runs := []BackupRun{
		{Scope: "accounts", Started: at(1), Finished: at(1), OK: false, Error: "access denied"},
		{Scope: "sync", Started: at(2), Finished: at(2), OK: true, Bytes: 10},
		{Scope: "accounts", Started: at(25), Finished: at(25), OK: true, Bytes: 20},
		{Scope: "sync", Started: at(26), Finished: at(26), OK: true, Bytes: 30},
	}
	got := backupStatuses(runs)
	if len(got) != 2 || got[0].Scope != "sync" || got[1].Scope != "accounts" {
		t.Fatalf("%+v", got)
	}
	if got[0].Last.Bytes != 10 || got[0].LastOK.Bytes != 10 || got[0].state(now) != "ok" || got[0].Problem(now) != "" {
		t.Errorf("sync: %+v", got[0])
	}
	if got[1].Last.OK || got[1].LastOK.Bytes != 20 || got[1].state(now) != "failed" || !strings.Contains(got[1].Problem(now), "failed on") ||
		!strings.HasSuffix(got[1].Problem(now), ": access denied") {
		t.Errorf("accounts: %+v %q", got[1], got[1].Problem(now))
	}
	// 36 hours: still fine; past them, stale
	ok := BackupStatus{Scope: "sync", Last: BackupRun{OK: true, Finished: at(35)}, LastOK: BackupRun{OK: true, Finished: at(35)}}
	if ok.state(now) != "ok" {
		t.Error("35 hours")
	}
	old := BackupStatus{Scope: "sync", Last: BackupRun{OK: true, Finished: at(37)}, LastOK: BackupRun{OK: true, Finished: at(37)}}
	if old.state(now) != "stale" || !strings.Contains(old.Problem(now), "more than 36 hours ago") || !old.Old() {
		t.Errorf("37 hours: %q", old.Problem(now))
	}
	never := backupStatuses([]BackupRun{{Scope: "sync", Started: at(1), Finished: at(1), Error: "x"}})
	if never[0].state(now) != "failed" || !never[0].LastOK.Finished.IsZero() {
		t.Errorf("%+v", never)
	}
}

func TestBackupAlertsOncePerState(t *testing.T) {
	fake := &fakeFxa{}
	app := testApp()
	app.sync, app.alerter = &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	h := newHealth(app)
	now := time.Now()
	row := func(ok bool, hoursAgo int) []driver.Value {
		at := now.Add(-time.Duration(hoursAgo) * time.Hour).UnixMilli()
		e := ""
		if !ok {
			e = "storage: access denied"
		}
		v := int64(0)
		if ok {
			v = 1
		}
		return []driver.Value{"sync", at, at, v, int64(1000), e, "/backups/sync/x"}
	}
	round := func(rows ...[]driver.Value) []string {
		fake.mu.Lock()
		fake.backups = rows
		fake.mu.Unlock()
		h.watchBackups(t.Context(), now)
		return app.alerter.take()
	}
	if got := round(); len(got) != 0 {
		t.Errorf("no backups: %q", got)
	}
	if got := round(row(true, 1)); len(got) != 0 {
		t.Errorf("a good one: %q", got)
	}
	got := round(row(false, 0), row(true, 1))
	if len(got) != 1 || !strings.Contains(got[0], "backup: The backup of the Sync databases failed on") || !strings.Contains(got[0], "storage: access denied") {
		t.Errorf("failed: %q", got)
	}
	if got := round(row(false, 0), row(true, 1)); len(got) != 0 {
		t.Errorf("failed again, alerted again: %q", got)
	}
	if got := round(row(true, 0), row(false, 0)); len(got) != 1 || !strings.Contains(got[0], "works again") {
		t.Errorf("back: %q", got)
	}
	if got := round(row(true, 40)); len(got) != 1 || !strings.Contains(got[0], "more than 36 hours ago") {
		t.Errorf("stale: %q", got)
	}
	if b := h.Backups(); len(b) != 1 || b[0].Last.Location != "/backups/sync/x" {
		t.Errorf("%+v", b)
	}
	// a first look at a failed backup alerts too (the admin UI restarted)
	h2 := newHealth(app)
	fake.backups = [][]driver.Value{row(false, 0)}
	h2.watchBackups(t.Context(), now)
	if got := app.alerter.take(); len(got) != 1 {
		t.Errorf("at the start: %q", got)
	}
}

// allGood: an overview with nothing to look at
func allGood(now time.Time) attentionInput {
	return attentionInput{now: now, fxa: true, staleDays: 90,
		components: []Component{{Name: "Admin UI", Up: true}, {Name: "Sync server", Up: true, Version: "0.21.1"}, {Name: "Email (SMTP)", Up: true},
			{Name: "Sign-up gate", Up: true}, {Name: oauthKeysCheck, Up: true, Hidden: true}},
		certs:  map[string]time.Time{"sync.example.com": now.AddDate(0, 0, 60)},
		status: &SyncStatus{Users: 8, MaxUsers: 10},
		backups: []BackupStatus{{Scope: "sync", Last: BackupRun{OK: true, Finished: now.Add(-time.Hour)},
			LastOK: BackupRun{OK: true, Finished: now.Add(-time.Hour)}}},
		storage:      &StorageReport{},
		accounts:     []accountRow{{UID: fakeUID, Email: fakeEmail}},
		pruneLastRan: now.Add(-time.Hour),
		alerts:       &SendStatus{At: now, LastOK: now},
		lastStatsd:   now.Add(-time.Minute), silenceFrom: now.Add(-time.Hour),
	}
}

func TestNeedsAttention(t *testing.T) {
	now := time.Now()
	if got := needsAttention(allGood(now)); len(got) != 0 {
		t.Fatalf("all good: %+v", got)
	}
	two := []accountRow{{UID: "aa"}, {UID: "bb"}}
	cases := []struct {
		name       string
		change     func(*attentionInput)
		href, text string
	}{
		{"component down", func(in *attentionInput) { in.components[1] = Component{Name: "Sync server", Error: "status 503"} }, "#health", "Sync server is down: status 503."},
		{"update", func(in *attentionInput) { in.components[1].Latest = "0.22.0" }, "#health", "Sync server 0.22.0 is out, 0.21.1 runs here."},
		{"blocked members", func(in *attentionInput) { in.accounts[0].Blocked = true }, "/security", "1 account blocked by the rate limits."},
		{"unconfirmed", func(in *attentionInput) { in.unconfirmed = 3 }, "/?show=unconfirmed#accounts", "3 accounts never confirmed their email."},
		{"one unconfirmed sign-in", func(in *attentionInput) { in.accounts[0].Security.UnverifiedSessions = 1 }, "/users/" + fakeUID, "1 account with a sign-in that never entered its email code"},
		{"unconfirmed sign-ins", func(in *attentionInput) {
			in.accounts = two
			in.accounts[0].Security.UnverifiedSessions, in.accounts[1].Security.UnverifiedSessions = 1, 2
		}, "/?show=unconfirmed-sign-in#accounts", "2 accounts with a sign-in"},
		{"stale backup", func(in *attentionInput) {
			in.backups[0].Last.Finished, in.backups[0].LastOK.Finished = now.Add(-40*time.Hour), now.Add(-40*time.Hour)
		}, "#backups", "more than 36 hours ago"},
		{"failed backup", func(in *attentionInput) { in.backups[0].Last = BackupRun{Finished: now, Error: "disk full"} }, "#backups", "failed on"},
		{"certificate", func(in *attentionInput) { in.certs["sync.example.com"] = now.AddDate(0, 0, 10).Add(time.Hour) }, "#health", "The certificate of sync.example.com expires in 10 days"},
		{"gate bypassed", func(in *attentionInput) { in.components[3] = Component{Name: "Sign-up gate", Warn: true, Error: "x"} }, "#health", "bypass the sign-up gate"},
		{"orphans", func(in *attentionInput) {
			in.storage = &StorageReport{Orphaned: Usage{Bytes: 2048}, Orphans: []Orphan{{}}}
		}, "/storage/purge", "2.0 KB of Sync data nobody reads any more (1 orphans)."},
		{"prune late", func(in *attentionInput) { in.pruneLastRan = now.Add(-49 * time.Hour) }, "/activity#maintenance", "not pruned for 2 days"},
		{"never pruned", func(in *attentionInput) { in.pruneLastRan = time.Time{} }, "/activity#maintenance", "(last: never)"},
		{"SMTP down", func(in *attentionInput) { in.components[2] = Component{Name: "Email (SMTP)", Error: "535 auth failed"} }, "#health", "The SMTP server does not work (535 auth failed)"},
		{"alert send failed", func(in *attentionInput) { in.alerts.Err = "connection refused" }, "#alert-status", "The last alert email failed on"},
		{"90% of max users", func(in *attentionInput) { in.status.Users = 9 }, "#sync", "9 of 10 accounts are taken (90% or more)"},
		{"statsd silence", func(in *attentionInput) { in.lastStatsd = now.Add(-31 * time.Minute) }, "/activity", "No metrics from the Sync server for 30 minutes"},
		{"inactive device", func(in *attentionInput) { in.inactiveDevices = map[string]int{fakeUID: 2} }, "/users/" + fakeUID + "#devices", "2 devices of 1 account not used for 90 days"},
		{"inactive devices", func(in *attentionInput) { in.inactiveDevices = map[string]int{"aa": 1, "bb": 1} }, "/?show=inactive-devices#accounts", "2 devices of 2 accounts"},
		{"sign-in keys", func(in *attentionInput) {
			in.components[4] = Component{Name: oauthKeysCheck, Hidden: true, Error: "no keys"}
		}, "#setup", "no keys"},
	}
	for _, c := range cases {
		in := allGood(now)
		c.change(&in)
		got := needsAttention(in)
		if len(got) != 1 || got[0].Href != c.href || !strings.Contains(got[0].Text, c.text) || got[0].Link == "" {
			t.Errorf("%s: %+v", c.name, got)
		}
	}
	// a server with no metrics since the start: only after 30 minutes
	in := allGood(now)
	in.lastStatsd, in.silenceFrom = time.Time{}, now.Add(-10*time.Minute)
	if got := needsAttention(in); len(got) != 0 {
		t.Errorf("just started: %+v", got)
	}
	// max users 0 refuses everybody on purpose; Mozilla's accounts: no accounts checks
	in = allGood(now)
	in.status, in.fxa, in.pruneLastRan, in.unconfirmed = &SyncStatus{Users: 0, MaxUsers: 0}, false, time.Time{}, 5
	if got := needsAttention(in); len(got) != 0 {
		t.Errorf("max users 0, Mozilla's accounts: %+v", got)
	}
	// the Sync server down: one line for it, no silence on top
	in = allGood(now)
	in.components[1], in.lastStatsd = Component{Name: "Sync server", Error: "x"}, time.Time{}
	if got := needsAttention(in); len(got) != 1 {
		t.Errorf("down: %+v", got)
	}
}

func TestThresholdsAlertOncePerState(t *testing.T) {
	now := time.Now()
	h := &Health{started: now.Add(-time.Hour)}
	full, room := &SyncStatus{Users: 9, MaxUsers: 10}, &SyncStatus{Users: 1, MaxUsers: 10}
	sent, failed := &SendStatus{At: now, LastOK: now}, &SendStatus{At: now, Err: "refused"}
	steps := []struct {
		st     *SyncStatus
		up     bool
		last   time.Time
		alerts *SendStatus
		want   []string
	}{
		{room, true, now, sent, nil},
		{full, true, now, sent, []string{"9 of 10 accounts are taken (90% or more)"}},
		{full, true, now, sent, nil},
		// a failed read: no change
		{nil, true, now, sent, nil},
		{room, true, now, sent, []string{"under 90% again"}},
		{room, true, now.Add(-time.Hour), sent, []string{"No metrics from the Sync server for 30 minutes"}},
		{room, true, now.Add(-time.Hour), sent, nil},
		// the Sync server down: its health alerts, the silence stays (no false "again")
		{room, false, now.Add(-time.Hour), sent, nil},
		{room, true, now.Add(-time.Hour), sent, nil},
		{room, true, now, sent, []string{"Metrics from the Sync server arrive again"}},
		{room, false, now.Add(-time.Hour), sent, nil},
		{room, true, now, failed, []string{"Alert emails fail: refused"}},
		{room, true, now, failed, nil},
		{room, true, now, sent, []string{"Alert emails go out again"}},
		{room, true, now, nil, nil},
	}
	for i, s := range steps {
		got := h.thresholdEvents(s.st, s.up, s.last, s.alerts, now)
		if len(got) != len(s.want) {
			t.Fatalf("step %d: %q, want %q", i, got, s.want)
		}
		for j := range got {
			if !strings.Contains(got[j], s.want[j]) {
				t.Errorf("step %d: %q, want %q", i, got[j], s.want[j])
			}
		}
	}
	// up again after an outage of more than 30 minutes, its first metrics not yet in:
	// the silence counts from its coming up
	h.syncUpSince = now.Add(-time.Minute)
	if got := h.thresholdEvents(room, true, now.Add(-time.Hour), sent, now); len(got) != 0 {
		t.Errorf("just up again: %q", got)
	}
	if got := h.thresholdEvents(room, true, now.Add(-time.Hour), sent, now.Add(statsdSilence)); len(got) != 1 || !strings.Contains(got[0], "No metrics") {
		t.Errorf("up again, still silent: %q", got)
	}
	// the first round alerts what is already wrong
	h = &Health{started: now.Add(-time.Hour)}
	if got := h.thresholdEvents(full, true, now, failed, now); len(got) != 2 {
		t.Errorf("first round: %q", got)
	}
}

func TestPaginate(t *testing.T) {
	for _, c := range []struct{ total, page, from, to, current, pages int }{
		{0, 1, 0, 0, 1, 1},
		{1, 1, 0, 1, 1, 1},
		{50, 1, 0, 50, 1, 1},
		{51, 1, 0, 50, 1, 2},
		{51, 2, 50, 51, 2, 2},
		{120, 3, 100, 120, 3, 3},
		{120, 9, 100, 120, 3, 3},
		{120, -4, 0, 50, 1, 3},
	} {
		from, to, current, pages := paginate(c.total, c.page, 50)
		if from != c.from || to != c.to || current != c.current || pages != c.pages {
			t.Errorf("%d rows, page %d: %d-%d page %d of %d", c.total, c.page, from, to, current, pages)
		}
	}
	p, from, to := newPager(120, 2, "Alice Smith", "blocked")
	if from != 50 || to != 100 || p.From != 51 || p.To != 100 || p.Total != 120 || p.Page != 2 || p.Pages != 3 {
		t.Errorf("%+v", p)
	}
	for _, link := range []string{p.Prev, p.Next} {
		u, err := url.Parse(link)
		if err != nil || u.Path != "/" || u.Query().Get("q") != "Alice Smith" || u.Query().Get("show") != "blocked" || u.Fragment != "accounts" {
			t.Errorf("link %q", link)
		}
	}
	if u, _ := url.Parse(p.Next); u.Query().Get("page") != "3" {
		t.Errorf("next %q", p.Next)
	}
	if u, _ := url.Parse(p.Prev); u.Query().Has("page") {
		t.Errorf("prev of page 2 is the first: %q", p.Prev)
	}
	if p, _, _ := newPager(10, 1, "", ""); p.Prev != "" || p.Next != "" || p.From != 1 || p.To != 10 {
		t.Errorf("one page: %+v", p)
	}
	if p, _, _ := newPager(0, 1, "x", ""); p.From != 0 || p.To != 0 {
		t.Errorf("none: %+v", p)
	}
}

func TestMatchAccount(t *testing.T) {
	for _, c := range []struct {
		q    string
		want bool
	}{
		{"", true}, {"alice", true}, {"example.com", true}, {"0123ab", true}, {"laptop", true}, {"bob", false},
		// the account of the tokenserver uid or another address, found by the caller
		{"42", true}, {"43", false},
	} {
		id := ""
		if c.q == "42" {
			id = fakeUID
		}
		if got := matchAccount(c.q, fakeUID, "Alice@Example.com", "Work Laptop", id); got != c.want {
			t.Errorf("%q: %v", c.q, got)
		}
	}
}

func TestBackupMetrics(t *testing.T) {
	now := time.Now()
	var b strings.Builder
	backupMetrics(&b, []BackupStatus{
		{Scope: "sync", Last: BackupRun{OK: true, Finished: now.Add(-90 * time.Minute)}, LastOK: BackupRun{OK: true, Finished: now.Add(-90 * time.Minute)}},
		{Scope: "accounts", Last: BackupRun{Finished: now}},
	}, now)
	out := b.String()
	for _, want := range []string{"ffs_backup_age_seconds{scope=\"sync\"} 5400\n", "ffs_backup_last_ok{scope=\"sync\"} 1\n", "ffs_backup_last_ok{scope=\"accounts\"} 0\n"} {
		if !strings.Contains(out, want) {
			t.Errorf("no %q in %s", want, out)
		}
	}
	// no good one yet: no age
	if strings.Contains(out, `ffs_backup_age_seconds{scope="accounts"}`) {
		t.Error(out)
	}
	b.Reset()
	backupMetrics(&b, nil, now)
	if b.Len() != 0 {
		t.Error("metrics without backups")
	}
}

func TestOverviewSearchAttentionAndDevices(t *testing.T) {
	fake := &fakeFxa{allDevices: [][]driver.Value{{fakeUID, int64(1700000000000), float64(1700000100000), fakeRef}}}
	redis, _ := fakeRedis(t)
	app := testApp()
	app.fxa, app.sync, app.alerter, app.staleDays = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}, 30
	app.health = newHealth(app)
	h := app.routes()
	c, _ := passwordSession(t, app, h)
	page := getPage(h, "/", c).Body.String()
	// the fake account has an unconfirmed sign-in and an old device
	for _, want := range []string{`<section id="attention">`, `with a sign-in that never entered its email code`, `href="/users/` + fakeUID + `">Accounts</a>`,
		`1 device of 1 account not used for 30 days`, `href="/users/` + fakeUID + `#devices"`, `<span class="badge">1 inactive device</span>`,
		`<tr data-email="` + fakeEmail + `">`, `<span id="accounts-total">1</span>`} {
		if !strings.Contains(page, want) {
			t.Errorf("overview: no %q", want)
		}
	}
	for q, found := range map[string]bool{"ALICE": true, "0123abcd": true, "example.com": true, "bob": false} {
		page := getPage(h, "/?q="+url.QueryEscape(q), c).Body.String()
		if strings.Contains(page, `<tr data-email="`+fakeEmail+`">`) != found || strings.Contains(page, "No account matches.") == found {
			t.Errorf("search %q: found %v", q, !found)
		}
		if !strings.Contains(page, `value="`+q+`"`) || !strings.Contains(page, `id="search-result"`) {
			t.Errorf("search %q: not kept in the form", q)
		}
	}
	page = getPage(h, "/?show=blocked", c).Body.String()
	if strings.Contains(page, `<tr data-email=`) || !strings.Contains(page, `<input type="hidden" name="show" value="blocked">`) ||
		!strings.Contains(page, `id="search-result">0 accounts blocked by the rate limits.`) {
		t.Error("filter blocked")
	}
	if page := getPage(h, "/?show=unconfirmed-sign-in", c).Body.String(); !strings.Contains(page, `<tr data-email="`+fakeEmail+`">`) {
		t.Error("filter unconfirmed sign-in")
	}
	user := getPage(h, "/users/"+fakeUID, c).Body.String()
	if !strings.Contains(user, `<span class="badge">inactive</span>`) || !strings.Contains(user, "not used for 30 days (ADMIN_STALE_DAYS)") {
		t.Errorf("device badge: %s", user)
	}
	app.staleDays = 365 * 100
	if user := getPage(h, "/users/"+fakeUID, c).Body.String(); strings.Contains(user, `<span class="badge">inactive</span>`) {
		t.Error("a device used within ADMIN_STALE_DAYS marked inactive")
	}
}

func TestOverviewShowsBackupsAndPages(t *testing.T) {
	page := pages(t)["dashboard.html"]
	for _, want := range []string{`<li>Sync server is down: x. <a href="#health">Health</a></li>`,
		`<p class="hint" data-scope="sync">Last backup of the Sync databases: `, `2.0 KB, <span class="ok">ok</span>.`,
		`<p class="hint" data-scope="accounts">Last backup of the accounts databases: `, `<span class="disabled">failed</span>: access denied (the last good one: `,
		`<span id="accounts-shown">1–50</span> of <span id="accounts-total">60</span>, newest first, page 1 of 2.`, `<a href="/?page=2#accounts" rel="next" id="older">`} {
		if !strings.Contains(page, want) {
			t.Errorf("no %q", want)
		}
	}
	if strings.Contains(page, `id="all-good"`) || strings.Contains(page, `id="newer"`) {
		t.Error("all good, or a link to newer accounts on the first page")
	}
}

// sessionRedis: a Redis that answers MGET from caches by key (others: no key), counting
// its connections
func sessionRedis(t *testing.T, caches map[string]string) (string, *atomic.Int32) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	var conns atomic.Int32
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			conns.Add(1)
			go func() {
				defer conn.Close()
				r := bufio.NewReader(conn)
				for {
					cmd, err := readReply(r)
					args, _ := cmd.([]any)
					if err != nil || len(args) == 0 || args[0] != "MGET" {
						return
					}
					var out strings.Builder
					fmt.Fprintf(&out, "*%d\r\n", len(args)-1)
					for _, k := range args[1:] {
						if v, ok := caches[k.(string)]; ok {
							fmt.Fprintf(&out, "$%d\r\n%s\r\n", len(v), v)
						} else {
							out.WriteString("$-1\r\n")
						}
					}
					conn.Write([]byte(out.String()))
				}
			}()
		}
	}()
	return ln.Addr().String(), &conns
}

func TestInactiveDevicesOneRedisConnection(t *testing.T) {
	used, broken, plain := fakeUID, strings.Repeat("b", 32), strings.Repeat("c", 32)
	recent := time.Now().UnixMilli()
	redis, conns := sessionRedis(t, map[string]string{
		"fxa-auth-session" + used:   fmt.Sprintf(`{"%s":[%d]}`, fakeToken, recent),
		"fxa-auth-session" + broken: `{"x": broken`,
	})
	old := int64(1700000000000)
	fake := &fakeFxa{allDevices: [][]driver.Value{
		{used, old, float64(old), fakeRef},   // used lately, per Redis
		{broken, old, float64(old), fakeRef}, // its cache unreadable: left out
		{plain, old, float64(old), "r1"},     // no cache: the database's times
		{plain, old, float64(old), "r2"},
	}}
	inactive, err := fake.db(redis).InactiveDevices(context.Background(), time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(inactive) != 1 || inactive[plain] != 2 {
		t.Errorf("inactive %v", inactive)
	}
	if n := conns.Load(); n != 1 {
		t.Errorf("%d Redis connections", n)
	}
	// Redis away: an error, no guess
	if _, err := fake.db("127.0.0.1:1").InactiveDevices(context.Background(), time.Now().Add(-time.Hour)); err == nil {
		t.Error("no error without Redis")
	}
}
