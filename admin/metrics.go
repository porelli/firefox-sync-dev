package main

import (
	"context"
	"log"
	"net"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Metrics and the event log, kept in the tokenserver database (ffs_metrics,
// ffs_events) for ADMIN_RETENTION_DAYS. syncstorage-rs (and its tokenserver) send
// statsd metrics over UDP when the admin UI runs, see docker-compose.yml.

const (
	// distinct metric names kept per minute: the UDP port is only reachable from
	// the stack's network, this bounds what a misbehaving sender can store
	maxMetricNames     = 500
	maxEventsPerMinute = 30
)

var metricName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,190}$`)

type metric struct {
	count int64
	total float64 // sum of the values of timers, in ms
}

type Recorder struct {
	db       *SyncDB
	keepDays int

	// events per kind and minute, at most maxEventsPerMinute (refused sign-ups come
	// from anybody)
	eventsMinute int64
	eventsCount  map[string]int

	mu       sync.Mutex
	current  map[string]*metric
	received time.Time // last statsd packet
	// since the start, for Prometheus (counters only grow)
	cumulative map[string]*metric
}

func (r *Recorder) Cumulative() map[string]metric {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make(map[string]metric, len(r.cumulative))
	for k, v := range r.cumulative {
		out[k] = *v
	}
	return out
}

func (r *Recorder) LastReceived() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.received
}

func (s *SyncDB) schema() []string {
	if s.postgres {
		return []string{
			`CREATE TABLE IF NOT EXISTS ffs_metrics (minute BIGINT NOT NULL, name VARCHAR(191) NOT NULL,
				count BIGINT NOT NULL, total DOUBLE PRECISION NOT NULL, PRIMARY KEY (minute, name))`,
			`CREATE TABLE IF NOT EXISTS ffs_events (id BIGSERIAL PRIMARY KEY, at BIGINT NOT NULL,
				kind VARCHAR(32) NOT NULL, detail VARCHAR(512) NOT NULL)`,
			`CREATE INDEX IF NOT EXISTS ffs_events_at ON ffs_events (at)`,
			`CREATE TABLE IF NOT EXISTS ffs_gauges (minute BIGINT NOT NULL, name VARCHAR(191) NOT NULL,
				value BIGINT NOT NULL, PRIMARY KEY (minute, name))`,
		}
	}
	return []string{
		`CREATE TABLE IF NOT EXISTS ffs_metrics (minute BIGINT NOT NULL, name VARCHAR(191) NOT NULL,
			count BIGINT NOT NULL, total DOUBLE PRECISION NOT NULL, PRIMARY KEY (minute, name))`,
		`CREATE TABLE IF NOT EXISTS ffs_events (id BIGINT AUTO_INCREMENT PRIMARY KEY, at BIGINT NOT NULL,
			kind VARCHAR(32) NOT NULL, detail VARCHAR(512) NOT NULL, KEY ffs_events_at (at))`,
		`CREATE TABLE IF NOT EXISTS ffs_gauges (minute BIGINT NOT NULL, name VARCHAR(191) NOT NULL,
			value BIGINT NOT NULL, PRIMARY KEY (minute, name))`,
	}
}

func newRecorder(ctx context.Context, db *SyncDB) (*Recorder, error) {
	for _, stmt := range db.schema() {
		if _, err := db.db.ExecContext(ctx, stmt); err != nil {
			return nil, err
		}
	}
	return &Recorder{db: db, keepDays: envInt("ADMIN_RETENTION_DAYS", 30), current: map[string]*metric{}, cumulative: map[string]*metric{}}, nil
}

// Event records something worth showing in the activity log
func (r *Recorder) Event(kind, detail string) {
	if len(detail) > 512 {
		detail = detail[:512]
	}
	r.mu.Lock()
	if minute := time.Now().Unix() / 60; minute != r.eventsMinute {
		r.eventsMinute, r.eventsCount = minute, map[string]int{}
	}
	r.eventsCount[kind]++
	over := r.eventsCount[kind] > maxEventsPerMinute
	r.mu.Unlock()
	if over {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := r.db.db.ExecContext(ctx, r.db.q("INSERT INTO ffs_events (at, kind, detail) VALUES (?, ?, ?)"),
		time.Now().UnixMilli(), kind, detail); err != nil {
		log.Printf("event log: %v", err)
	}
}

// parseStatsd adds the lines of a statsd packet: name:value|type[|@rate][|#tags]
func (r *Recorder) parseStatsd(packet string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.received = time.Now()
	for _, line := range strings.Split(packet, "\n") {
		name, rest, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok || !metricName.MatchString(name) {
			continue
		}
		fields := strings.Split(rest, "|")
		if len(fields) < 2 {
			continue
		}
		value, err := strconv.ParseFloat(fields[0], 64)
		if err != nil {
			continue
		}
		rate := 1.0
		for _, f := range fields[2:] {
			if strings.HasPrefix(f, "@") {
				if v, err := strconv.ParseFloat(f[1:], 64); err == nil && v > 0 && v <= 1 {
					rate = v
				}
			}
		}
		m := r.current[name]
		if m == nil {
			if len(r.current) >= maxMetricNames {
				continue
			}
			m = &metric{}
			r.current[name] = m
		}
		c := r.cumulative[name]
		if c == nil && len(r.cumulative) < maxMetricNames && r.cumulative != nil {
			c = &metric{}
			r.cumulative[name] = c
		}
		if c == nil {
			c = &metric{}
		}
		switch fields[1] {
		case "c":
			m.count += int64(value / rate)
			c.count += int64(value / rate)
		case "ms", "h", "d":
			m.count++
			m.total += value
			c.count++
			c.total += value
		}
	}
}

func (r *Recorder) listen(ctx context.Context, addr string) error {
	conn, err := net.ListenPacket("udp", addr)
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		conn.Close()
	}()
	log.Printf("metrics (statsd) on udp %s", addr)
	buf := make([]byte, 65535)
	for {
		n, _, err := conn.ReadFrom(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		r.parseStatsd(string(buf[:n]))
	}
}

// run writes the counters of every minute, and drops what is older than the retention
func (r *Recorder) run(ctx context.Context) {
	// how often the counters are written (the tests shorten it)
	tick := time.NewTicker(time.Duration(envInt("METRICS_FLUSH_SECONDS", 60)) * time.Second)
	defer tick.Stop()
	lastPrune := time.Time{}
	for {
		select {
		case <-ctx.Done():
			r.flush()
			return
		case <-tick.C:
			r.flush()
			if time.Since(lastPrune) > time.Hour {
				r.prune()
				lastPrune = time.Now()
			}
		}
	}
}

func (r *Recorder) flush() {
	r.mu.Lock()
	current := r.current
	r.current = map[string]*metric{}
	r.mu.Unlock()
	if len(current) == 0 {
		return
	}
	minute := time.Now().Unix() / 60 * 60 * 1000
	upsert := `INSERT INTO ffs_metrics (minute, name, count, total) VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE count = count + VALUES(count), total = total + VALUES(total)`
	if r.db.postgres {
		upsert = `INSERT INTO ffs_metrics (minute, name, count, total) VALUES ($1, $2, $3, $4)
		ON CONFLICT (minute, name) DO UPDATE SET count = ffs_metrics.count + EXCLUDED.count, total = ffs_metrics.total + EXCLUDED.total`
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for name, m := range current {
		if _, err := r.db.db.ExecContext(ctx, upsert, minute, name, m.count, m.total); err != nil {
			log.Printf("metrics: %v", err)
			return
		}
	}
}

func (r *Recorder) prune() {
	cutoff := time.Now().AddDate(0, 0, -r.keepDays).UnixMilli()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	for _, q := range []string{"DELETE FROM ffs_metrics WHERE minute < ?", "DELETE FROM ffs_events WHERE at < ?", "DELETE FROM ffs_gauges WHERE minute < ?"} {
		if _, err := r.db.db.ExecContext(ctx, r.db.q(q), cutoff); err != nil {
			log.Printf("pruning: %v", err)
		}
	}
}

type Event struct {
	At     time.Time
	Kind   string
	Detail string
}

func (r *Recorder) Events(ctx context.Context, since time.Time, limit int) ([]Event, error) {
	rows, err := r.db.db.QueryContext(ctx, r.db.q("SELECT at, kind, detail FROM ffs_events WHERE at >= ? ORDER BY at DESC LIMIT ?"),
		since.UnixMilli(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []Event
	for rows.Next() {
		var e Event
		var at int64
		if err := rows.Scan(&at, &e.Kind, &e.Detail); err != nil {
			return nil, err
		}
		e.At = time.UnixMilli(at)
		events = append(events, e)
	}
	return events, rows.Err()
}

// A series of the activity page: metrics whose name matches, per bucket
type Series struct {
	Title  string
	Total  int64
	Points []int64
}

type MetricTotal struct {
	Name  string
	Count int64
	AvgMs float64
}

// series of the activity charts: name prefixes (after the statsd label) to sum
var chartSeries = []struct {
	title   string
	include []string
	exclude string
}{
	{"Sync requests", []string{"syncstorage.request."}, ".error."},
	{"Sync tokens issued", []string{"syncstorage.token_creation"}, ""},
	{"Errors", []string{"syncstorage.request.error.", "syncstorage.oauth.error.", "syncstorage.error.", "syncstorage.tokenserver.error."}, ""},
}

func (r *Recorder) Activity(ctx context.Context, since time.Time, bucket time.Duration) ([]Series, []MetricTotal, error) {
	rows, err := r.db.db.QueryContext(ctx, r.db.q("SELECT minute, name, count, total FROM ffs_metrics WHERE minute >= ?"), since.UnixMilli())
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	n := int(time.Since(since)/bucket) + 1
	series := make([]Series, len(chartSeries))
	for i, c := range chartSeries {
		series[i] = Series{Title: c.title, Points: make([]int64, n)}
	}
	totals := map[string]*MetricTotal{}
	timers := map[string]float64{}
	for rows.Next() {
		var minute, count int64
		var name string
		var total float64
		if err := rows.Scan(&minute, &name, &count, &total); err != nil {
			return nil, nil, err
		}
		i := int(time.UnixMilli(minute).Sub(since) / bucket)
		if i < 0 || i >= n {
			continue
		}
		for s, c := range chartSeries {
			if matches(name, c.include, c.exclude) {
				series[s].Points[i] += count
				series[s].Total += count
			}
		}
		t := totals[name]
		if t == nil {
			t = &MetricTotal{Name: name}
			totals[name] = t
		}
		t.Count += count
		timers[name] += total
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	list := make([]MetricTotal, 0, len(totals))
	for name, t := range totals {
		if timers[name] > 0 && t.Count > 0 {
			t.AvgMs = timers[name] / float64(t.Count)
		}
		list = append(list, *t)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Count > list[j].Count })
	return series, list, nil
}

func matches(name string, include []string, exclude string) bool {
	if exclude != "" && strings.Contains(name, exclude) {
		return false
	}
	for _, p := range include {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// Gauge records a value now (e.g. the size of a database), replacing one of the same minute
func (r *Recorder) Gauge(name string, value int64) {
	minute := time.Now().Unix() / 60 * 60 * 1000
	upsert := "INSERT INTO ffs_gauges (minute, name, value) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)"
	if r.db.postgres {
		upsert = "INSERT INTO ffs_gauges (minute, name, value) VALUES ($1, $2, $3) ON CONFLICT (minute, name) DO UPDATE SET value = EXCLUDED.value"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := r.db.db.ExecContext(ctx, upsert, minute, name, value); err != nil {
		log.Printf("gauge %s: %v", name, err)
	}
}

type GaugeSeries struct {
	Name   string
	Last   int64
	Points []int64 // last value of each bucket, 0 without one
}

func (r *Recorder) Gauges(ctx context.Context, since time.Time, bucket time.Duration) ([]GaugeSeries, error) {
	rows, err := r.db.db.QueryContext(ctx, r.db.q("SELECT minute, name, value FROM ffs_gauges WHERE minute >= ? ORDER BY minute"), since.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	n := int(time.Since(since)/bucket) + 1
	byName := map[string]*GaugeSeries{}
	var names []string
	for rows.Next() {
		var minute, value int64
		var name string
		if err := rows.Scan(&minute, &name, &value); err != nil {
			return nil, err
		}
		i := int(time.UnixMilli(minute).Sub(since) / bucket)
		if i < 0 || i >= n {
			continue
		}
		g := byName[name]
		if g == nil {
			g = &GaugeSeries{Name: name, Points: make([]int64, n)}
			byName[name] = g
			names = append(names, name)
		}
		g.Points[i], g.Last = value, value
	}
	sort.Strings(names)
	series := make([]GaugeSeries, 0, len(names))
	for _, name := range names {
		series = append(series, *byName[name])
	}
	return series, rows.Err()
}
