package main

import (
	"fmt"
	"html/template"
	"net/http"
	"sort"
	"strings"
	"time"
)

// the account page: what it stores on the Sync server, its devices
func (a *App) userPage(w http.ResponseWriter, r *http.Request, s *session) {
	ctx := r.Context()
	uid := strings.ToLower(r.PathValue("uid"))
	data := a.base(s)
	data["UID"] = uid
	var errs []string

	user, err := a.sync.User(ctx, uid)
	if err != nil {
		errs = append(errs, "Sync users: "+err.Error())
	}
	data["SyncUser"] = user
	if user != nil && a.storage != nil {
		collections, err := a.storage.Collections(ctx, user.StorageID)
		if err != nil {
			errs = append(errs, "Sync storage: "+err.Error())
		}
		var total Usage
		for _, c := range collections {
			total.Items += c.Items
			total.Bytes += c.Bytes
			if c.LastModified.After(total.LastModified) {
				total.LastModified = c.LastModified
			}
		}
		data["Collections"], data["Total"] = collections, total
	}

	if a.fxa != nil {
		data["FxA"] = true
		accounts, err := a.fxa.Accounts(ctx)
		if err != nil {
			errs = append(errs, "Accounts: "+err.Error())
		}
		for _, acc := range accounts {
			if acc.UID == uid {
				acc := acc
				data["Account"] = &acc
			}
		}
		if data["Account"] != nil {
			devices, sessions, err := a.fxa.Devices(ctx, uid)
			if err != nil {
				errs = append(errs, "Devices: "+err.Error())
			}
			data["Devices"], data["Sessions"] = devices, sessions
		}
	}
	if data["Account"] == nil && user == nil && len(errs) == 0 {
		http.NotFound(w, r)
		return
	}
	data["Errors"] = errs
	a.render(w, "user.html", data)
}

var ranges = map[string]struct {
	span, bucket time.Duration
	label        string
}{
	"24h": {24 * time.Hour, time.Hour, "per hour"},
	"7d":  {7 * 24 * time.Hour, 6 * time.Hour, "per 6 hours"},
	"30d": {30 * 24 * time.Hour, 24 * time.Hour, "per day"},
}

// the activity page: metrics of the Sync server and the event log
func (a *App) activityPage(w http.ResponseWriter, r *http.Request, s *session) {
	ctx := r.Context()
	name := r.URL.Query().Get("range")
	rg, ok := ranges[name]
	if !ok {
		name, rg = "24h", ranges["24h"]
	}
	since := time.Now().Add(-rg.span).Truncate(rg.bucket)
	data := a.base(s)
	data["Range"], data["Bucket"], data["Ranges"], data["Since"], data["Received"] = name, rg.label, []string{"24h", "7d", "30d"}, since, a.rec.LastReceived()
	var errs []string

	series, totals, err := a.rec.Activity(ctx, since, rg.bucket)
	if err != nil {
		errs = append(errs, "Metrics: "+err.Error())
	}
	type chart struct {
		Series
		SVG template.HTML
	}
	charts := make([]chart, 0, len(series))
	for _, sr := range series {
		charts = append(charts, chart{sr, barChart(sr.Points)})
	}
	data["Charts"], data["Totals"] = charts, totals
	gauges, err := a.rec.Gauges(ctx, since, rg.bucket)
	if err != nil {
		errs = append(errs, "Database sizes: "+err.Error())
	}
	type gaugeChart struct {
		Name string
		Last int64
		SVG  template.HTML
	}
	gaugeCharts := make([]gaugeChart, 0, len(gauges))
	for _, g := range gauges {
		gaugeCharts = append(gaugeCharts, gaugeChart{strings.TrimPrefix(g.Name, "db.size."), g.Last, barChart(g.Points)})
	}
	data["Gauges"] = gaugeCharts

	events, err := a.rec.Events(ctx, since, 300)
	if err != nil {
		errs = append(errs, "Event log: "+err.Error())
	}
	if a.fxa != nil {
		recent, err := a.fxa.Recent(ctx, since)
		if err != nil {
			errs = append(errs, "Accounts activity: "+err.Error())
		}
		events = append(events, recent...)
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].At.After(events[j].At) })
	if len(events) > 300 {
		events = events[:300]
	}
	data["Events"] = events
	data["Errors"] = errs
	a.render(w, "activity.html", data)
}

// barChart draws the points as an SVG bar chart (numbers only, nothing from users)
func barChart(points []int64) template.HTML {
	const width, height = 600, 80
	var max int64 = 1
	for _, p := range points {
		if p > max {
			max = p
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, `<svg class="chart" viewBox="0 0 %d %d" preserveAspectRatio="none" role="img" aria-label="peak %d">`, width, height, max)
	if n := len(points); n > 0 {
		step := float64(width) / float64(n)
		for i, p := range points {
			h := float64(p) / float64(max) * (height - 2)
			if p > 0 && h < 1 {
				h = 1
			}
			fmt.Fprintf(&b, `<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>`, float64(i)*step+0.5, height-h, step-1, h)
		}
	}
	b.WriteString(`</svg>`)
	return template.HTML(b.String())
}

func humanBytes(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}

func when(t time.Time) string {
	if t.IsZero() {
		return "never"
	}
	return t.UTC().Format("2006-01-02 15:04")
}

func (a *App) signOutDevice(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	uid := strings.ToLower(r.PathValue("uid"))
	err := a.fxa.SignOutDevice(r.Context(), uid, r.PathValue("id"))
	a.doneTo(w, r, s, "/users/"+uid, "Signed out a device of account "+uid, err)
}

func (a *App) signOutSession(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	uid := strings.ToLower(r.PathValue("uid"))
	err := a.fxa.SignOutSession(r.Context(), uid, r.PathValue("ref"))
	a.doneTo(w, r, s, "/users/"+uid, "Signed out a session of account "+uid, err)
}

// the security page: who is being rate limited by the accounts service
func (a *App) securityPage(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	data := a.base(s)
	blocks, attempts, err := a.fxa.RateLimits(r.Context())
	if err != nil {
		data["Errors"] = []string{"Rate limits: " + err.Error()}
	}
	data["Blocks"], data["Attempts"] = blocks, attempts
	a.render(w, "security.html", data)
}

func (a *App) unblock(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	key := r.PostFormValue("key")
	_, on, value, action, _, _, _ := parseRateLimitKey(key)
	err := a.fxa.Unblock(r.Context(), key)
	a.doneTo(w, r, s, "/security", fmt.Sprintf("Lifted the block of %s %s (%s)", on, value, action), err)
}
