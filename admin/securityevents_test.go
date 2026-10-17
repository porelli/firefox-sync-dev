package main

import (
	"database/sql"
	"database/sql/driver"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestAccountEventsSetting(t *testing.T) {
	// as the auth server (convict) reads ACCOUNT_EVENTS_ENABLED: anything but false is true
	for _, c := range []struct {
		value string
		set   bool
		want  bool
	}{{"", false, false}, {"false", true, false}, {"FALSE", true, false}, {"true", true, true}, {"no", true, true}, {"", true, true}} {
		if got := accountEventsOn(c.value, c.set); got != c.want {
			t.Errorf("%q (set %v): %v", c.value, c.set, got)
		}
	}
}

func TestSecurityEventAlerts(t *testing.T) {
	h, alerter := testHealth("")
	h.app.accountEvents = true
	now := h.started.Add(time.Minute)
	event := func(name, ip string, at time.Time) accountSecurityEvent {
		return accountSecurityEvent{SecurityEvent{Name: name, At: at, IP: ip}, fakeUID, fakeEmail}
	}
	events := []accountSecurityEvent{
		event("account.login", "203.0.113.7", now.Add(-20*time.Second)),
		event("account.password_changed", "203.0.113.7", now.Add(-10*time.Second)),
		event("account.two_factor_removed", "", now.Add(-5*time.Second)),
		event("account.recovery_key_added", "198.51.100.2", h.started.Add(-time.Second)),                                              // before the start
		{SecurityEvent{Name: "account.reset", At: now.Add(-time.Second), IP: "198.51.100.2"}, "ffffffffffffffffffffffffffffffff", ""}, // deleted since
		// recorded with account.password_changed on every change: not a reset
		event("account.password_reset_success", "203.0.113.7", now.Add(-10*time.Second)),
	}
	h.securityEvents(events, now, false)
	lines := alerter.take()
	if len(lines) != 3 || !strings.HasSuffix(lines[0], "security: alice@example.com (uid 0123abcd): password changed, from 203.0.113.7") ||
		!strings.HasSuffix(lines[1], "security: alice@example.com (uid 0123abcd): two-step authentication turned off") ||
		!strings.HasSuffix(lines[2], "security: account ffffffffffffffffffffffffffffffff: password reset (forgotten password), from 198.51.100.2") {
		t.Errorf("alerts %q", lines)
	}
	// the next round reads them again (the overlap): nothing new, not counted twice
	h.securityEvents(append(events, event("account.login", "203.0.113.7", now.Add(30*time.Second))), now.Add(time.Minute), false)
	if lines := alerter.take(); len(lines) != 0 {
		t.Errorf("alerted again: %q", lines)
	}
	counts := h.SecurityCounts()
	if counts["account.login"] != 2 || counts["account.password_changed"] != 1 || counts["account.recovery_key_added"] != 0 || len(counts) != 5 {
		t.Errorf("counts %v", counts)
	}
	var b strings.Builder
	securityMetrics(&b, counts)
	if !strings.Contains(b.String(), "# TYPE ffs_security_events_total counter\n") || !strings.Contains(b.String(), `ffs_security_events_total{event="account.login"} 2`) {
		t.Errorf("metrics %s", b.String())
	}
	// forgotten once older than the overlap
	h.securityEvents(nil, now.Add(time.Hour), false)
	if len(h.securitySeen) != 0 {
		t.Errorf("kept %v", h.securitySeen)
	}
	if !alertKinds["security"] || !strings.Contains(strings.Join(eventKinds, ","), "security") {
		t.Error("security: not an alert, or not in the filter of the event log")
	}
}

func TestSecurityAlertsOfMozilla(t *testing.T) {
	// every change of the password, the primary email or a way to sign in or to recover
	// the account (fxa-mono v1.347, the names of lib/routes recordSecurityEvent), labelled
	for _, name := range []string{"account.password_changed", "account.reset", "account.password_added", "account.primary_secondary_swapped",
		"account.two_factor_added", "account.two_factor_removed", "account.two_factor_replace_success",
		"account.recovery_codes_created", "account.recovery_codes_replaced", "account.recovery_key_added", "account.recovery_key_removed",
		"account.passkey.registration_success", "account.passkey.removed",
		"account.recovery_phone_setup_complete", "account.recovery_phone_replace_complete", "account.recovery_phone_removed"} {
		if !securityAlerts[name] {
			t.Errorf("%s not alerted", name)
		}
	}
	for name := range securityAlerts {
		if _, ok := securityEventLabels[name]; !ok {
			t.Errorf("%s alerted without a label", name)
		}
	}
	// what comes with another alerted event: a password change, turning on two-step
	// authentication; and sign-ins
	for _, name := range []string{"account.password_reset_success", "account.recovery_codes_set", "account.login", "account.login.failure", "account.password_upgrade_success"} {
		if securityAlerts[name] {
			t.Errorf("%s alerted", name)
		}
	}
}

func TestSecurityEventsReadInPages(t *testing.T) {
	defer func(page, pages int) { securityPage, securityPages = page, pages }(securityPage, securityPages)
	securityPage, securityPages = 3, 2
	h, alerter := testHealth("")
	h.app.accountEvents = true
	h.started = time.Now().Add(-time.Hour)
	start := h.started
	// a burst of wrong passwords, then the password changed: 7 events, one page of 3 at a time
	var all [][]driver.Value
	for i := range 6 {
		all = append(all, []driver.Value{fakeUID, fakeEmail, "account.login.failure", start.Add(time.Duration(i+1) * time.Second).UnixMilli(), "203.0.113.9"})
	}
	all = append(all, []driver.Value{fakeUID, fakeEmail, "account.password_changed", start.Add(7 * time.Second).UnixMilli(), "203.0.113.9"})
	fake := &fakeFxa{answer: func(query string, args []driver.Value) *fakeRows {
		if !strings.Contains(query, "FROM ffs.security_events e") {
			return nil
		}
		rows := &fakeRows{cols: []string{"uid", "email", "name", "at", "ip"}}
		for _, r := range all {
			if r[3].(int64) >= args[0].(int64) && len(rows.rows) < int(args[1].(int64)) {
				rows.rows = append(rows.rows, r)
			}
		}
		return rows
	}}
	h.app.fxa = fake.db("")
	// first round: 2 pages, both full, read on from the last event the next round
	h.watchSecurityEvents(t.Context())
	if q := fake.queried("FROM ffs.security_events e"); len(q) != 2 || q[0][0] != start.Add(-watchOverlap).UnixMilli() || q[1][0] != start.Add(3*time.Second).UnixMilli() {
		t.Errorf("queries %v", q)
	}
	if lines := alerter.take(); len(lines) != 0 {
		t.Errorf("alerts %q", lines)
	}
	// the second: from the 5th, the change is read (the 5th again, not counted twice)
	h.watchSecurityEvents(t.Context())
	if q := fake.queried("FROM ffs.security_events e"); len(q) != 4 || q[2][0] != start.Add(5*time.Second).UnixMilli() {
		t.Errorf("queries %v", q)
	}
	if lines := alerter.take(); len(lines) != 1 || !strings.HasSuffix(lines[0], "password changed, from 203.0.113.9") {
		t.Errorf("alerts %q", lines)
	}
	if counts := h.SecurityCounts(); counts["account.login.failure"] != 6 || counts["account.password_changed"] != 1 {
		t.Errorf("counts %v", counts)
	}
	// caught up: the next round looks back the overlap only, and reads nothing twice
	h.watchSecurityEvents(t.Context())
	if q := fake.queried("FROM ffs.security_events e"); len(q) != 5 || q[4][0].(int64) < time.Now().Add(-watchOverlap-time.Second).UnixMilli() {
		t.Errorf("queries %v", q)
	}
	if counts := h.SecurityCounts(); counts["account.login.failure"] != 6 || counts["account.password_changed"] != 1 {
		t.Errorf("counted again: %v", counts)
	}
	// a full page in one millisecond cannot stop the watch
	h.lastSecurity = time.Time{}
	h.securitySeen = nil
	same := start.Add(time.Hour)
	var page []accountSecurityEvent
	for range 3 {
		page = append(page, accountSecurityEvent{SecurityEvent{Name: "account.login.failure", At: same}, fakeUID, fakeEmail})
	}
	h.lastSecurity = same
	if !h.securityEvents(page, same.Add(time.Minute), true) || !h.lastSecurity.After(same) {
		t.Errorf("stuck at %v", h.lastSecurity)
	}
}

func TestSecurityEventsWatchOnlyWhenOn(t *testing.T) {
	fake := &fakeFxa{}
	h, _ := testHealth("")
	h.app.fxa = fake.db("")
	h.watchSecurityEvents(t.Context())
	if q := fake.queried("ffs.security_events"); len(q) != 0 {
		t.Errorf("read the history with FXA_ACCOUNT_EVENTS off: %v", q)
	}
	h.app.accountEvents = true
	h.watchSecurityEvents(t.Context())
	if q := fake.queried("FROM ffs.security_events e"); len(q) != 1 {
		t.Errorf("queries %v", q)
	}
}

func TestSecurityHistoryOnTheAccountPage(t *testing.T) {
	for _, on := range []bool{true, false} {
		fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
			if strings.Contains(query, "FROM ffs.security_events WHERE uid") {
				return &fakeRows{cols: []string{"name", "at", "ip", "verified"}, rows: [][]driver.Value{
					{"account.password_changed", int64(1700000500000), "203.0.113.7", int64(1)},
					{"account.login", int64(1700000400000), "203.0.113.7", int64(0)},
					{"account.something_new", int64(1700000300000), "", int64(1)},
				}}
			}
			return nil
		}}
		app := testApp()
		app.fxa, app.sync, app.accountEvents = fake.db(""), &SyncDB{db: sql.OpenDB(fake)}, on
		h := app.routes()
		c, _ := passwordSession(t, app, h)
		page := getPage(h, "/users/"+fakeUID, c).Body.String()
		table := page[strings.Index(page, `<table id="security-events"`):]
		table = table[:strings.Index(table, "</table>")]
		for _, want := range []string{"<td>password changed</td>", "<td>203.0.113.7</td><td>yes</td>", "<td>signed in</td>",
			`<span class="badge">not confirmed</span>`, "<td>account.something_new</td>"} {
			if !strings.Contains(table, want) {
				t.Errorf("on %v: no %q in %s", on, want, table)
			}
		}
		if off := strings.Contains(page, `id="events-off"`); off == on || (!on && !strings.Contains(page, "<code>FXA_ACCOUNT_EVENTS=true</code>")) {
			t.Errorf("on %v: the box to turn them on %v", on, off)
		}
		if q := fake.queried("FROM ffs.security_events WHERE uid"); len(q) != 1 || q[0][1] != int64(securityHistoryRows) {
			t.Errorf("queries %v", q)
		}
	}
	// none yet
	fake := &fakeFxa{}
	app := testApp()
	app.fxa, app.sync, app.accountEvents = fake.db(""), &SyncDB{db: sql.OpenDB(fake)}, true
	h := app.routes()
	c, _ := passwordSession(t, app, h)
	if page := getPage(h, "/users/"+fakeUID, c).Body.String(); !strings.Contains(page, `id="no-security-events"`) || strings.Contains(page, `id="events-off"`) {
		t.Error("an account without events")
	}
}

// metaStore: an admin UI's database whose ffs_meta keeps what is written there, for the
// watch across restarts
func metaStore() (*SyncDB, func() map[string]string) {
	own := &fakeFxa{}
	rows := func() map[string]string {
		own.mu.Lock()
		defer own.mu.Unlock()
		meta := map[string]string{}
		for i, q := range own.execs {
			switch {
			case strings.HasPrefix(q, "INSERT INTO ffs_meta"):
				meta[own.args[i][0].(string)] = own.args[i][1].(string)
			case strings.HasPrefix(q, "DELETE FROM ffs_meta"):
				delete(meta, own.args[i][0].(string))
			}
		}
		return meta
	}
	own.answer = func(query string, args []driver.Value) *fakeRows {
		if !strings.HasPrefix(query, "SELECT name, value FROM ffs_meta") {
			return nil
		}
		found := &fakeRows{cols: []string{"name", "value"}}
		for name, value := range rows() {
			if name == args[0] || strings.HasPrefix(name, strings.TrimSuffix(args[1].(string), "%")) {
				found.rows = append(found.rows, []driver.Value{name, value})
			}
		}
		return found
	}
	return &SyncDB{db: sql.OpenDB(&fakeFxa{}), own: sql.OpenDB(own), ownName: "ffs_admin"}, rows
}

func TestSecurityEventsAcrossRestarts(t *testing.T) {
	ctx := t.Context()
	s, meta := metaStore()
	base := time.Now().Add(-3 * time.Hour).Truncate(time.Millisecond)
	event := func(name string, at time.Duration) accountSecurityEvent {
		return accountSecurityEvent{SecurityEvent{Name: name, At: base.Add(at), IP: "203.0.113.7"}, fakeUID, fakeEmail}
	}
	start := func(at time.Duration) (*Health, *Alerter) {
		h, alerter := testHealth("")
		h.app.accountEvents, h.app.sync, h.started = true, s, base.Add(at)
		h.resumeSecurity(ctx)
		return h, alerter
	}
	round := func(h *Health, events []accountSecurityEvent, at time.Duration) {
		h.securityEvents(events, base.Add(at), false)
		h.saveSecurity(ctx)
	}
	changed := event("account.password_changed", 10*time.Minute)
	// the first start with it: nothing kept, from the start as before
	h, alerter := start(0)
	if from := h.securityFrom(); !from.Equal(base.Add(-watchOverlap)) {
		t.Errorf("first start from %v", from)
	}
	round(h, []accountSecurityEvent{changed}, 11*time.Minute)
	if lines := alerter.take(); len(lines) != 1 || !strings.HasSuffix(lines[0], "password changed, from 203.0.113.7") {
		t.Errorf("alerts %q", lines)
	}
	if m := meta(); m[securityFromKey] != strconv.FormatInt(base.Add(10*time.Minute).UnixMilli(), 10) || len(m) != 2 {
		t.Errorf("kept %v", m)
	}

	// down from 11 minutes to an hour: 2-step on and a recovery key in the meantime, a
	// sign-in too; then a sign-in after the start
	during := []accountSecurityEvent{changed, event("account.two_factor_added", 30*time.Minute),
		event("account.recovery_key_added", 40*time.Minute), event("account.login", 50*time.Minute), event("account.login", 70*time.Minute)}
	h, alerter = start(time.Hour)
	if from := h.securityFrom(); !from.Equal(base.Add(10 * time.Minute)) {
		t.Errorf("after the restart from %v", from)
	}
	round(h, during, 71*time.Minute)
	lines := alerter.take()
	if len(lines) != 2 || !strings.HasSuffix(lines[0], "two-step authentication turned on, from 203.0.113.7") ||
		!strings.HasSuffix(lines[1], "recovery key created, from 203.0.113.7") {
		t.Errorf("the changes while the admin UI was down, once: %q", lines)
	}
	// Prometheus counts since the start
	if counts := h.SecurityCounts(); counts["account.login"] != 1 || counts["account.two_factor_added"] != 0 || len(counts) != 1 {
		t.Errorf("counts %v", counts)
	}

	// restarted again at once: what it reads again was alerted already
	h, alerter = start(72 * time.Minute)
	round(h, during, 73*time.Minute)
	if lines := alerter.take(); len(lines) != 0 {
		t.Errorf("alerted twice: %q", lines)
	}
	// later the kept events are forgotten, here and in ffs_meta
	round(h, nil, 3*time.Hour)
	if m := meta(); len(m) != 1 || m[securityFromKey] != strconv.FormatInt(base.Add(3*time.Hour-watchOverlap).UnixMilli(), 10) {
		t.Errorf("kept %v", m)
	}

	// down longer than ADMIN_RETENTION_DAYS: from that far back only (older ones are pruned)
	s.own.Exec("INSERT INTO ffs_meta (name, value) VALUES (?, ?)", securityFromKey, strconv.FormatInt(time.Now().AddDate(0, 0, -90).UnixMilli(), 10))
	h, _ = start(3 * time.Hour)
	if from := h.securityFrom(); from.Before(time.Now().AddDate(0, 0, -30).Add(-time.Minute)) || from.After(time.Now().AddDate(0, 0, -30)) {
		t.Errorf("from %v, not 30 days back", from)
	}

	// without a database of its own (an install from before ADMIN_DB_PASSWORD): from the start
	h, _ = testHealth("")
	h.app.accountEvents, h.app.sync = true, &SyncDB{db: sql.OpenDB(&fakeFxa{})}
	h.resumeSecurity(ctx)
	h.saveSecurity(ctx)
	if from := h.securityFrom(); !from.Equal(h.started.Add(-watchOverlap)) {
		t.Errorf("without ADMIN_DB_PASSWORD from %v", from)
	}
}
