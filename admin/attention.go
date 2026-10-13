package main

import (
	"context"
	"fmt"
	"log"
	"net/url"
	"sort"
	"strings"
	"time"
)

// Needs attention: one list at the top of the overview, built from what the overview
// loads anyway, each line with a link to where it is fixed. Three thresholds also
// alert, once per change of their state: accounts at 90% of max users, no metrics from
// a Sync server that is up, alert emails that fail.

const (
	// no statsd packet for this long while the Sync server answers: it lost the admin UI
	statsdSilence = 30 * time.Minute
	// the daily prune of the accounts database
	pruneLate = 48 * time.Hour
)

type attention struct {
	Text string
	Href string // where it is fixed
	Link string // the link's text
}

// attentionInput: what the overview loaded
type attentionInput struct {
	now        time.Time
	components []Component
	certs      map[string]time.Time
	status     *SyncStatus
	backups    []BackupStatus
	storage    *StorageReport
	// self-hosted accounts
	fxa             bool
	accounts        []accountRow
	unconfirmed     int
	pruneLastRan    time.Time
	inactiveDevices map[string]int // per account uid
	staleDays       int
	alerts          *SendStatus // nil without ADMIN_ALERT_EMAIL
	lastStatsd      time.Time
	silenceFrom     time.Time // see Health.silenceFrom
}

// nearMaxUsers: 90% of max users or more are taken (0: no new account at all, not a warning)
func nearMaxUsers(st *SyncStatus) bool {
	return st != nil && st.MaxUsers > 0 && st.Users*10 >= st.MaxUsers*9
}

// statsdSilent: the Sync server answers but its metrics stopped (or never came) for
// statsdSilence since from: it resolved the admin UI before a new container. It reports its
// database pool every few seconds, so a quiet night is not silence
func statsdSilent(syncUp bool, last, from, now time.Time) bool {
	return syncUp && now.Sub(latest(last, from)) >= statsdSilence
}

// silenceFrom: since when no metrics count as silence, the start of the admin UI or the
// Sync server's last coming up (after an outage the old last packet is no measure)
func (h *Health) silenceFrom() time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	return latest(h.started, h.syncUpSince)
}

// alertsFailing: the last alert email could not be sent
func alertsFailing(s *SendStatus) bool {
	return s != nil && s.Err != ""
}

func componentUp(components []Component, name string) bool {
	for _, c := range components {
		if c.Name == name {
			return c.Up
		}
	}
	return false
}

func needsAttention(in attentionInput) []attention {
	var list []attention
	add := func(href, link, format string, args ...any) {
		list = append(list, attention{Text: fmt.Sprintf(format, args...), Href: href, Link: link})
	}
	for _, c := range in.components {
		switch {
		case c.Name == "Email (SMTP)" && !c.Up:
			add("#health", "Health", "The SMTP server does not work (%s): no alerts, invitations or notices go out.", c.Error)
		case c.Name == "Sign-up gate" && c.Warn:
			add("#health", "Health", "Sign-ups bypass the sign-up gate: refused sign-ups see \"Unexpected error\" instead of why.")
		case c.Hidden && !c.Up:
			add("#setup", "Setup", "%s: %s.", c.Name, c.Error)
		case !c.Up && !c.Warn:
			add("#health", "Health", "%s is down: %s.", c.Name, c.Error)
		}
		if c.Latest != "" {
			add("#health", "Health", "%s %s is out, %s runs here.", c.Name, c.Latest, c.Version)
		}
	}
	hosts := make([]string, 0, len(in.certs))
	for host := range in.certs {
		hosts = append(hosts, host)
	}
	sort.Strings(hosts)
	for _, host := range hosts {
		if left := in.certs[host].Sub(in.now); left < certWarnDays*24*time.Hour {
			add("#health", "Health", "The certificate of %s expires in %d days (%s): is its renewal running?", host, int(left/(24*time.Hour)), formatTime(in.certs[host], adminZone))
		}
	}
	if nearMaxUsers(in.status) {
		add("#sync", "Max users", "%d of %d accounts are taken (90%% or more): new accounts are refused once all are.", in.status.Users, in.status.MaxUsers)
	}
	for _, b := range in.backups {
		if p := b.Problem(in.now); p != "" {
			add("#backups", "Backups", "%s.", upperFirst(p))
		}
	}
	if in.storage != nil && in.storage.Orphaned.Bytes > 0 {
		add("/storage/purge", "Purge…", "%s of Sync data nobody reads any more (%d orphans).", humanBytes(in.storage.Orphaned.Bytes), len(in.storage.Orphans))
	}
	if in.fxa {
		var blocked, unconfirmedSignIn []string
		for _, a := range in.accounts {
			if a.Blocked {
				blocked = append(blocked, a.UID)
			}
			if a.Security.UnverifiedSessions > 0 {
				unconfirmedSignIn = append(unconfirmedSignIn, a.UID)
			}
		}
		if len(blocked) > 0 {
			add("/security", "Security", "%s blocked by the rate limits.", plural(len(blocked), "account"))
		}
		if in.unconfirmed > 0 {
			add(filterLink("unconfirmed"), "Accounts", "%s never confirmed their email.", plural(in.unconfirmed, "account"))
		}
		if len(unconfirmedSignIn) > 0 {
			add(accountsLink(unconfirmedSignIn, "unconfirmed-sign-in", ""), "Accounts", "%s with a sign-in that never entered its email code: someone may have the password.",
				plural(len(unconfirmedSignIn), "account"))
		}
		if len(in.inactiveDevices) > 0 {
			devices, uids := 0, make([]string, 0, len(in.inactiveDevices))
			for uid, n := range in.inactiveDevices {
				devices += n
				uids = append(uids, uid)
			}
			sort.Strings(uids)
			add(accountsLink(uids, "inactive-devices", "#devices"), "Devices", "%s of %s not used for %d days (ADMIN_STALE_DAYS): sign them out if they are gone.",
				plural(devices, "device"), plural(len(uids), "account"), in.staleDays)
		}
		if last := in.pruneLastRan; last.IsZero() || in.now.Sub(last) > pruneLate {
			add("/activity#maintenance", "Maintenance", "The accounts database was not pruned for 2 days (last: %s).", whenIn(last, adminZone))
		}
	}
	if alertsFailing(in.alerts) {
		add("#alert-status", "Alert emails", "The last alert email failed on %s: %s.", formatTime(in.alerts.At, adminZone), in.alerts.Err)
	}
	if statsdSilent(componentUp(in.components, "Sync server"), in.lastStatsd, in.silenceFrom, in.now) {
		add("/activity", "Activity", "No metrics from the Sync server for %d minutes while it is up: restart it (docker compose restart syncstorage, or systemctl --user restart firefox-sync-syncstorage.service).",
			int(statsdSilence.Minutes()))
	}
	return list
}

// filterLink: the accounts list showing only those of a badge
func filterLink(show string) string {
	return "/?" + url.Values{"show": {show}}.Encode() + "#accounts"
}

// accountsLink: the account's page when there is one (at anchor), the filtered list otherwise
func accountsLink(uids []string, show, anchor string) string {
	if len(uids) == 1 {
		return "/users/" + url.PathEscape(uids[0]) + anchor
	}
	return filterLink(show)
}

// changed: whether a condition's state differs from the last round (the first round:
// whether it is not ok), for alerts once per change
func (h *Health) changed(key, state string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.states == nil {
		h.states = map[string]string{}
	}
	prev, seen := h.states[key]
	h.states[key] = state
	return (seen && prev != state) || (!seen && state != "ok")
}

// logOnce logs an error of a background check when it is new, not every round
func (h *Health) logOnce(key string, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.logged == nil {
		h.logged = map[string]string{}
	}
	msg := ""
	if err != nil {
		msg = err.Error()
	}
	if msg != "" && msg != h.logged[key] {
		log.Printf("%s: %s", key, msg)
	}
	h.logged[key] = msg
}

// thresholdEvents: the events of the thresholds whose state changed
func (h *Health) thresholdEvents(st *SyncStatus, syncUp bool, lastStatsd time.Time, alerts *SendStatus, now time.Time) []string {
	var events []string
	if st != nil {
		on := nearMaxUsers(st)
		if h.changed("near-max-users", okState(!on)) {
			if on {
				events = append(events, fmt.Sprintf("%d of %d accounts are taken (90%% or more): raise max users, or new accounts are refused once all are", st.Users, st.MaxUsers))
			} else {
				events = append(events, fmt.Sprintf("%d of %d accounts are taken, under 90%% again", st.Users, st.MaxUsers))
			}
		}
	}
	// the Sync server down: its health alerts, the silence keeps its state until it is up
	if silent := statsdSilent(syncUp, lastStatsd, h.silenceFrom(), now); syncUp && h.changed("statsd-silent", okState(!silent)) {
		if silent {
			events = append(events, fmt.Sprintf("No metrics from the Sync server for %d minutes while it is up: restart it", int(statsdSilence.Minutes())))
		} else {
			events = append(events, "Metrics from the Sync server arrive again")
		}
	}
	if alerts != nil {
		failing := alertsFailing(alerts)
		if h.changed("alerts-failing", okState(!failing)) {
			if failing {
				events = append(events, "Alert emails fail: "+alerts.Err)
			} else {
				events = append(events, "Alert emails go out again")
			}
		}
	}
	return events
}

func okState(ok bool) string {
	if ok {
		return "ok"
	}
	return "problem"
}

// watchThresholds: the thresholds of the overview, as events and alerts
func (h *Health) watchThresholds(ctx context.Context, now time.Time) {
	st, err := h.app.sync.Status(ctx)
	if err != nil {
		st = nil
	}
	var alerts *SendStatus
	if h.app.alerter != nil {
		s := h.app.alerter.Status()
		alerts = &s
	}
	var last time.Time
	if h.app.rec != nil {
		last = h.app.rec.LastReceived()
	}
	for _, e := range h.thresholdEvents(st, componentUp(h.Components(), "Sync server"), last, alerts, now) {
		h.app.event("attention", e)
	}
}

// matchAccount: whether a row of the list matches the search q (lower case): part of
// its email, its account id or its note; id: the account of q as a tokenserver uid or an
// address (any of its emails)
func matchAccount(q, uid, email, note, id string) bool {
	if q == "" {
		return true
	}
	return uid == id || strings.Contains(strings.ToLower(email), q) || strings.Contains(uid, q) || strings.Contains(strings.ToLower(note), q)
}

const accountsPerPage = 50

// paginate: rows from to of the page (1, the first; out of range: the nearest), of pages
func paginate(total, page, per int) (from, to, current, pages int) {
	pages = (total + per - 1) / per
	if pages < 1 {
		pages = 1
	}
	current = min(max(page, 1), pages)
	from = (current - 1) * per
	to = min(from+per, total)
	return from, to, current, pages
}

// pager: the links of the accounts list, keeping the search
type pager struct {
	Page, Pages, Total, From, To int
	Prev, Next                   string
}

func newPager(total, page int, q, show string) (pager, int, int) {
	from, to, current, pages := paginate(total, page, accountsPerPage)
	p := pager{Page: current, Pages: pages, Total: total, From: from + 1, To: to}
	if total == 0 {
		p.From = 0
	}
	link := func(n int) string {
		v := url.Values{}
		if q != "" {
			v.Set("q", q)
		}
		if show != "" {
			v.Set("show", show)
		}
		if n > 1 {
			v.Set("page", fmt.Sprint(n))
		}
		if len(v) == 0 {
			return "/#accounts"
		}
		return "/?" + v.Encode() + "#accounts"
	}
	if current > 1 {
		p.Prev = link(current - 1)
	}
	if current < pages {
		p.Next = link(current + 1)
	}
	return p, from, to
}
