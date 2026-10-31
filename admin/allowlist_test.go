package main

import (
	"database/sql"
	"database/sql/driver"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	pendingUID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	allowedUID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	rejectUID  = "cccccccccccccccccccccccccccccccc"
)

// allowlistFake: the tokenserver of an allowlist (on: turned on by the init container) with
// one pending uid, one that is no uid (a mock FxA's), one allowed and one rejected; the
// newest event of a refusal at eventAt (0: none)
func allowlistFake(on *bool, eventAt *int64) *fakeFxa {
	fake := &fakeFxa{nodes: [][]driver.Value{}, maxUsers: "10", syncUsers: 1}
	// the refusals whose event is written (ffs_mark_refusal_reported)
	var mu sync.Mutex
	reported := map[string]int64{rejectUID: 1}
	fake.execErr = func(query string, args []driver.Value) error {
		if strings.Contains(query, "ffs_mark_refusal_reported") {
			mu.Lock()
			reported[args[0].(string)] = 1
			mu.Unlock()
		}
		return nil
	}
	fake.answer = func(query string, _ []driver.Value) *fakeRows {
		switch {
		case strings.Contains(query, "config_key = 'allowed_accounts'"):
			n := int64(0)
			if *on {
				n = 1
			}
			return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{n}}}
		case strings.Contains(query, "FROM sync_allowed_accounts"):
			return &fakeRows{cols: []string{"uid", "note", "at", "by", "syncs"},
				rows: [][]driver.Value{{allowedUID, "my phone", int64(1700000000000), "SYNC_ALLOWED_ACCOUNTS", int64(1)}}}
		case strings.Contains(query, "FROM sync_refused_accounts"):
			mu.Lock()
			defer mu.Unlock()
			return &fakeRows{cols: []string{"uid", "first", "last", "attempts", "rejected", "by", "reported"}, rows: [][]driver.Value{
				{pendingUID, int64(1700000300000), int64(1700000400000), int64(3), int64(0), "", reported[pendingUID]},
				{"bob", int64(1700000200000), int64(1700000200000), int64(1), int64(0), "", reported["bob"]},
				{rejectUID, int64(1700000100000), int64(1700000500000), int64(7), int64(1700000150000), "admin (password)", reported[rejectUID]},
			}}
		case strings.Contains(query, "SELECT n.current_load"):
			// the node's load: counted, its accounts (eventAt: the drift)
			return &fakeRows{cols: []string{"load", "accounts"}, rows: [][]driver.Value{{int64(5) + *eventAt, int64(5)}}}
		}
		return nil
	}
	return fake
}

// allowlistApp: the overview on the fake, with Mozilla's accounts (no accounts database)
func allowlistApp(t *testing.T, fake *fakeFxa, editable bool) (*App, http.Handler, *http.Cookie, *session) {
	t.Helper()
	app := testApp()
	app.sync, app.alerter, app.allowlistEditable = &SyncDB{db: sql.OpenDB(fake), own: sql.OpenDB(fake), ownName: "ffs_admin"}, &Alerter{}, editable
	app.health = newHealth(app)
	h := app.routes()
	c, s := passwordSession(t, app, h)
	app.alerter.take()
	return app, h, c, s
}

func TestAllowlistSetting(t *testing.T) {
	for _, c := range []struct {
		value        string
		on, editable bool
	}{
		{"", false, false}, {"  ", false, false}, {"admin", true, true}, {"initial:" + pendingUID, true, true}, {"initial:", true, true},
		{pendingUID, true, false}, {"fixed:" + pendingUID + ", " + allowedUID, true, false}, {" initial: " + pendingUID, true, true},
	} {
		if on, editable := allowlistSetting(c.value); on != c.on || editable != c.editable {
			t.Errorf("%q: on %v editable %v", c.value, on, editable)
		}
	}
	for in, want := range map[string]string{" " + strings.ToUpper(pendingUID) + " ": pendingUID, "bob": "", pendingUID + "a": "", "g" + pendingUID[1:]: ""} {
		got, err := accountUID(in)
		if got != want || (err == nil) != (want != "") {
			t.Errorf("accountUID(%q) = %q, %v", in, got, err)
		}
	}
}

func TestAllowlistOnTheOverview(t *testing.T) {
	on, eventAt := true, int64(0)
	fake := allowlistFake(&on, &eventAt)
	_, h, c, _ := allowlistApp(t, fake, true)
	page := getPage(h, "/", c).Body.String()
	for _, want := range []string{
		`<h2 id="sync-allowlist-title">Invite-only Sync</h2><span class="pill warn">2 pending</span>`,
		`<tr data-uid="` + pendingUID + `"><td><code>` + pendingUID + `</code></td><td>first `,
		`<a href="/sync/allowlist/allow?uid=` + pendingUID + `" class="quiet-link" aria-label="Approve ` + pendingUID + `…">Approve…</a>`,
		`<a href="/sync/allowlist/reject?uid=` + pendingUID + `"`, `<a href="/sync/allowlist/reject?uid=bob"`,
		`<form method="get" action="/sync/allowlist/allow" id="allow-uid">`,
		`<a href="/users/` + allowedUID + `"><code>` + allowedUID + `</code></a>`, `by SYNC_ALLOWED_ACCOUNTS</td><td>my phone</td>`,
		`<a href="/sync/allowlist/remove?uid=` + allowedUID + `"`,
		`<summary>Rejected<span class="hint"> · 1</span></summary>`, `<a href="/sync/allowlist/allow?uid=` + rejectUID + `"`,
		// Needs attention, with the link to the list
		`2 accounts waiting for your approval to sync (SYNC_ALLOWED_ACCOUNTS). <a href="#sync-allowlist">Pending accounts</a>`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("overview: no %q", want)
		}
	}
	// what is no uid can only be rejected
	if strings.Contains(page, "allow?uid=bob") {
		t.Error("overview: bob can be approved")
	}
	// off: no card, no line
	on = false
	page = getPage(h, "/", c).Body.String()
	if strings.Contains(page, "sync-allowlist") || strings.Contains(page, "waiting for your approval") {
		t.Error("off: the allowlist is shown")
	}
}

func TestAllowlistReadOnly(t *testing.T) {
	on, eventAt := true, int64(0)
	fake := allowlistFake(&on, &eventAt)
	_, h, c, s := allowlistApp(t, fake, false)
	page := getPage(h, "/", c).Body.String()
	if strings.Contains(page, "Approve…") || strings.Contains(page, `id="allow-uid"`) || strings.Contains(page, "remove?uid=") ||
		!strings.Contains(page, "<code>SYNC_ALLOWED_ACCOUNTS</code> in .env sets the list on every start") || !strings.Contains(page, "Reject…") {
		t.Errorf("read-only overview: %s", page)
	}
	// a link or a script: refused with why, nothing changed
	w := getPage(h, "/sync/allowlist/allow?uid="+pendingUID, c)
	if w.Code != http.StatusSeeOther || !strings.Contains(s.failed, "managed by SYNC_ALLOWED_ACCOUNTS in .env: set SYNC_ALLOWED_ACCOUNTS=admin") {
		t.Errorf("read-only confirm: %d %q", w.Code, s.failed)
	}
	s.failed = ""
	post(h, "/sync/allowlist/remove", url.Values{"csrf": {s.csrf}, "uid": {allowedUID}}, c, nil)
	if !strings.Contains(s.failed, "managed by SYNC_ALLOWED_ACCOUNTS") || len(fake.statements()) != 0 {
		t.Errorf("read-only remove: %q %q", s.failed, fake.statements())
	}
	// rejecting is no change of the list: it works
	post(h, "/sync/allowlist/reject", url.Values{"csrf": {s.csrf}, "uid": {pendingUID}}, c, nil)
	if got := fake.statements(); len(got) != 1 || got[0] != "CALL ffs_reject_account(?, ?)" || s.message != "Rejected Sync account "+pendingUID {
		t.Errorf("read-only reject: %q %q %q", got, s.message, s.failed)
	}
}

func TestAllowlistConfirmAndChange(t *testing.T) {
	on, eventAt := true, int64(0)
	fake := allowlistFake(&on, &eventAt)
	app, h, c, s := allowlistApp(t, fake, true)
	// Approve: the confirm page says what happens, its form posts the uid
	page := getPage(h, "/sync/allowlist/allow?uid="+strings.ToUpper(pendingUID), c).Body.String()
	for _, want := range []string{"<h1>Allow " + pendingUID + "?</h1>", "This account can start to sync", "It was refused 3 times, first on",
		`<form method="post" action="/sync/allowlist/allow" id="confirm">`, `<input type="hidden" name="uid" value="` + pendingUID + `">`, "Allow the account"} {
		if !strings.Contains(page, want) {
			t.Errorf("confirm allow: no %q", want)
		}
	}
	// the form of Allow a uid: its note on the page and in the form
	page = getPage(h, "/sync/allowlist/allow?uid="+strings.Repeat("d", 32)+"&note=Bob%27s+laptop", c).Body.String()
	if !strings.Contains(page, `<input type="hidden" name="note" value="Bob&#39;s laptop">`) || strings.Contains(page, "It was refused") {
		t.Errorf("confirm allow a uid: %s", page)
	}
	for path, code := range map[string]int{
		"/sync/allowlist/reject?uid=" + allowedUID: http.StatusNotFound, // not pending
		"/sync/allowlist/reject?uid=" + rejectUID:  http.StatusNotFound, // rejected already
		"/sync/allowlist/remove?uid=" + pendingUID: http.StatusNotFound, // not on the list
		"/sync/allowlist/purge?uid=" + pendingUID:  http.StatusNotFound,
		"/sync/allowlist/reject?uid=bob":           http.StatusOK,
		"/sync/allowlist/remove?uid=" + allowedUID: http.StatusOK,
	} {
		if w := getPage(h, path, c); w.Code != code {
			t.Errorf("%s: %d, not %d", path, w.Code, code)
		}
	}
	// not a uid: refused before the database
	getPage(h, "/sync/allowlist/allow?uid=bob", c)
	if !strings.Contains(s.failed, "an account id is 32 hexadecimal characters") {
		t.Errorf("allow bob: %q", s.failed)
	}
	post(h, "/sync/allowlist/allow", url.Values{"csrf": {s.csrf}, "uid": {pendingUID}, "reason": {"my sister"}}, c, nil)
	if s.message != "Approved Sync account "+pendingUID || s.failed != "" {
		t.Errorf("approve: %q %q", s.message, s.failed)
	}
	post(h, "/sync/allowlist/allow", url.Values{"csrf": {s.csrf}, "uid": {strings.Repeat("d", 32)}, "note": {"Bob's laptop"}}, c, nil)
	post(h, "/sync/allowlist/remove", url.Values{"csrf": {s.csrf}, "uid": {allowedUID}}, c, nil)
	if w := post(h, "/sync/allowlist/reject", url.Values{"csrf": {s.csrf}, "uid": {"bob"}}, c, nil); w.Header().Get("Location") != allowlistBack {
		t.Errorf("reject: back to %q", w.Header().Get("Location"))
	}
	var got []string
	for i, q := range fake.statements() {
		if strings.Contains(q, "ffs_mark_refusal_reported") {
			continue
		}
		var args []string
		for _, v := range fake.args[i] {
			args = append(args, v.(string))
		}
		got = append(got, q+" "+strings.ReplaceAll(strings.Join(args, "|"), " ", "_"))
	}
	want := []string{
		"CALL ffs_allow_account(?, ?, ?) " + pendingUID + "||admin_(password)",
		"CALL ffs_allow_account(?, ?, ?) " + strings.Repeat("d", 32) + "|Bob's_laptop|admin_(password)",
		"CALL ffs_remove_allowed_account(?) " + allowedUID,
		"CALL ffs_reject_account(?, ?) bob|admin_(password)",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("statements:\n%s", strings.Join(got, "\n"))
	}
	// each one an audit event, with who and the reason
	lines := strings.Join(alerts(t, app.alerter, 4), "\n")
	for _, want := range []string{"admin: Approved Sync account " + pendingUID + " by admin (password): my sister", "admin: Allowed Sync account " + strings.Repeat("d", 32) + " (note: Bob's laptop) by admin (password)",
		"admin: Removed Sync account " + allowedUID + " from the allowlist by admin (password)", "admin: Rejected Sync account bob by admin (password)"} {
		if !strings.Contains(lines, want) {
			t.Errorf("alerts: no %q in %q", want, lines)
		}
	}
	// PostgreSQL: the functions of allowlist.sql
	app.sync.postgres = true
	post(h, "/sync/allowlist/allow", url.Values{"csrf": {s.csrf}, "uid": {pendingUID}}, c, nil)
	if st := fake.statements(); st[len(st)-1] != "SELECT ffs_allow_account($1, $2, $3)" {
		t.Errorf("postgres: %q", st[len(st)-1])
	}
	// off: nothing to change
	on = false
	n := len(fake.statements())
	post(h, "/sync/allowlist/allow", url.Values{"csrf": {s.csrf}, "uid": {pendingUID}}, c, nil)
	if !strings.Contains(s.failed, "invite-only Sync is off") || len(fake.statements()) != n {
		t.Errorf("off: %q", s.failed)
	}
}

func TestPendingAccountsMetric(t *testing.T) {
	on, eventAt := true, int64(0)
	app := testApp()
	app.sync = &SyncDB{db: sql.OpenDB(allowlistFake(&on, &eventAt))}
	if out := prometheusText(t, app); !strings.Contains(out, "# TYPE ffs_sync_pending_accounts gauge\nffs_sync_pending_accounts 2\n") {
		t.Errorf("metrics: %s", out)
	}
	on = false
	if out := prometheusText(t, app); strings.Contains(out, "ffs_sync_pending_accounts") {
		t.Error("metrics: pending accounts with the allowlist off")
	}
}

func TestWatchRefusals(t *testing.T) {
	on, eventAt := true, int64(0)
	fake := allowlistFake(&on, &eventAt)
	app, _, _, _ := allowlistApp(t, fake, true)
	// both pending ones, oldest first, once each (their rows are marked), the rejected one never
	app.health.watchRefusals(t.Context())
	app.health.watchRefusals(t.Context())
	lines := alerts(t, app.alerter, 3)
	want := []string{"sign-up refused: " + refusalEvent("bob"), "sign-up refused: " + refusalEvent(pendingUID)}
	if len(lines) != 2 || !strings.HasSuffix(lines[0], want[0]) || !strings.HasSuffix(lines[1], want[1]) {
		t.Errorf("first rounds:\n%s", strings.Join(lines, "\n"))
	}
	var marks []string
	for i, q := range fake.statements() {
		if q == "CALL ffs_mark_refusal_reported(?)" {
			marks = append(marks, fake.args[i][0].(string))
		}
	}
	if strings.Join(marks, " ") != "bob "+pendingUID {
		t.Errorf("marked: %q", marks)
	}
	// a restart (a new Health): what the rows say, nothing again
	app.health = newHealth(app)
	app.health.watchRefusals(t.Context())
	if lines := alerts(t, app.alerter, 1); len(lines) != 0 {
		t.Errorf("after a restart: %q", lines)
	}
	// off: nothing read
	on, app.health = false, newHealth(app)
	n := len(fake.queries)
	app.health.watchRefusals(t.Context())
	if len(fake.queries) != n+1 {
		t.Errorf("off: %q", fake.queries[n:])
	}
}

func TestWatchNodeLoad(t *testing.T) {
	on, drift := false, int64(0)
	fake := allowlistFake(&on, &drift)
	app, h, c, _ := allowlistApp(t, fake, true)
	app.syncDomain = "https://sync.example.com"
	resyncs := func() int {
		n := 0
		for _, q := range fake.statements() {
			if q == "CALL ffs_resync_node_load(?)" {
				n++
			}
		}
		return n
	}
	now := time.Now()
	// the load as counted: nothing to do, no check shown
	app.health.watchNodeLoad(t.Context(), now)
	if _, shown := app.health.nodeLoadCheck(now); resyncs() != 0 || shown {
		t.Errorf("no drift: %d resyncs", resyncs())
	}
	// a small drift: counted again (the first time), then not before nodeLoadEvery
	drift = 3
	app.health.watchNodeLoad(t.Context(), now)
	app.health.watchNodeLoad(t.Context(), now.Add(time.Minute))
	if c, shown := app.health.nodeLoadCheck(now); resyncs() != 1 || !shown || !c.OK {
		t.Errorf("small drift: %d resyncs, %+v", resyncs(), c)
	}
	app.health.watchNodeLoad(t.Context(), now.Add(nodeLoadEvery+time.Minute))
	if resyncs() != 2 || fake.args[len(fake.args)-1][0] != "https://sync.example.com" {
		t.Errorf("after nodeLoadEvery: %d resyncs", resyncs())
	}
	// nodeLoadDrift or more: at once, and a warning of the setup checks for a day
	drift = nodeLoadDrift
	app.health.watchNodeLoad(t.Context(), now.Add(nodeLoadEvery+2*time.Minute))
	check, _ := app.health.nodeLoadCheck(now.Add(nodeLoadEvery + 3*time.Minute))
	if resyncs() != 3 || check.OK || !strings.Contains(check.Text, "The tokenserver counted 15 accounts on https://sync.example.com, which has 5") {
		t.Errorf("large drift: %d resyncs, %+v", resyncs(), check)
	}
	page := getPage(h, "/", c).Body.String()
	if !strings.Contains(page, "<td>Sync node load</td><td><span class=\"pill warn\">warning</span>") {
		t.Errorf("overview: no warning of the node's load")
	}
	if check, _ := app.health.nodeLoadCheck(now.Add(nodeLoadShown + time.Hour)); !check.OK {
		t.Errorf("a day later: %+v", check)
	}
}
