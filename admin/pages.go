package main

import (
	"fmt"
	"html/template"
	"math"
	"net/http"
	"sort"
	"strconv"
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
	// every row the tokenserver has for the account, what each stores, what looks wrong
	if rows, flags, err := a.syncRows(ctx, uid); err != nil {
		errs = append(errs, "Sync rows: "+err.Error())
	} else {
		data["Rows"], data["Flags"], data["Storage"] = rows, flags, a.storage != nil
	}

	if a.fxa != nil {
		data["FxA"] = true
		var acc *FxaAccount
		// not an account id (404 below): nothing to ask
		if _, err := accountID(uid); err == nil {
			if acc, err = a.fxa.Account(ctx, uid); err != nil {
				errs = append(errs, "Accounts: "+err.Error())
			}
		}
		if acc != nil {
			data["Account"], data["ContentURL"] = acc, a.contentURL
			devices, sessions, err := a.fxa.Devices(ctx, uid)
			if err != nil {
				errs = append(errs, "Devices: "+err.Error())
			}
			staleBefore := time.Now().AddDate(0, 0, -a.staleDays)
			for i := range devices {
				devices[i].Inactive = latest(devices[i].LastUsed, devices[i].CreatedAt).Before(staleBefore)
			}
			data["StaleDays"] = a.staleDays
			data["Devices"], data["Sessions"] = devices, sessions
			if data["Security"], err = a.fxa.Security(ctx, uid); err != nil {
				errs = append(errs, "Sign-in security: "+err.Error())
			}
			if data["Emails"], err = a.fxa.Emails(ctx, uid); err != nil {
				errs = append(errs, "Emails: "+err.Error())
			}
			blocks, complete, err := a.fxa.BlocksOf(ctx, []FxaAccount{*acc})
			if err != nil {
				errs = append(errs, "Rate limits: "+err.Error())
			} else if !complete {
				errs = append(errs, tooManyBlocks())
			}
			data["Blocks"] = blocks
			// recorded only with FXA_ACCOUNT_EVENTS, those of before (or kept since) too
			data["AccountEvents"] = a.accountEvents
			if data["SecurityEvents"], err = a.fxa.SecurityEvents(ctx, uid, securityHistoryRows); err != nil {
				errs = append(errs, "Security history: "+err.Error())
			}
			data["SecurityHistoryRows"], data["Quadlets"] = securityHistoryRows, a.deployment.Quadlets()
		}
	}
	if data["Account"] == nil && user == nil && len(errs) == 0 {
		http.NotFound(w, r)
		return
	}
	data["MaxNote"] = maxNote
	if data["Note"], err = a.sync.Note(ctx, uid); err != nil {
		errs = append(errs, "Note: "+err.Error())
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
	// the middle of the x axis, and whether the metrics are missing as the overview says
	data["Mid"] = since.Add(time.Since(since) / 2)
	if row, silent := a.metrics(); silent {
		data["Silent"] = row.Error
	}
	var errs []string

	series, totals, errorRows, err := a.rec.Activity(ctx, since, rg.bucket)
	if err != nil {
		errs = append(errs, "Metrics: "+err.Error())
	}
	data["ErrorKinds"] = errorRows
	if a.health != nil {
		if c := a.health.errorRate; c.on() {
			data["ErrorRate"], data["ErrorRateConfig"] = a.health.ErrorRate(), map[string]any{"Percent": c.percent, "Min": c.minErrors}
		}
	}
	type chart struct {
		Series
		SVG  template.HTML
		Peak int64
	}
	// the time span for screen readers: the date axis is hidden from them
	span := fmt.Sprintf(", from %s to now", formatTime(since, adminZone))
	// whether the stored history has anything, received by this process or before
	history := false
	charts := make([]chart, 0, len(series))
	for _, sr := range series {
		p := peak(sr.Points)
		history = history || sr.Total > 0
		charts = append(charts, chart{sr, barChart(sr.Points, fmt.Sprintf("peak %d %s%s", p, rg.label, span)), p})
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
		Peak int64
	}
	gaugeCharts := make([]gaugeChart, 0, len(gauges))
	for _, g := range gauges {
		p := peak(g.Points)
		history = history || p > 0
		gaugeCharts = append(gaugeCharts, gaugeChart{strings.TrimPrefix(g.Name, "db.size."), g.Last, lineChart(g.Points, "peak "+humanBytes(p)+span), p})
	}
	data["Gauges"], data["History"] = gaugeCharts, history
	if a.health != nil {
		data["Started"] = a.health.started
	}

	data["Events"], data["Older"], data["Kind"], data["Q"], data["Paged"], data["Hide"] = a.eventPage(r, &errs)
	data["Kinds"] = eventKinds
	if jobs, err := a.sync.Jobs(ctx); err != nil {
		errs = append(errs, "Maintenance: "+err.Error())
	} else {
		data["Jobs"] = jobList(a.enabledJobs(), jobs)
	}
	data["Errors"], data["Kubernetes"] = errs, a.deployment.Kubernetes()
	a.render(w, "activity.html", data)
}

// the kinds of the event filter: those of the log, then those of the accounts database
// adminSignIn: how the event of an admin's sign-in starts, routine in the log
const adminSignIn = "signed in"

var eventKinds = []string{"admin", "sign-in", "sign-up refused", "health", "update", "blocked", "maintenance", "sign-up burst", "backup", "attention", "security", "sign-up", "new device"}

const eventsPerPage = 100

// eventPage: the events of the log and of the accounts database (sign-ups, new
// devices), newest first, before ?before= (milliseconds), of ?kind=, containing ?q=;
// older is where the next page starts (0: no more)
func (a *App) eventPage(r *http.Request, errs *[]string) (events []Event, older int64, kind, q string, paged, hide bool) {
	ctx := r.Context()
	query := r.URL.Query()
	kind, q = query.Get("kind"), oneLine(strings.TrimSpace(query.Get("q")), 100)
	// ?hide=sign-ins: without the admins' own sign-ins
	hide = query.Get("hide") == "sign-ins"
	before := time.Now().Add(time.Minute)
	if ms, err := strconv.ParseInt(query.Get("before"), 10, 64); err == nil && ms > 0 {
		before, paged = time.UnixMilli(ms), true
	}
	fromFxa := a.fxa != nil && (kind == "" || kind == "sign-up" || kind == "new device")
	// the window of this page: down to the oldest of a full page of the log, the
	// accounts' events in it
	var since time.Time
	if kind != "sign-up" && kind != "new device" {
		logged, err := a.rec.Events(ctx, before, kind, q, hide, eventsPerPage)
		if err != nil {
			*errs = append(*errs, "Event log: "+err.Error())
		}
		if len(logged) == eventsPerPage {
			since = logged[len(logged)-1].At
		}
		events = logged
	}
	if fromFxa {
		recent, err := a.fxa.Recent(ctx, since, before, kind, q, eventsPerPage)
		if err != nil {
			*errs = append(*errs, "Accounts activity: "+err.Error())
		}
		events = append(events, recent...)
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].At.After(events[j].At) })
	if len(events) >= eventsPerPage {
		events = events[:eventsPerPage]
		older = events[len(events)-1].At.UnixMilli()
		// the cursor is a millisecond: the events of the last one go to the next page
		// whole, those past the cut would be on neither (unless the page is one ms)
		n := len(events)
		for n > 0 && events[n-1].At.UnixMilli() == older {
			n--
		}
		if n > 0 {
			events, older = events[:n], older+1
		}
	}
	return events, older, kind, q, paged, hide
}

// chart sizes: the SVG stretches to the width of its box, the lines keep 1 px
const chartWidth, chartHeight = 600, 120

func peak(points []int64) int64 {
	var max int64
	for _, p := range points {
		max = maxInt(max, p)
	}
	return max
}

func maxInt(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// chartGrid: the gridlines at the peak (y) and half of it, and the baseline
func chartGrid(b *strings.Builder, y float64) {
	for _, y := range []float64{y, (y + chartHeight) / 2} {
		fmt.Fprintf(b, `<line class="grid" x1="0" y1="%.1f" x2="%d" y2="%.1f" vector-effect="non-scaling-stroke"/>`, y, chartWidth, y)
	}
	fmt.Fprintf(b, `<line class="base" x1="0" y1="%d" x2="%d" y2="%d" vector-effect="non-scaling-stroke"/>`, chartHeight-1, chartWidth, chartHeight-1)
}

// barChart draws the points as an SVG bar chart (numbers only, nothing from users);
// label is its accessible name, the peak with its unit and the time span
func barChart(points []int64, label string) template.HTML {
	max := maxInt(peak(points), 1)
	var b strings.Builder
	fmt.Fprintf(&b, `<svg class="chart" viewBox="0 0 %d %d" preserveAspectRatio="none" role="img" aria-label="%s">`, chartWidth, chartHeight, template.HTMLEscapeString(label))
	chartGrid(&b, 1)
	if n := len(points); n > 0 {
		step := float64(chartWidth) / float64(n)
		gap := math.Min(2, step/4)
		for i, p := range points {
			h := float64(p) / float64(max) * (chartHeight - 2)
			if p > 0 && h < 2 {
				h = 2
			}
			if p > 0 {
				fmt.Fprintf(&b, `<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>`, float64(i)*step+gap/2, chartHeight-1-h, step-gap, h)
			}
		}
	}
	b.WriteString(`</svg>`)
	return template.HTML(b.String())
}

// lineChart draws a measure (a database size) as a line over an area, from 0 with
// headroom: a size that barely changes is a flat line, not a wall. Points of 0 are
// hours with no measure, left out
func lineChart(points []int64, label string) template.HTML {
	max := maxInt(peak(points), 1)
	top := float64(max) * 1.25
	var b strings.Builder
	fmt.Fprintf(&b, `<svg class="chart line" viewBox="0 0 %d %d" preserveAspectRatio="none" role="img" aria-label="%s">`, chartWidth, chartHeight, template.HTMLEscapeString(label))
	// the peak at 1/5 from the top, where the page puts its label
	chartGrid(&b, chartHeight-1-(chartHeight-2)/1.25)
	n := len(points)
	step := float64(chartWidth) / float64(maxInt(int64(n), 1))
	// one path per run of measured points
	for i := 0; i < n; {
		if points[i] <= 0 {
			i++
			continue
		}
		j := i
		for j < n && points[j] > 0 {
			j++
		}
		y := func(k int) float64 { return chartHeight - 1 - float64(points[k])/top*(chartHeight-2) }
		var line strings.Builder
		x0, x1 := (float64(i)+0.5)*step, (float64(j)-0.5)*step
		if j-i == 1 {
			// a lone point gets the width of its bucket, so it shows
			x0, x1 = float64(i)*step, float64(j)*step
			fmt.Fprintf(&line, "M%.1f %.1f L%.1f %.1f", x0, y(i), x1, y(i))
		} else {
			for k := i; k < j; k++ {
				cmd := "L"
				if k == i {
					cmd = "M"
				}
				fmt.Fprintf(&line, "%s%.1f %.1f ", cmd, (float64(k)+0.5)*step, y(k))
			}
		}
		d := line.String()
		fmt.Fprintf(&b, `<path class="area" d="%s L%.1f %d L%.1f %d Z"/>`, strings.TrimSpace(d), x1, chartHeight-1, x0, chartHeight-1)
		fmt.Fprintf(&b, `<path class="stroke" d="%s" vector-effect="non-scaling-stroke"/>`, strings.TrimSpace(d))
		i = j
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

func (a *App) signOutDevice(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	uid := strings.ToLower(r.PathValue("uid"))
	acc := a.account(r, uid)
	err := a.fxa.SignOutDevice(r.Context(), uid, r.PathValue("id"))
	a.doneTo(w, r, s, "/users/"+uid, "Signed out a device of "+accountLabel(acc, uid), err)
}

func (a *App) signOutSession(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	uid := strings.ToLower(r.PathValue("uid"))
	acc := a.account(r, uid)
	err := a.fxa.SignOutSession(r.Context(), uid, r.PathValue("ref"))
	a.doneTo(w, r, s, "/users/"+uid, "Signed out a session of "+accountLabel(acc, uid), err)
}

// the security page: who is being rate limited by the accounts service
func (a *App) securityPage(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	data := a.base(s)
	limits, err := a.fxa.RateLimits(r.Context())
	if err != nil {
		data["Errors"] = []string{"Rate limits: " + err.Error()}
	} else if !limits.Complete {
		data["Errors"] = []string{tooManyBlocks()}
	}
	data["Blocks"], data["Hidden"], data["Attempts"] = limits.Blocks, limits.Hidden, limits.Attempts
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
	a.doneTo(w, r, s, backTo(r, "/security"), fmt.Sprintf("Lifted the block of %s %s (%s)", on, value, action), err)
}

// jobRow: a job of the Activity page, on or not (it ran before, e.g. ADMIN_PURGE since unset)
type jobRow struct {
	Job
	On bool
}

// jobList: the jobs that are on, then those that ran before, in a fixed order
func jobList(enabled []string, jobs map[string]Job) []jobRow {
	var list []jobRow
	for _, name := range []string{"prune", "purge", "delete-unconfirmed"} {
		j, ran := jobs[name]
		on := false
		for _, e := range enabled {
			on = on || e == name
		}
		if !on && !ran {
			continue
		}
		j.Name = name
		list = append(list, jobRow{j, on})
	}
	return list
}
