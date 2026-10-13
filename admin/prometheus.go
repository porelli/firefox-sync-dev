package main

import (
	"crypto/subtle"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
)

// Prometheus metrics at /metrics, with METRICS_TOKEN as bearer token (no token: off)

var promName = regexp.MustCompile(`[^a-zA-Z0-9_]`)

func promLabel(v string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v)
}

func (a *App) prometheus(w http.ResponseWriter, r *http.Request) {
	token := env("METRICS_TOKEN", "")
	given := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token == "" || subtle.ConstantTimeCompare([]byte(given), []byte(token)) != 1 {
		http.NotFound(w, r)
		return
	}
	ctx := r.Context()
	var b strings.Builder
	gauge := func(name, help string, value int64, labels ...string) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s gauge\n", name, help, name)
		if len(labels) == 2 {
			fmt.Fprintf(&b, "%s{%s=\"%s\"} %d\n", name, labels[0], promLabel(labels[1]), value)
		} else {
			fmt.Fprintf(&b, "%s %d\n", name, value)
		}
	}
	if st, err := a.sync.Status(ctx); err == nil {
		gauge("ffs_sync_accounts", "Accounts using this Sync server", int64(st.Users))
		gauge("ffs_sync_max_users", "Maximum accounts (MAX_USERS)", int64(st.MaxUsers))
	}
	if a.storage != nil {
		if totals, err := a.storage.Totals(ctx); err == nil {
			var items, bytes int64
			for _, u := range totals {
				items += u.Items
				bytes += u.Bytes
			}
			gauge("ffs_sync_stored_items", "Items stored by all accounts", items)
			gauge("ffs_sync_stored_bytes", "Bytes stored by all accounts", bytes)
		}
	}
	if a.fxa != nil {
		if accounts, err := a.fxa.Accounts(ctx); err == nil {
			gauge("ffs_accounts", "Accounts of the self-hosted accounts service", int64(len(accounts)))
		}
	}
	if a.health != nil {
		b.WriteString("# HELP ffs_up Whether a component answers its health check\n# TYPE ffs_up gauge\n")
		for _, c := range a.health.Components() {
			up := 0
			if c.Up {
				up = 1
			}
			fmt.Fprintf(&b, "ffs_up{component=\"%s\"} %d\n", promLabel(c.Name), up)
		}
		b.WriteString("# HELP ffs_database_bytes Size of a database\n# TYPE ffs_database_bytes gauge\n")
		sizes := a.health.Sizes()
		names := make([]string, 0, len(sizes))
		for n := range sizes {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			fmt.Fprintf(&b, "ffs_database_bytes{database=\"%s\"} %d\n", promLabel(n), sizes[n])
		}
	}
	// what the Sync server sent since the admin UI started
	cumulative := a.rec.Cumulative()
	names := make([]string, 0, len(cumulative))
	for n := range cumulative {
		names = append(names, n)
	}
	sort.Strings(names)
	b.WriteString("# HELP ffs_statsd_total statsd metrics of the Sync server (count of events) since the admin UI started\n# TYPE ffs_statsd_total counter\n")
	for _, n := range names {
		fmt.Fprintf(&b, "ffs_statsd_total{name=\"%s\"} %d\n", promLabel(promName.ReplaceAllString(n, "_")), cumulative[n].count)
	}
	b.WriteString("# HELP ffs_statsd_ms_total Sum of the timings of the Sync server since the admin UI started\n# TYPE ffs_statsd_ms_total counter\n")
	for _, n := range names {
		if cumulative[n].total > 0 {
			fmt.Fprintf(&b, "ffs_statsd_ms_total{name=\"%s\"} %g\n", promLabel(promName.ReplaceAllString(n, "_")), cumulative[n].total)
		}
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Write([]byte(b.String()))
}
