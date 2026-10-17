package main

import (
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

// TestSizeOfNow: on MySQL the sizes are read past the cache of information_schema (a
// day by default), MariaDB has no such variable, PostgreSQL no such cache
func TestSizeOfNow(t *testing.T) {
	for _, tc := range []struct {
		name    string
		setErr  error
		size    int64
		failing bool
	}{
		{"mysql", nil, 42, false},
		{"mariadb", &mysql.MySQLError{Number: 1193, Message: "Unknown system variable 'information_schema_stats_expiry'"}, 42, false},
		{"down", errors.New("down"), 0, true},
	} {
		fake := &fakeFxa{
			execErr: func(query string, _ []driver.Value) error {
				if strings.HasPrefix(query, "SET SESSION information_schema_stats_expiry = 0") {
					return tc.setErr
				}
				return nil
			},
			answer: func(query string, _ []driver.Value) *fakeRows {
				if strings.Contains(query, "data_length + index_length") || strings.Contains(query, "FROM ffs.database_sizes") {
					return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{int64(42)}}}
				}
				return nil
			},
		}
		sync, fxa := &SyncDB{db: sql.OpenDB(fake)}, fake.db("")
		for what, size := range map[string]func() (int64, error){"sync": func() (int64, error) { return sync.Size(t.Context()) }, "fxa": func() (int64, error) { return fxa.Size(t.Context()) }} {
			n, err := size()
			if n != tc.size || (err != nil) != tc.failing {
				t.Errorf("%s %s: %d %v", tc.name, what, n, err)
			}
		}
		if got := len(fake.statements()); got != 2 {
			t.Errorf("%s: %d SET", tc.name, got)
		}
	}
	// PostgreSQL: its own size, no SET
	fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
		if strings.Contains(query, "pg_database_size") {
			return &fakeRows{cols: []string{"n"}, rows: [][]driver.Value{{int64(7)}}}
		}
		return nil
	}}
	if n, err := (&SyncDB{db: sql.OpenDB(fake), postgres: true}).Size(t.Context()); n != 7 || err != nil || len(fake.statements()) != 0 {
		t.Errorf("postgres: %d %v %q", n, err, fake.statements())
	}
}

// hourly measures of a database for days, growing perDay(d) on the day d days ago
func hourlySizes(now time.Time, days int, perDay func(d int) int64) []sizeSample {
	var samples []sizeSample
	size := int64(1 << 30)
	for h := days * 24; h >= 0; h-- {
		samples = append(samples, sizeSample{now.Add(-time.Duration(h) * time.Hour), size})
		// the hour after this measure, in the day (h-1)/24 days ago
		size += perDay((h-1)/24) / 24
	}
	return samples
}

func TestGrowthOf(t *testing.T) {
	now := time.Now()
	c := growthConfig{mb: 1024, factor: 5}
	mb := int64(1 << 20)
	steady := func(int) int64 { return 24 * mb }
	if _, ok := growthOf("x", hourlySizes(now, 0, steady), now, c); ok {
		t.Error("less than a day: compared")
	}
	g, ok := growthOf("Sync storage", hourlySizes(now, 1, steady), now, c)
	if !ok || g.PerDay != 24*mb || g.Days != 0 || g.Alert {
		t.Errorf("a day: %+v", g)
	}
	// 2 GB in the last day, the rest steady: ADMIN_DB_GROWTH_MB, even without history
	spike := func(d int) int64 {
		if d == 0 {
			return 2048 * mb
		}
		return 24 * mb
	}
	g, _ = growthOf("Sync storage", hourlySizes(now, 1, spike), now, c)
	if !g.Alert || !strings.Contains(g.line(), "The database Sync storage grew 2.0 GB in the last day, more than ADMIN_DB_GROWTH_MB (1024 MB)") {
		t.Errorf("over the MB: %+v %q", g, g.line())
	}
	// 240 MB after days of 24: 10 times the usual, once there are 3 days of history
	tenfold := func(d int) int64 {
		if d == 0 {
			return 240 * mb
		}
		return 24 * mb
	}
	if g, _ := growthOf("x", hourlySizes(now, 3, tenfold), now, c); g.Alert || g.Days != 2 {
		t.Errorf("two days of history: %+v", g)
	}
	g, _ = growthOf("Sync storage", hourlySizes(now, 8, tenfold), now, c)
	if !g.Alert || g.Days != growthDays || g.Usual != 24*mb || !strings.Contains(g.line(), "more than 5 times its usual 24.0 MB a day (ADMIN_DB_GROWTH_FACTOR)") {
		t.Errorf("tenfold: %+v %q", g, g.line())
	}
	// small: 10 times 1 MB is under growthFloor
	small := func(d int) int64 {
		if d == 0 {
			return 10 * mb
		}
		return mb
	}
	if g, _ := growthOf("x", hourlySizes(now, 8, small), now, c); g.Alert {
		t.Errorf("a small database: %+v", g)
	}
	// purged: shrinking is no growth, the median ignores it
	if g, _ := growthOf("x", hourlySizes(now, 8, func(d int) int64 { return -100 * mb }), now, c); g.Alert || g.PerDay >= 0 || g.Usual != 0 {
		t.Errorf("shrinking: %+v", g)
	}
	// off, each and both
	if g, _ := growthOf("x", hourlySizes(now, 8, spike), now, growthConfig{factor: 5}); !g.Alert || !strings.Contains(g.Reason, "ADMIN_DB_GROWTH_FACTOR") {
		t.Errorf("ADMIN_DB_GROWTH_MB=0: %+v", g)
	}
	if g, _ := growthOf("x", hourlySizes(now, 1, spike), now, growthConfig{factor: 5}); g.Alert {
		t.Errorf("ADMIN_DB_GROWTH_MB=0, without history: %+v", g)
	}
	if g, _ := growthOf("x", hourlySizes(now, 8, tenfold), now, growthConfig{mb: 1024}); g.Alert {
		t.Errorf("ADMIN_DB_GROWTH_FACTOR=0 still alerts: %+v", g)
	}
	if (growthConfig{}).on() {
		t.Error("both 0: on")
	}
	// a gap: no measure within 2 hours of a day ago
	var gap []sizeSample
	for _, s := range hourlySizes(now, 2, steady) {
		if d := now.Sub(s.at); d < 21*time.Hour || d > 27*time.Hour {
			gap = append(gap, s)
		}
	}
	if _, ok := growthOf("x", gap, now, c); ok {
		t.Error("compared over a gap")
	}
	t.Setenv("ADMIN_DB_GROWTH_MB", "")
	t.Setenv("ADMIN_DB_GROWTH_FACTOR", "")
	if got := growthSettings(); got != c {
		t.Errorf("defaults %+v", got)
	}
}

func TestWatchGrowth(t *testing.T) {
	now := time.Now()
	mb := int64(1 << 20)
	var storage, tokens []sizeSample
	fake := &fakeFxa{answer: func(query string, _ []driver.Value) *fakeRows {
		if strings.Contains(query, "FROM ffs_gauges WHERE minute >= ? AND name LIKE 'db.size.%'") {
			rows := &fakeRows{cols: []string{"minute", "name", "value"}}
			for _, s := range storage {
				rows.rows = append(rows.rows, []driver.Value{s.at.UnixMilli(), "db.size.Sync storage", s.bytes})
			}
			for _, s := range tokens {
				rows.rows = append(rows.rows, []driver.Value{s.at.UnixMilli(), "db.size.Tokenserver", s.bytes})
			}
			return rows
		}
		return nil
	}}
	app := testApp()
	app.sync, app.alerter = &SyncDB{db: sql.OpenDB(fake)}, &Alerter{}
	app.rec = &Recorder{db: app.sync}
	h := newHealth(app)
	h.growth = growthConfig{mb: 1024, factor: 5}
	app.health = h
	if _, ok := growthRow(h.Growth(), h.growth, false); ok {
		t.Error("a row before the first measure")
	}
	round := func() []string {
		h.watchGrowth(t.Context(), now)
		return app.alerter.take()
	}
	// an hour of history: a row that says so
	storage = hourlySizes(now, 0, func(int) int64 { return 0 })
	if got := round(); len(got) != 0 {
		t.Errorf("no history: %q", got)
	}
	row, ok := growthRow(h.Growth(), h.growth, true)
	if !ok || !row.Up || !strings.Contains(row.Detail, "from a day of history on") {
		t.Errorf("row %+v", row)
	}
	steady := func(int) int64 { return 24 * mb }
	storage, tokens = hourlySizes(now, 8, func(d int) int64 {
		if d == 0 {
			return 1500 * mb
		}
		return 24 * mb
	}), hourlySizes(now, 8, steady)
	got := round()
	if len(got) != 1 || !strings.Contains(got[0], "attention: The database Sync storage grew 1.5 GB in the last day, more than ADMIN_DB_GROWTH_MB (1024 MB)") {
		t.Errorf("growth: %q", got)
	}
	if got := round(); len(got) != 0 {
		t.Errorf("alerted twice: %q", got)
	}
	row, _ = growthRow(h.Growth(), h.growth, true)
	if !row.Warn || row.Label != "growing fast" || !strings.HasPrefix(row.Error, "The database Sync storage grew") {
		t.Errorf("row %+v", row)
	}
	list := needsAttention(attentionInput{now: now, components: []Component{row}})
	if len(list) != 1 || list[0].Href != "/activity" {
		t.Errorf("needs attention %+v", list)
	}
	var b strings.Builder
	thresholdMetrics(&b, h)
	for _, want := range []string{`ffs_database_growth_bytes{database="Sync storage"} ` + "1572864000", `ffs_database_growth_alert{database="Sync storage"} 1`,
		`ffs_database_growth_alert{database="Tokenserver"} 0`} {
		if !strings.Contains(b.String(), want+"\n") {
			t.Errorf("no %q in %s", want, b.String())
		}
	}
	storage = hourlySizes(now, 8, steady)
	if got := round(); len(got) != 1 || !strings.Contains(got[0], "The database Sync storage grows as usual again (+24.0 MB in the last day)") {
		t.Errorf("as usual: %q", got)
	}
	row, _ = growthRow(h.Growth(), h.growth, true)
	if !row.Up || row.Detail != "Sync storage +24.0 MB, Tokenserver +24.0 MB in the last day" {
		t.Errorf("row %+v", row)
	}
}
