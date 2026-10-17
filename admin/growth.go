package main

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"
)

// The growth of the databases per day, from their sizes measured every hour (the
// gauges db.size.*, kept for ADMIN_RETENTION_DAYS). A database alerts when it grew
// more than ADMIN_DB_GROWTH_MB in the last day, or ADMIN_DB_GROWTH_FACTOR times its
// usual growth: the median of the days before (up to growthDays), once there are
// growthMinDays of them, and only from growthFloor a day (a small database that grows
// 5 times 1 MB is no news). Quiet until a day of history.

const (
	growthDays    = 7
	growthMinDays = 3
	growthFloor   = 100 << 20
	// how far a measure may be from the time it stands for (they are hourly)
	growthSlack = 2 * time.Hour
)

type growthConfig struct {
	mb     int64 // a day, 0: off
	factor int64 // 0: off
}

func growthSettings() growthConfig {
	return growthConfig{mb: int64(envInt("ADMIN_DB_GROWTH_MB", 1024)), factor: int64(envInt("ADMIN_DB_GROWTH_FACTOR", 5))}
}

func (c growthConfig) on() bool { return c.mb > 0 || c.factor > 0 }

type sizeSample struct {
	at    time.Time
	bytes int64
}

// DBGrowth: the growth of a database in the last day, against its usual one
type DBGrowth struct {
	Database string
	PerDay   int64 // in the last 24 hours
	Usual    int64 // the median of the days before, when Days >= growthMinDays
	Days     int   // days before the last one with a growth
	Alert    bool
	Reason   string // why it alerts
}

// sizeAt: the measure closest to t, within growthSlack
func sizeAt(samples []sizeSample, t time.Time) (int64, bool) {
	best, found := time.Duration(0), false
	var bytes int64
	for _, s := range samples {
		d := s.at.Sub(t)
		if d < 0 {
			d = -d
		}
		if d <= growthSlack && (!found || d < best) {
			best, bytes, found = d, s.bytes, true
		}
	}
	return bytes, found
}

// growthOf: the growth of a database from its measures, false: not a day of history yet
func growthOf(name string, samples []sizeSample, now time.Time, c growthConfig) (DBGrowth, bool) {
	g := DBGrowth{Database: name}
	day := 24 * time.Hour
	last, ok := sizeAt(samples, now)
	before, ok2 := sizeAt(samples, now.Add(-day))
	if !ok || !ok2 {
		return g, false
	}
	g.PerDay = last - before
	var past []int64
	for k := 1; k <= growthDays; k++ {
		end, ok := sizeAt(samples, now.Add(-time.Duration(k)*day))
		start, ok2 := sizeAt(samples, now.Add(-time.Duration(k+1)*day))
		if ok && ok2 {
			past = append(past, max(end-start, 0))
		}
	}
	g.Days = len(past)
	if g.Days >= growthMinDays {
		sort.Slice(past, func(i, j int) bool { return past[i] < past[j] })
		g.Usual = past[len(past)/2]
	}
	switch {
	case c.mb > 0 && g.PerDay > c.mb<<20:
		g.Alert, g.Reason = true, fmt.Sprintf("more than ADMIN_DB_GROWTH_MB (%d MB)", c.mb)
	case c.factor > 0 && g.Days >= growthMinDays && g.PerDay >= growthFloor && g.PerDay > c.factor*g.Usual:
		g.Alert, g.Reason = true, fmt.Sprintf("more than %d times its usual %s a day (ADMIN_DB_GROWTH_FACTOR)", c.factor, humanBytes(g.Usual))
	}
	return g, true
}

// signedBytes: +12.0 MB, -3.0 KB
func signedBytes(n int64) string {
	if n < 0 {
		return "-" + humanBytes(-n)
	}
	return "+" + humanBytes(n)
}

func (g DBGrowth) line() string {
	return fmt.Sprintf("The database %s grew %s in the last day, %s", g.Database, humanBytes(g.PerDay), g.Reason)
}

// growthCheck: the row of the health table
const growthCheck = "Database growth"

// growthRow: the row of the health table, counted only when a database alerts. none:
// not a day of history yet
func growthRow(growth []DBGrowth, c growthConfig, measured bool) (Component, bool) {
	if !c.on() || !measured {
		return Component{}, false
	}
	row := Component{Name: growthCheck, Limit: true}
	if len(growth) == 0 {
		row.Up, row.Detail = true, "measured every hour, compared from a day of history on"
		return row, true
	}
	var alerts, fine []string
	for _, g := range growth {
		if g.Alert {
			alerts = append(alerts, g.line())
		} else {
			fine = append(fine, g.Database+" "+signedBytes(g.PerDay))
		}
	}
	if len(alerts) > 0 {
		row.Warn, row.Label, row.Error = true, "growing fast", strings.Join(alerts, "; ")
		return row, true
	}
	row.Up, row.Detail = true, strings.Join(fine, ", ")+" in the last day"
	return row, true
}

// SizeHistory: the measures of the databases since, by name (db.size. left out)
func (r *Recorder) SizeHistory(ctx context.Context, since time.Time) (map[string][]sizeSample, error) {
	rows, err := r.db.mine().QueryContext(ctx, r.db.q("SELECT minute, name, value FROM ffs_gauges WHERE minute >= ? AND name LIKE 'db.size.%' ORDER BY minute"), since.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]sizeSample{}
	for rows.Next() {
		var minute, value int64
		var name string
		if err := rows.Scan(&minute, &name, &value); err != nil {
			return nil, err
		}
		name = strings.TrimPrefix(name, "db.size.")
		out[name] = append(out[name], sizeSample{time.UnixMilli(minute), value})
	}
	return out, rows.Err()
}

// watchGrowth: the growth of each database after a measure, its event (and alert) when
// it starts and stops growing fast
func (h *Health) watchGrowth(ctx context.Context, now time.Time) {
	c := h.growth
	if !c.on() || h.app.rec == nil {
		return
	}
	history, err := h.app.rec.SizeHistory(ctx, now.Add(-time.Duration(growthDays+1)*24*time.Hour-growthSlack))
	// "database size: ...", like the errors of the measures (tests/e2e.sh looks for them)
	h.logOnce("database size", err)
	if err != nil {
		return
	}
	names := make([]string, 0, len(history))
	for name := range history {
		names = append(names, name)
	}
	sort.Strings(names)
	var growth []DBGrowth
	for _, name := range names {
		g, ok := growthOf(name, history[name], now, c)
		if !ok {
			continue
		}
		growth = append(growth, g)
		if h.changed("db-growth:"+name, okState(!g.Alert)) {
			if g.Alert {
				h.app.event("attention", g.line())
			} else {
				h.app.event("attention", fmt.Sprintf("The database %s grows as usual again (%s in the last day)", name, signedBytes(g.PerDay)))
			}
		}
	}
	h.mu.Lock()
	h.dbGrowth, h.growthMeasured = growth, true
	h.mu.Unlock()
}

// Growth: the growth of the databases of the last measure (none: not a day of history)
func (h *Health) Growth() []DBGrowth {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]DBGrowth(nil), h.dbGrowth...)
}
