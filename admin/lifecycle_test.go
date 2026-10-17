package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

var t0 = time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

// row: a users row of alice, created at t0 + minutes
func row(id int64, state string, keys int64, minutes int, replaced bool) UserRow {
	r := UserRow{ID: id, Email: "alice@api.example.com", ClientState: state, KeysChangedAt: keys, NodeID: 1, Node: "https://sync.example.com",
		NodeKnown: true, CreatedAt: t0.Add(time.Duration(minutes) * time.Minute)}
	if replaced {
		r.ReplacedAt = r.CreatedAt.Add(time.Minute)
	}
	return r
}

func flagNames(rows []UserRow) []string {
	markCurrent(rows)
	var names []string
	for _, f := range diagnose(rows) {
		if f.Text == "" {
			names = append(names, "no text: "+f.Name)
		}
		names = append(names, f.Name)
	}
	return names
}

func TestDiagnoseFlags(t *testing.T) {
	// a key change done right: the old row replaced, a new client state with a newer date
	clean := []UserRow{row(1, "aa", 1000, 0, true), row(2, "bb", 2000, 5, false)}
	clean[1].Usage.Items = 5
	if got := flagNames(clean); len(got) != 0 {
		t.Errorf("clean history: %v", got)
	}
	if !clean[1].Current || clean[0].Current {
		t.Errorf("current: %+v", clean)
	}

	cases := map[string][]UserRow{
		"Several current rows":        {row(1, "aa", 1000, 0, false), row(2, "bb", 2000, 5, false)},
		"Keys went back in time":      {row(1, "aa", 2000, 0, true), row(2, "bb", 1000, 5, false)},
		"Keys changed without a date": {row(1, "aa", 1000, 0, true), row(2, "bb", 1000, 5, false)},
	}
	unknown := []UserRow{row(1, "aa", 1000, 0, false)}
	unknown[0].NodeKnown, unknown[0].Node = false, ""
	cases["Unknown node"] = unknown
	downed := []UserRow{row(1, "aa", 1000, 0, false)}
	downed[0].Downed = true
	cases["Node retired"] = downed
	left := []UserRow{row(1, "aa", 1000, 0, true), row(2, "bb", 2000, 5, false)}
	left[0].Usage.Items = 7
	cases["Data left on old keys"] = left
	for want, rows := range cases {
		for i := range rows {
			if rows[i].Usage.Items == 0 && rows[i].ID == 2 && want != "Data left on old keys" {
				rows[i].Usage.Items = 1
			}
		}
		if want == "Unknown node" || want == "Node retired" {
			rows[0].Usage.Items = 1
		}
		got := flagNames(rows)
		if len(got) != 1 || got[0] != want {
			t.Errorf("%s: %v", want, got)
		}
	}
	// generation is not looked at (always 0 with OAuth), nor the same client state again
	same := []UserRow{row(1, "aa", 1000, 0, true), row(2, "aa", 1000, 5, false)}
	same[1].Usage.Items = 1
	if got := flagNames(same); len(got) != 0 {
		t.Errorf("same keys: %v", got)
	}
	// the current row: the newest not replaced, or the newest
	all := []UserRow{row(3, "aa", 1000, 0, true), row(4, "bb", 2000, 5, true)}
	if markCurrent(all); !all[1].Current || all[0].Current {
		t.Errorf("all replaced: %+v", all)
	}
	// seconds or milliseconds in X-KeyID
	if got := row(1, "aa", 1700000000, 0, false).KeysChanged(); !got.Equal(time.Unix(1700000000, 0)) {
		t.Errorf("seconds: %v", got)
	}
	if got := row(1, "aa", 1700000000123, 0, false).KeysChanged(); !got.Equal(time.UnixMilli(1700000000123)) {
		t.Errorf("milliseconds: %v", got)
	}
}

func TestSecondPassScheduling(t *testing.T) {
	fake := &fakeFxa{}
	app := testApp()
	app.sync, app.storage, app.rec = &SyncDB{db: sql.OpenDB(fake)}, &StorageDB{db: sql.OpenDB(fake)}, fakeRecorder(fake)
	app.scheduleSecondPass([]int64{7, 9}, "alice@example.com (uid 0123)", t0)
	app.scheduleSecondPass(nil, "nobody", t0)
	app.runSecondPasses(context.Background(), t0.Add(secondPassAfter-time.Second))
	if got := fake.statements(); len(got) != 0 {
		t.Fatalf("ran before its time: %q", got)
	}
	if secondPassAfter < time.Hour+5*time.Minute {
		t.Errorf("before the Sync tokens (1 hour) and the checked access tokens (5 minutes) run out: %v", secondPassAfter)
	}
	app.runSecondPasses(context.Background(), t0.Add(secondPassAfter))
	var deletes []string
	for _, s := range fake.statements() {
		if strings.HasPrefix(s, "DELETE FROM bso ") {
			deletes = append(deletes, s)
		}
	}
	if len(deletes) != 2 || deletes[0] != "DELETE FROM bso WHERE userid = ? LIMIT 1000" {
		t.Errorf("storage deleted: %q", fake.statements())
	}
	if got := inserted(fake, "maintenance"); len(got) != 1 || !strings.Contains(got[0], "Second pass on the Sync storage of alice@example.com (uid 0123): 6 items") {
		t.Errorf("event: %q", got)
	}
	// once
	n := len(fake.statements())
	app.runSecondPasses(context.Background(), t0.Add(3*secondPassAfter))
	if len(fake.statements()) != n {
		t.Error("ran twice")
	}
}

func TestOrphanClassification(t *testing.T) {
	now := t0.Add(48 * time.Hour)
	at := func(h int) time.Time { return t0.Add(time.Duration(h) * time.Hour) }
	rows := []UserRow{
		// alice: current, replaced two days ago (orphan), replaced an hour ago (kept a day)
		{ID: 1, Email: "alice@api.example.com", CreatedAt: at(0), ReplacedAt: at(1)},
		{ID: 2, Email: "alice@api.example.com", CreatedAt: at(1), ReplacedAt: at(47)},
		{ID: 3, Email: "alice@api.example.com", CreatedAt: at(47)},
		// bob deleted his account: both rows, the current one too
		{ID: 4, Email: "bob@api.example.com", CreatedAt: at(0), ReplacedAt: at(1)},
		{ID: 5, Email: "bob@api.example.com", CreatedAt: at(1)},
		// carol: another domain, not an account here: listed apart
		{ID: 6, Email: "carol@old.example.com", CreatedAt: at(0)},
		// dave: another domain, an account here: his rows are his
		{ID: 8, Email: "Dave@old.example.com", CreatedAt: at(0)},
	}
	markCurrent(rows)
	usage := map[int64]StoredUsage{
		1: {Live: Usage{Items: 2, Bytes: 20}}, 3: {Live: Usage{Items: 9}}, 5: {Live: Usage{Items: 4, Bytes: 40}, Expired: Usage{Items: 1, Bytes: 10}},
		6: {Live: Usage{Items: 1}},
		// no row: an old one, one newer than every row but changed long ago, one just written
		// below the highest uid (a deleted row), one just written above it (a row created since)
		7:  {Live: Usage{Items: 3, LastModified: now}},
		90: {Live: Usage{Items: 1, LastModified: at(1)}},
		91: {Live: Usage{Items: 1, LastModified: now.Add(-time.Minute)}},
	}
	accounts := map[string]bool{"alice": true, "dave": true}
	orphans, others := classifyOrphans(rows, usage, accounts, "api.example.com", now)
	type got struct {
		kind string
		rows int
		ids  string
	}
	var list []got
	for _, o := range orphans {
		var ids []string
		for _, id := range o.Storage {
			ids = append(ids, strconv.FormatInt(id, 10))
		}
		list = append(list, got{o.Kind, len(o.Rows), strings.Join(ids, ",")})
	}
	want := []got{{orphanReplaced, 1, "1"}, {orphanDeleted, 2, "4,5"}, {orphanNoRow, 0, "7"}, {orphanNoRow, 0, "90"}}
	if len(list) != len(want) {
		t.Fatalf("orphans: %+v", list)
	}
	for i := range want {
		if list[i] != want[i] {
			t.Errorf("orphan %d: %+v, want %+v", i, list[i], want[i])
		}
	}
	if orphans[1].Usage.Items != 5 || orphans[1].Usage.Bytes != 50 {
		t.Errorf("bob's usage, expired too: %+v", orphans[1].Usage)
	}
	if len(others) != 1 || others[0].Email != "carol@old.example.com" || others[0].Usage.Items != 1 {
		t.Errorf("other domains: %+v", others)
	}
	// Mozilla's accounts (or the accounts database not read): no deleted accounts, nor other domains
	orphans, others = classifyOrphans(rows, usage, nil, "api.example.com", now)
	for _, o := range orphans {
		if o.Kind == orphanDeleted {
			t.Errorf("deleted without the accounts: %+v", o)
		}
	}
	if len(others) != 0 || len(orphans) != 4 { // alice's, bob's replaced, the two without a row
		t.Errorf("without the accounts: %+v %+v", orphans, others)
	}
}

// multiRows: the result sets of a CALL, as the MySQL driver gives them
type multiRows struct {
	sets [][][]driver.Value
	cols [][]string
	read *int // sets read to their end
}

func (r *multiRows) Columns() []string { return r.cols[0] }
func (r *multiRows) Close() error      { return nil }
func (r *multiRows) Next(dest []driver.Value) error {
	if len(r.sets[0]) == 0 {
		return io.EOF
	}
	copy(dest, r.sets[0][0])
	r.sets[0] = r.sets[0][1:]
	return nil
}
func (r *multiRows) HasNextResultSet() bool { return len(r.sets) > 1 }
func (r *multiRows) NextResultSet() error {
	if len(r.sets) < 2 {
		return io.EOF
	}
	*r.read++
	r.sets, r.cols = r.sets[1:], r.cols[1:]
	return nil
}

type callDriver struct{ rows func() *multiRows }

func (d callDriver) Connect(context.Context) (driver.Conn, error) { return callConn(d), nil }
func (d callDriver) Driver() driver.Driver                        { return nil }

type callConn callDriver

func (c callConn) Prepare(string) (driver.Stmt, error) { return nil, driver.ErrSkip }
func (c callConn) Close() error                        { return nil }
func (c callConn) Begin() (driver.Tx, error)           { return nil, io.ErrUnexpectedEOF }
func (c callConn) QueryContext(context.Context, string, []driver.NamedValue) (driver.Rows, error) {
	return c.rows(), nil
}

func TestPruneDrainsTheResultSets(t *testing.T) {
	read := 0
	// prune_10's own SELECTs first (the lock, the window, the uids), then ours
	db := sql.OpenDB(callDriver{func() *multiRows {
		return &multiRows{read: &read, cols: [][]string{{"@lockAcquired := GET_LOCK('fxa-auth-server.prune-lock', 3)"}, {"uid"}, {"RELEASE_LOCK('fxa-auth-server.prune-lock')"},
			{"unblock_codes", "signin_codes", "account_tokens", "sessions", "oauth_codes", "security_events"}},
			sets: [][][]driver.Value{{{int64(1)}}, {{[]byte("x")}, {[]byte("y")}}, {{int64(1)}}, {{int64(2), int64(0), int64(1), int64(3), int64(4), int64(5)}}}}
	}})
	db.SetMaxOpenConns(1)
	f := &FxaDB{db: db}
	counts, err := f.Prune(context.Background(), t0, t0.AddDate(0, 0, -30))
	if err != nil {
		t.Fatal(err)
	}
	if read != 3 || counts.String() != "2 unblock codes, 0 sign-in codes, 1 reset and password tokens, 3 sessions without a device, 4 OAuth codes, 5 security events" {
		t.Errorf("read %d sets: %v", read, counts)
	}
	// and the connection is free again
	if _, err := f.Prune(context.Background(), t0, t0); err != nil {
		t.Error(err)
	}
	// a procedure that answers without its counts
	none := &FxaDB{db: sql.OpenDB(callDriver{func() *multiRows {
		return &multiRows{read: &read, cols: [][]string{{"x"}}, sets: [][][]driver.Value{{{int64(1)}}}}
	}})}
	if _, err := none.Prune(context.Background(), t0, t0); err == nil {
		t.Error("no counts accepted")
	}
}

func TestProceduresTakeTheDatabaseTime(t *testing.T) {
	prune := policyStmt(t, fxaPolicySQL, "ffs.prune")
	for _, want := range []string{"SET v_now = LEAST(p_now, UNIX_TIMESTAMP() * 1000)", "SET v_events_before = LEAST(p_events_before, v_now - 86400000)",
		"CALL fxa.prune_10(v_now,", "securityEvents WHERE createdAt < v_events_before", "CAST(v_now AS CHAR)"} {
		if !strings.Contains(prune, want) {
			t.Errorf("ffs.prune without %q", want)
		}
	}
	if strings.Contains(strings.SplitN(prune, "BEGIN", 2)[1], "p_events_before;") || strings.Contains(prune, "prune_10(p_now") {
		t.Errorf("ffs.prune uses the caller's times: %s", prune)
	}
	del := policyStmt(t, fxaPolicySQL, "ffs.delete_unconfirmed")
	if !strings.Contains(del, "SET v_before = LEAST(p_before, UNIX_TIMESTAMP() * 1000 - 86400000)") || !strings.Contains(del, "a.createdAt < v_before") ||
		!strings.Contains(del, "a.uid = p_uid") || !strings.Contains(del, errNotUnconfirmed) {
		t.Errorf("ffs.delete_unconfirmed: %s", del)
	}
}

func TestDeleteUnconfirmedNamesThemAndStopsPartway(t *testing.T) {
	uid := func(c byte) string { return strings.Repeat(string(c), 32) }
	fake := &fakeFxa{unconfirmed: [][]driver.Value{
		{uid('a'), "a@example.com", int64(1)}, {uid('b'), "b@example.com", int64(2)}, {uid('c'), "c@example.com", int64(3)}, {uid('d'), "d@example.com", int64(4)}}}
	fake.execErr = func(query string, args []driver.Value) error {
		if query != "CALL ffs.delete_unconfirmed(?, ?)" {
			return nil
		}
		switch strings.ToLower(hex.EncodeToString(args[0].([]byte))) {
		case uid('b'): // confirmed since it was listed
			return &mysql.MySQLError{Number: 1644, SQLState: [5]byte{'4', '5', '0', '0', '0'}, Message: errNotUnconfirmed}
		case uid('d'):
			return errors.New("connection lost")
		}
		return nil
	}
	app := testApp()
	app.fxa, app.sync = fake.db("127.0.0.1:1"), &SyncDB{db: sql.OpenDB(fake)}
	deleted, err := app.deleteUnconfirmedAccounts(context.Background(), t0)
	var partial *partialError
	if len(deleted) != 2 || deleted[0].Email != "a@example.com" || deleted[1].Email != "c@example.com" || !errors.As(err, &partial) ||
		!strings.Contains(err.Error(), "stopped after 2 of 4: connection lost") {
		t.Fatalf("deleted %+v: %v", deleted, err)
	}
	notes := 0
	for _, q := range fake.statements() {
		if q == "DELETE FROM ffs_account_notes WHERE uid = ?" {
			notes++
		}
	}
	if notes != 2 {
		t.Errorf("notes removed: %d", notes)
	}
	if got := unconfirmedResult(deleted, 3); got != "Deleted 2 accounts that never confirmed their email in 3 days: a@example.com, c@example.com" {
		t.Errorf("result: %q", got)
	}
	// nothing deleted: a plain error, no change to record
	fake.execErr = func(string, []driver.Value) error { return errors.New("down") }
	if deleted, err := app.fxa.DeleteUnconfirmed(context.Background(), t0); len(deleted) != 0 || err == nil || errors.As(err, &partial) {
		t.Errorf("all failed: %+v %v", deleted, err)
	}
	// many: the emails that fit in an event, then how many more
	var many []FxaAccount
	for i := 0; i < 100; i++ {
		many = append(many, FxaAccount{Email: fmt.Sprintf("user%03d@example.com", i)})
	}
	got := unconfirmedResult(many, 30)
	if len(got) > 400 || !strings.Contains(got, ": user000@example.com, user001@example.com") || !regexp.MustCompile(` and \d+ more$`).MatchString(got) {
		t.Errorf("many: %d %q", len(got), got)
	}
}

func TestAutomaticPurgeGuards(t *testing.T) {
	orphans := func(kinds ...string) []Orphan {
		var list []Orphan
		for _, k := range kinds {
			list = append(list, Orphan{Kind: k})
		}
		return list
	}
	for _, c := range []struct {
		name          string
		rep           StorageReport
		syncing       int
		deleted, rows bool
	}{
		{"one account of several deleted", StorageReport{Orphans: orphans(orphanDeleted), AccountCount: 4, RowCount: 5, StorageUsers: 5}, 5, false, false},
		{"the only account, the accounts database empty", StorageReport{Orphans: orphans(orphanDeleted), AccountCount: 0, RowCount: 1, StorageUsers: 1}, 1, true, false},
		{"the only one of one", StorageReport{Orphans: orphans(orphanDeleted), AccountCount: 3, RowCount: 1, StorageUsers: 1}, 1, true, false},
		{"most deleted", StorageReport{Orphans: orphans(orphanDeleted, orphanDeleted, orphanDeleted), AccountCount: 2, RowCount: 5, StorageUsers: 5}, 5, true, false},
		{"tokenserver count unknown", StorageReport{Orphans: orphans(orphanDeleted), AccountCount: 9, RowCount: 9, StorageUsers: 9}, -1, true, false},
		{"one uid without a row", StorageReport{Orphans: orphans(orphanNoRow), AccountCount: 4, RowCount: 4, StorageUsers: 5}, 4, false, false},
		{"the users table empty", StorageReport{Orphans: orphans(orphanNoRow), AccountCount: 4, RowCount: 0, StorageUsers: 4}, 0, false, true},
		{"most of the storage without a row", StorageReport{Orphans: orphans(orphanNoRow, orphanNoRow, orphanNoRow), AccountCount: 4, RowCount: 2, StorageUsers: 5}, 2, false, true},
		{"replaced keys only", StorageReport{Orphans: orphans(orphanReplaced, orphanReplaced), RowCount: 3, StorageUsers: 3}, 1, false, false},
	} {
		deleted, rows := skipOrphans(&c.rep, c.syncing)
		if deleted != c.deleted || rows != c.rows {
			t.Errorf("%s: skip deleted %v, without a row %v", c.name, deleted, rows)
		}
	}
}

func TestSignupBurst(t *testing.T) {
	h := &Health{}
	for _, c := range []struct {
		count, threshold int
		at               time.Duration
		want             bool
	}{
		{10, 10, 0, false},                // at the threshold
		{11, 10, 0, true},                 // above
		{30, 10, 30 * time.Minute, false}, // once an hour
		{30, 10, 61 * time.Minute, true},
		{5, 10, 3 * time.Hour, false},
		{500, 0, 5 * time.Hour, false}, // 0: never
	} {
		if got := h.signupBurst(c.count, c.threshold, t0.Add(c.at)); got != c.want {
			t.Errorf("%d new accounts (threshold %d) at +%v: %v", c.count, c.threshold, c.at, got)
		}
	}
}

func TestDailyJobs(t *testing.T) {
	jobs := map[string]Job{"prune": {Name: "prune", LastRun: t0}, "purge": {Name: "purge", LastRun: t0.Add(-25 * time.Hour)}}
	due := dueJobs([]string{"prune", "purge", "delete-unconfirmed"}, jobs, t0.Add(23*time.Hour))
	if strings.Join(due, " ") != "purge delete-unconfirmed" {
		t.Errorf("due: %v", due)
	}
	if due := dueJobs([]string{"prune"}, jobs, t0.Add(24*time.Hour)); len(due) != 1 {
		t.Errorf("a day later: %v", due)
	}
	// a failed run: again an hour later, not a day
	failed := map[string]Job{"prune": {Name: "prune", LastRun: t0, Failed: true}}
	if due := dueJobs([]string{"prune"}, failed, t0.Add(59*time.Minute)); len(due) != 0 {
		t.Errorf("failed, 59 minutes later: %v", due)
	}
	if due := dueJobs([]string{"prune"}, failed, t0.Add(time.Hour)); len(due) != 1 {
		t.Errorf("failed, an hour later: %v", due)
	}
	list := jobList([]string{"prune"}, jobs)
	if len(list) != 2 || !list[0].On || list[1].On || list[1].Name != "purge" {
		t.Errorf("listed: %+v", list)
	}
}

func TestDeleteOnlyDisabledWithTheEmail(t *testing.T) {
	fake := &fakeFxa{}
	redis, _ := fakeRedis(t)
	app := testApp()
	app.fxa, app.sync = fake.db(redis), &SyncDB{db: sql.OpenDB(fake)}
	h := app.routes()
	c, s := passwordSession(t, app, h)
	path := "/users/" + fakeUID + "/delete"
	// active: not offered, and refused
	if w := getPage(h, path, c); w.Code != 404 {
		t.Errorf("confirm page of an active account: %d", w.Code)
	}
	// the procedure's refusal, as it says it
	post(h, path, url.Values{"csrf": {s.csrf}, "confirm_email": {fakeEmail}}, c, nil)
	if s.failed != "only a disabled account can be deleted: disable it first" || strings.Join(fake.statements(), " ") != "CALL ffs.delete_account(?)" {
		t.Errorf("active account: %q %q", s.failed, fake.statements())
	}
	fake.mu.Lock()
	fake.execs, fake.args = nil, nil
	fake.mu.Unlock()
	fake.disabled = true
	w := getPage(h, path, c)
	if page := w.Body.String(); w.Code != 200 || !strings.Contains(page, "Delete "+fakeEmail+"?") || !strings.Contains(page, `<label for="confirm_email">Type the email of the account`) {
		t.Fatalf("confirm page: %d %s", w.Code, page)
	}
	// the email typed must match
	w = post(h, path, url.Values{"csrf": {s.csrf}, "confirm_email": {"bob@example.com"}}, c, nil)
	if w.Header().Get("Location") != path || !strings.Contains(s.failed, "nothing deleted") || len(fake.statements()) != 0 {
		t.Errorf("wrong email: %s %q %q", w.Header().Get("Location"), s.failed, fake.statements())
	}
	w = post(h, path, url.Values{"csrf": {s.csrf}, "confirm_email": {" Alice@Example.com "}}, c, nil)
	// and its note: personal data, with no page left to remove it from
	if got := fake.statements(); len(got) != 2 || got[0] != "CALL ffs.delete_account(?)" || got[1] != "DELETE FROM ffs_account_notes WHERE uid = ?" || w.Header().Get("Location") != "/" {
		t.Errorf("delete: %q %s %q", got, w.Header().Get("Location"), s.failed)
	}
	if !strings.HasPrefix(s.message, "Deleted alice@example.com (uid "+fakeUID+") and its Sync data") {
		t.Errorf("message: %q", s.message)
	}
}

// once the account is gone from the accounts service, what fails after is shown and in
// the audit trail, the deletion with it
func TestDeleteAuditsWhatFailsAfter(t *testing.T) {
	for _, c := range []struct {
		name, redis, failing string
		message, failed      string
	}{
		{"Redis down", "127.0.0.1:1", "", "Deleted alice@example.com (uid " + fakeUID + ") and its Sync data", "account deleted, but its access tokens are still valid"},
		{"tokenserver rows", "", "CALL ffs_delete_user_row", "Deleted alice@example.com (uid " + fakeUID + "), but only part of its Sync data", "the Sync data was not all deleted"},
		{"the note", "", "DELETE FROM ffs_account_notes", "Deleted alice@example.com (uid " + fakeUID + ") and its Sync data", "its note was not removed"},
	} {
		t.Run(c.name, func(t *testing.T) {
			fake := &fakeFxa{disabled: true, users: [][]driver.Value{{int64(7), fakeUID + "@api.example.com", "aaaa", int64(0), int64(1), "https://sync.example.com", int64(0), int64(1), int64(1700000000000), int64(0)}}}
			fake.execErr = func(query string, _ []driver.Value) error {
				if c.failing != "" && strings.HasPrefix(query, c.failing) {
					return errors.New("database gone")
				}
				return nil
			}
			redis := c.redis
			if redis == "" {
				redis, _ = fakeRedis(t)
			}
			app := testApp()
			app.fxa, app.alerter, app.sync = fake.db(redis), &Alerter{}, &SyncDB{db: sql.OpenDB(fake)}
			h := app.routes()
			cookie, s := passwordSession(t, app, h)
			app.alerter.take()
			post(h, "/users/"+fakeUID+"/delete", url.Values{"csrf": {s.csrf}, "confirm_email": {fakeEmail}, "reason": {"asked"}}, cookie, nil)
			if !strings.HasPrefix(s.message, c.message) || !strings.Contains(s.failed, c.failed) {
				t.Errorf("shown: %q / %q", s.message, s.failed)
			}
			lines := alerts(t, app.alerter, 1)
			if len(lines) != 1 || !strings.Contains(lines[0], "admin: "+c.message) || !strings.Contains(lines[0], c.failed) {
				t.Errorf("audit: %q", lines)
			}
		})
	}
}

// storageAnswers: a MySQL storage database where only bob (uid 7, deleted from the
// accounts database) stores anything, and syncing accounts use Sync
func storageAnswers(syncing int64) func(string, []driver.Value) *fakeRows {
	return func(query string, _ []driver.Value) *fakeRows {
		switch {
		case strings.HasPrefix(query, "SELECT COUNT(*), COALESCE(MAX(last_modified), 0) FROM user_collections"):
			return &fakeRows{cols: []string{"n", "last"}, rows: [][]driver.Value{{int64(1), int64(1700000000000)}}}
		case strings.HasPrefix(query, "SELECT userid, CASE WHEN ttl"):
			return &fakeRows{cols: []string{"id", "live", "n", "bytes"}, rows: [][]driver.Value{{int64(7), int64(1), int64(3), int64(300)}}}
		case strings.HasPrefix(query, "SELECT userid, MAX(last_modified) FROM user_collections"):
			return &fakeRows{cols: []string{"id", "last"}, rows: [][]driver.Value{{int64(7), int64(1700000000000)}}}
		case strings.HasPrefix(query, "SELECT COUNT(*) FROM batch_uploads"), strings.Contains(query, "information_schema.tables"):
			return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{int64(0)}}}
		case strings.HasPrefix(query, "SELECT COUNT(*), COALESCE(SUM(LENGTH(payload)), 0) FROM batch_upload_items"):
			return &fakeRows{cols: []string{"n", "bytes"}, rows: [][]driver.Value{{int64(0), int64(0)}}}
		case query == "SELECT COUNT(DISTINCT email) FROM users":
			return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{syncing}}}
		case strings.HasPrefix(query, "CALL ffs.prune("):
			return &fakeRows{cols: []string{"unblock_codes", "signin_codes", "account_tokens", "sessions", "oauth_codes", "security_events"},
				rows: [][]driver.Value{{int64(1), int64(0), int64(0), int64(2), int64(0), int64(3)}}}
		}
		return nil
	}
}

// bob's rows in the tokenserver: an account the accounts database (alice only) no longer has
var bobRows = [][]driver.Value{{int64(7), strings.Repeat("b", 32) + "@api.example.com", "aaaa", int64(0), int64(1), "https://sync.example.com", int64(0), int64(1), int64(1700000000000), int64(0)}}

func jobsApp(fake *fakeFxa) *App {
	app := testApp()
	app.fxa, app.sync, app.storage, app.rec = fake.db("127.0.0.1:1"), &SyncDB{db: sql.OpenDB(fake)}, &StorageDB{db: sql.OpenDB(fake)}, fakeRecorder(fake)
	app.emailDomain, app.unconfirmedDays, app.autoPurge = "api.example.com", 30, true
	return app
}

func TestAutomaticJobs(t *testing.T) {
	ctx := context.Background()
	fake := &fakeFxa{users: bobRows, answer: storageAnswers(5),
		unconfirmed: [][]driver.Value{{strings.Repeat("c", 32), "carol@example.com", int64(1)}}}
	app := jobsApp(fake)
	storage := app.storage
	app.storage = nil
	if got := strings.Join(app.enabledJobs(), " "); got != "prune delete-unconfirmed" {
		t.Errorf("without a storage database: %q", got)
	}
	app.storage = storage
	if got := app.enabledJobs(); !slices.Contains(got, "purge") {
		t.Errorf("with a storage database: %q", got)
	}
	app.autoPurge, app.unconfirmedDays = false, 0
	if got := strings.Join(app.enabledJobs(), " "); got != "prune" {
		t.Errorf("only FxA: %q", got)
	}
	app.autoPurge, app.unconfirmedDays = true, 30

	app.dailyJobs(ctx, t0)
	if got := fake.queried("CALL ffs.prune(?, ?)"); len(got) != 1 || got[0][0] != t0.UnixMilli() {
		t.Errorf("prune: %v", got)
	}
	var deleted, upserts []string
	for i, q := range fake.statements() {
		switch {
		case q == "CALL ffs.delete_unconfirmed(?, ?)":
			if before := fake.args[i][1]; before != t0.AddDate(0, 0, -30).UnixMilli() {
				t.Errorf("deleted the unconfirmed before %v", before)
			}
			deleted = append(deleted, q)
		case strings.HasPrefix(q, "INSERT INTO ffs_jobs"):
			upserts = append(upserts, fake.args[i][0].(string))
		}
	}
	if len(deleted) != 1 {
		t.Errorf("unconfirmed deleted: %d", len(deleted))
	}
	if strings.Join(upserts, " ") != "prune purge delete-unconfirmed" {
		t.Errorf("jobs stored: %q", upserts)
	}
	events := inserted(fake, "maintenance")
	if len(events) != 3 || !strings.HasPrefix(events[0], "Pruned the accounts database: 1 unblock codes") ||
		!strings.HasPrefix(events[1], "Purged the Sync storage") || strings.Contains(events[1], "failed") ||
		events[2] != "Deleted 1 accounts that never confirmed their email in 30 days: carol@example.com" {
		t.Errorf("events: %q", events)
	}
	// bob is one of five using Sync: the automatic purge deletes him
	if !deletesStorage(fake, 0) {
		t.Errorf("bob's storage kept: %q", fake.statements())
	}
}

// deletesStorage: whether the statements from n on delete a user's items
func deletesStorage(fake *fakeFxa, n int) bool {
	for _, q := range fake.statements()[n:] {
		if strings.HasPrefix(q, "DELETE FROM bso WHERE userid = ?") {
			return true
		}
	}
	return false
}

// a deleted account that is all of those using Sync: an accounts database that came
// back from another server or an old backup. The daily purge leaves it, the button does not
func TestAutomaticPurgeSkipsDeleted(t *testing.T) {
	ctx := context.Background()
	fake := &fakeFxa{users: bobRows, answer: storageAnswers(1)}
	app := jobsApp(fake)
	res, err := app.purge(ctx, true)
	if err != nil || res.SkippedDeleted != 1 || res.Orphans != 0 {
		t.Fatalf("automatic: %+v %v", res, err)
	}
	if deletesStorage(fake, 0) {
		t.Errorf("automatic purge deleted: %q", fake.statements())
	}
	n := len(fake.statements())
	res, err = app.purge(ctx, false)
	if err != nil || res.SkippedDeleted != 0 || res.Orphans != 1 || res.Rows != 1 || !deletesStorage(fake, n) {
		t.Errorf("by hand: %+v %v %q", res, err, fake.statements()[n:])
	}
	// the note of the deleted account goes with it (personal data, no account page left)
	if notes := noteDeletes(fake, n); len(notes) != 1 || notes[0] != strings.Repeat("b", 32) {
		t.Errorf("notes removed: %q", notes)
	}

	// a replaced row of alice, who is still there: her note stays
	alice := fakeUID + "@api.example.com"
	fake = &fakeFxa{answer: storageAnswers(2), users: append([][]driver.Value{
		{int64(8), alice, "aaaa", int64(0), int64(1), "https://sync.example.com", int64(0), int64(1), int64(1600000000000), int64(1600000000000)},
		{int64(9), alice, "bbbb", int64(0), int64(1), "https://sync.example.com", int64(0), int64(1), int64(1600000000000), int64(0)},
	}, bobRows...)}
	app = jobsApp(fake)
	res, err = app.purge(ctx, false)
	if err != nil || res.Orphans != 2 || res.Rows != 2 {
		t.Errorf("with a replaced row: %+v %v %q", res, err, fake.statements())
	}
	if !slices.Contains(fake.statements(), "CALL ffs_delete_user_row(?)") {
		t.Errorf("replaced row kept: %q", fake.statements())
	}
	if notes := noteDeletes(fake, 0); len(notes) != 1 || notes[0] != strings.Repeat("b", 32) {
		t.Errorf("notes removed: %q", notes)
	}
}

// noteDeletes: the uids whose note was removed, from statement n on
func noteDeletes(fake *fakeFxa, n int) []any {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	var uids []any
	for i := n; i < len(fake.execs); i++ {
		if fake.execs[i] == "DELETE FROM ffs_account_notes WHERE uid = ?" {
			uids = append(uids, fake.args[i][0])
		}
	}
	return uids
}

func TestSignupBurstAlert(t *testing.T) {
	fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
		if query == "SELECT COUNT(*) FROM fxa.accounts WHERE createdAt >= ?" {
			return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{int64(11)}}}
		}
		return nil
	}}
	app := testApp()
	app.fxa, app.alerter, app.signupBurst = fake.db("127.0.0.1:1"), &Alerter{}, 10
	h := newHealthFor(app)
	ctx := context.Background()
	h.watchSignupBurst(ctx, t0)
	lines := app.alerter.take()
	if len(lines) != 1 || !strings.Contains(lines[0], "sign-up burst: 11 new accounts in the last hour, more than ADMIN_SIGNUP_BURST (10)") {
		t.Errorf("alerts: %q", lines)
	}
	if got := fake.queried("FROM fxa.accounts WHERE createdAt >= ?"); len(got) != 1 || got[0][0] != t0.Add(-time.Hour).UnixMilli() {
		t.Errorf("since: %v", got)
	}
	// once an hour
	h.watchSignupBurst(ctx, t0.Add(30*time.Minute))
	if lines := app.alerter.take(); len(lines) != 0 {
		t.Errorf("again within the hour: %q", lines)
	}
	// 0: not even counted
	app.signupBurst = 0
	n := len(fake.queried("createdAt >= ?"))
	h.watchSignupBurst(ctx, t0.Add(3*time.Hour))
	if len(fake.queried("createdAt >= ?")) != n || len(app.alerter.take()) != 0 {
		t.Error("counted with ADMIN_SIGNUP_BURST=0")
	}
}
