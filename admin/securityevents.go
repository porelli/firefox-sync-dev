package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The security history of the self-hosted accounts: what the auth server records in
// fxa.securityEvents (the Recent activity of the account settings), read through
// ffs.security_events. It only records them with ACCOUNT_EVENTS_ENABLED, which the stack
// sets from FXA_ACCOUNT_EVENTS (off by default: they keep IP addresses), see docs/accounts.md#security-history

// SecurityEvent: one entry of the history of an account
type SecurityEvent struct {
	Name     string // Mozilla's name, e.g. account.password_changed
	At       time.Time
	IP       string
	Verified bool // the sign-in of the event was confirmed (code, second step), then or later
}

// Label: what the event means, Mozilla's name for those without one here
func (e SecurityEvent) Label() string {
	if label, ok := securityEventLabels[e.Name]; ok {
		return label
	}
	return e.Name
}

// the events of fxa.securityEventNames worth a word, the others are shown by their name
var securityEventLabels = map[string]string{
	"account.create":                             "account created",
	"account.login":                              "signed in",
	"account.login.failure":                      "wrong password",
	"account.reset":                              "password reset (forgotten password)",
	"account.password_added":                     "password set",
	"account.password_changed":                   "password changed",
	"account.password_reset_requested":           "password reset requested",
	"account.password_reset_success":             "new password saved",
	"account.password_upgrade_success":           "password upgraded (the same password)",
	"account.password_reset_otp_sent":            "password reset code sent",
	"account.password_reset_otp_verified":        "password reset code entered",
	"account.two_factor_added":                   "two-step authentication turned on",
	"account.two_factor_removed":                 "two-step authentication turned off",
	"account.two_factor_replace_success":         "authenticator app replaced",
	"account.two_factor_challenge_success":       "two-step code entered",
	"account.two_factor_challenge_failure":       "wrong two-step code",
	"account.recovery_key_added":                 "recovery key created",
	"account.recovery_key_removed":               "recovery key removed",
	"account.recovery_key_challenge_success":     "recovery key used",
	"account.recovery_key_challenge_failure":     "wrong recovery key",
	"account.recovery_codes_created":             "backup codes created",
	"account.recovery_codes_replaced":            "backup codes replaced",
	"account.recovery_codes_set":                 "backup codes set (turning on two-step authentication)",
	"account.recovery_codes_signin_complete":     "signed in with a backup code",
	"account.secondary_email_added":              "secondary email added",
	"account.secondary_email_removed":            "secondary email removed",
	"account.primary_secondary_swapped":          "primary email changed",
	"account.signin_confirm_bypass_new_account":  "sign-in code skipped: new account",
	"account.signin_confirm_bypass_known_ip":     "sign-in code skipped: known IP address",
	"account.signin_confirm_bypass_known_device": "sign-in code skipped: known device",
	"account.mfa_send_otp_code":                  "settings change code sent",
	"account.mfa_verify_otp_code_success":        "settings change code entered",
	"account.mfa_verify_otp_code_failed":         "wrong settings change code",
	"session.destroy":                            "signed out",
	"account.passkey.registration_success":       "passkey added",
	"account.passkey.removed":                    "passkey removed",
	"account.passkey.authentication_success":     "signed in with a passkey",
	"account.recovery_phone_setup_complete":      "recovery phone added",
	"account.recovery_phone_replace_complete":    "recovery phone replaced",
	"account.recovery_phone_removed":             "recovery phone removed",
}

// securityAlerts: the events of any account that are recorded in the event log (kind
// security) and alerted: the password, the primary email (where the sign-in codes go) and
// the ways to sign in or to recover the account changed. Not account.password_reset_success:
// in v1.347 Mozilla records it next to account.password_changed on every password change
// (routes/password.ts), a forgotten password reset is account.reset. Not
// account.recovery_codes_set either: the backup codes of turning on two-step
// authentication, alerted as account.two_factor_added
var securityAlerts = map[string]bool{
	"account.password_changed":                true,
	"account.reset":                           true,
	"account.password_added":                  true,
	"account.primary_secondary_swapped":       true,
	"account.two_factor_added":                true,
	"account.two_factor_removed":              true,
	"account.two_factor_replace_success":      true,
	"account.recovery_codes_created":          true,
	"account.recovery_codes_replaced":         true,
	"account.recovery_key_added":              true,
	"account.recovery_key_removed":            true,
	"account.passkey.registration_success":    true,
	"account.passkey.removed":                 true,
	"account.recovery_phone_setup_complete":   true,
	"account.recovery_phone_replace_complete": true,
	"account.recovery_phone_removed":          true,
}

// the account page shows the newest ones
const securityHistoryRows = 50

// SecurityEvents: the history of an account, newest first, at most limit
func (f *FxaDB) SecurityEvents(ctx context.Context, uid string, limit int) ([]SecurityEvent, error) {
	id, err := accountID(uid)
	if err != nil {
		return nil, err
	}
	rows, err := f.db.QueryContext(ctx, `SELECT name, createdAt, COALESCE(ipAddr, ''), COALESCE(verified, 0)
		FROM ffs.security_events WHERE uid = ? ORDER BY createdAt DESC LIMIT ?`, id, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []SecurityEvent
	for rows.Next() {
		var e SecurityEvent
		var at int64
		if err := rows.Scan(&e.Name, &at, &e.IP, &e.Verified); err != nil {
			return nil, err
		}
		e.At = ms(at)
		events = append(events, e)
	}
	return events, rows.Err()
}

// accountSecurityEvent: an event of the history with its account, for the watch
type accountSecurityEvent struct {
	SecurityEvent
	UID, Email string
}

// SecurityEventsSince: the events of every account recorded since, oldest first, at most
// limit
func (f *FxaDB) SecurityEventsSince(ctx context.Context, since time.Time, limit int) ([]accountSecurityEvent, error) {
	rows, err := f.db.QueryContext(ctx, `SELECT LOWER(HEX(e.uid)), COALESCE(a.email, ''), e.name, e.createdAt, COALESCE(e.ipAddr, '')
		FROM ffs.security_events e LEFT JOIN fxa.accounts a ON a.uid = e.uid
		WHERE e.createdAt >= ? ORDER BY e.createdAt LIMIT ?`, since.UnixMilli(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []accountSecurityEvent
	for rows.Next() {
		var e accountSecurityEvent
		var at int64
		if err := rows.Scan(&e.UID, &e.Email, &e.Name, &at, &e.IP); err != nil {
			return nil, err
		}
		e.At = ms(at)
		events = append(events, e)
	}
	return events, rows.Err()
}

// a round reads the new events by pages of this many, oldest first, and at most
// securityPages of them: past that the next round goes on from the last one read
var securityPage, securityPages = 10000, 10

// watchSecurityEvents: every round, the new events of the history: counted by name (for
// Prometheus), and those of securityAlerts into the event log and the alerts. Nothing is
// skipped: a burst (failed sign-ins from everywhere, a catch-up after the accounts
// database was down) is read page by page, from the last event of the previous page. Where
// it is, and the alerted events it can read again, are kept in the admin UI's database
// after each page: after a restart (an upgrade, the host down) it goes on from there, the
// changes of the meantime alerted once
func (h *Health) watchSecurityEvents(ctx context.Context) {
	if h.app.fxa == nil || !h.app.accountEvents {
		return
	}
	h.resumeSecurity(ctx)
	for range securityPages {
		now := time.Now()
		from := h.securityFrom()
		events, err := h.app.fxa.SecurityEventsSince(ctx, from, securityPage)
		if err != nil {
			h.logOnce("security events", err)
			return
		}
		h.logOnce("security events", nil)
		more := h.securityEvents(events, now, len(events) >= securityPage)
		h.saveSecurity(ctx)
		if !more {
			return
		}
	}
	log.Printf("security events: more than %d new ones in a round, the next round reads on from %s",
		securityPage*securityPages, h.securityFrom().UTC().Format(time.RFC3339Nano))
}

// ffs_meta: where the watch of the security history is, and each alerted event it can read
// again from there (a hash of the event, its time)
const securityFromKey, securitySeenKey = "security.from", "security.seen."

// securityKey: an event of the history, the same when read again
func securityKey(e accountSecurityEvent) string {
	sum := sha256.Sum256([]byte(e.UID + "\x00" + e.Name + "\x00" + e.IP + "\x00" + strconv.FormatInt(e.At.UnixMilli(), 10)))
	return hex.EncodeToString(sum[:16])
}

// resumeSecurity, once: where the admin UI left off before this start, at most
// ADMIN_RETENTION_DAYS back (older events are pruned), and the alerted events seen from
// there. Nothing kept (the first start with it, no database of its own) or not readable:
// from the start, as before
func (h *Health) resumeSecurity(ctx context.Context) {
	h.mu.Lock()
	resumed := h.securityResumed
	h.securityResumed = true
	h.mu.Unlock()
	if resumed || h.app.sync == nil || h.app.sync.own == nil {
		return
	}
	from, seen, err := h.app.sync.securityState(ctx)
	if err != nil {
		log.Printf("security events: where the watch stopped before this start: %v; events before the start are not alerted", err)
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.securitySeen == nil {
		h.securitySeen, h.securityCounts = map[string]time.Time{}, map[string]int64{}
	}
	if h.securityKept == nil {
		h.securityKept = map[string]bool{}
	}
	for key, at := range seen {
		h.securitySeen[key], h.securityKept[key] = at, true
	}
	if oldest := time.Now().AddDate(0, 0, -h.app.retentionDays()); !from.IsZero() && from.Before(oldest) {
		log.Printf("security events: the watch stopped on %s, more than ADMIN_RETENTION_DAYS ago: reading from %s",
			from.UTC().Format(time.RFC3339), oldest.UTC().Format(time.RFC3339))
		from = oldest
	}
	if !from.IsZero() && from.Before(h.started) {
		h.securityFloor, h.lastSecurity = from, from
	}
}

// saveSecurity: where the next read starts and the alerted events added and forgotten since
// the last save, into the admin UI's database (tried again at the next page when it fails)
func (h *Health) saveSecurity(ctx context.Context) {
	if h.app.sync == nil || h.app.sync.own == nil {
		return
	}
	h.mu.Lock()
	from, add, forget := h.lastSecurity, h.securityAdd, h.securityForget
	h.mu.Unlock()
	if err := h.app.sync.saveSecurityState(ctx, from, add, forget); err != nil {
		h.logOnce("security events: saving where the watch is", err)
		return
	}
	h.logOnce("security events: saving where the watch is", nil)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.securityKept == nil {
		h.securityKept = map[string]bool{}
	}
	for key := range add {
		h.securityKept[key] = true
	}
	h.securityAdd, h.securityForget = nil, nil
}

// securityState: what saveSecurityState kept
func (s *SyncDB) securityState(ctx context.Context) (time.Time, map[string]time.Time, error) {
	rows, err := s.own.QueryContext(ctx, s.q("SELECT name, value FROM ffs_meta WHERE name = ? OR name LIKE ?"), securityFromKey, securitySeenKey+"%")
	if err != nil {
		return time.Time{}, nil, err
	}
	defer rows.Close()
	var from time.Time
	seen := map[string]time.Time{}
	for rows.Next() {
		var name, value string
		if err := rows.Scan(&name, &value); err != nil {
			return time.Time{}, nil, err
		}
		at, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return time.Time{}, nil, fmt.Errorf("%s in ffs_meta: %q", name, value)
		}
		if name == securityFromKey {
			from = ms(at)
		} else if key, ok := strings.CutPrefix(name, securitySeenKey); ok {
			seen[key] = ms(at)
		}
	}
	return from, seen, rows.Err()
}

// saveSecurityState: where the watch is, the alerted events to keep and those to forget, in
// one transaction
func (s *SyncDB) saveSecurityState(ctx context.Context, from time.Time, add map[string]time.Time, forget []string) error {
	tx, err := s.own.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := s.setMeta(ctx, tx, securityFromKey, strconv.FormatInt(from.UnixMilli(), 10)); err != nil {
		return err
	}
	for key, at := range add {
		if err := s.setMeta(ctx, tx, securitySeenKey+key, strconv.FormatInt(at.UnixMilli(), 10)); err != nil {
			return err
		}
	}
	for _, key := range forget {
		if _, err := tx.ExecContext(ctx, s.q("DELETE FROM ffs_meta WHERE name = ?"), securitySeenKey+key); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// securityFrom: where the next page starts, the overlap included
func (h *Health) securityFrom() time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.lastSecurity.IsZero() {
		return h.started.Add(-watchOverlap)
	}
	return h.lastSecurity
}

// securityEvents: the events not seen yet, since the start; and before it, from where the
// admin UI left off (securityFloor), those of securityAlerts, not counted (Prometheus counts
// since the start). full: the page was full, the next one starts at its last event (those of
// the same millisecond are read again and skipped); otherwise at now less the overlap.
// Whether to read on
func (h *Health) securityEvents(events []accountSecurityEvent, now time.Time, full bool) bool {
	h.mu.Lock()
	if h.securitySeen == nil {
		h.securitySeen, h.securityCounts = map[string]time.Time{}, map[string]int64{}
	}
	from := h.lastSecurity
	if from.IsZero() {
		from = h.started.Add(-watchOverlap)
	}
	floor := h.securityFloor
	if floor.IsZero() {
		floor = h.started
	}
	var record []accountSecurityEvent
	for _, e := range events {
		key := securityKey(e)
		before := e.At.Before(h.started)
		if e.At.Before(floor) || !h.securitySeen[key].IsZero() || (before && !securityAlerts[e.Name]) {
			continue
		}
		h.securitySeen[key] = e.At
		if !before {
			h.securityCounts[e.Name]++
		}
		if securityAlerts[e.Name] {
			record = append(record, e)
			if h.securityAdd == nil {
				h.securityAdd = map[string]time.Time{}
			}
			h.securityAdd[key] = e.At
		}
	}
	more := full && len(events) > 0
	switch {
	case more && events[len(events)-1].At.After(from):
		h.lastSecurity = events[len(events)-1].At
	case more:
		// a full page in one millisecond: never seen, it cannot be read past otherwise
		h.lastSecurity = from.Add(time.Millisecond)
		log.Printf("security events: more than %d at %s, some of them were not read", len(events), from.UTC().Format(time.RFC3339Nano))
	default:
		h.lastSecurity = now.Add(-watchOverlap)
	}
	// older than the next page and the next round look (after a full page, the next
	// round can start before its last event again)
	forget := h.lastSecurity
	if now.Add(-watchOverlap).Before(forget) {
		forget = now.Add(-watchOverlap)
	}
	for key, at := range h.securitySeen {
		if at.Before(forget) {
			delete(h.securitySeen, key)
			if _, ok := h.securityAdd[key]; ok {
				delete(h.securityAdd, key)
			} else if h.securityKept[key] {
				delete(h.securityKept, key)
				h.securityForget = append(h.securityForget, key)
			}
		}
	}
	h.mu.Unlock()
	for _, e := range record {
		h.app.event("security", securityEventDetail(e))
	}
	return more
}

// securityEventDetail: the line of the event log and of the alert
func securityEventDetail(e accountSecurityEvent) string {
	who := accountLabel(&FxaAccount{UID: e.UID, Email: e.Email}, e.UID)
	if e.Email == "" { // deleted since
		who = accountLabel(nil, e.UID)
	}
	detail := who + ": " + e.Label()
	if e.IP != "" {
		detail += ", from " + e.IP
	}
	return detail
}

// SecurityCounts: the events of the history seen since the start, by name
func (h *Health) SecurityCounts() map[string]int64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	counts := make(map[string]int64, len(h.securityCounts))
	for name, n := range h.securityCounts {
		counts[name] = n
	}
	return counts
}

// securityMetrics: ffs_security_events_total{event}, the events of the history since
// the admin UI started
func securityMetrics(b *strings.Builder, counts map[string]int64) {
	names := make([]string, 0, len(counts))
	for n := range counts {
		names = append(names, n)
	}
	sort.Strings(names)
	b.WriteString("# HELP ffs_security_events_total Security events of the self-hosted accounts (FXA_ACCOUNT_EVENTS) since the admin UI started\n# TYPE ffs_security_events_total counter\n")
	for _, n := range names {
		fmt.Fprintf(b, "ffs_security_events_total{event=\"%s\"} %d\n", promLabel(n), counts[n])
	}
}

// accountEventsOn: whether the auth server records the history, from FXA_ACCOUNT_EVENTS as
// docker-compose.fxa.yml and the Quadlets pass it to ACCOUNT_EVENTS_ENABLED. The auth
// server (convict) takes anything but "false" as true, an empty value too: so does this.
// Not set: off, the stack's default
func accountEventsOn(value string, set bool) bool {
	on := set && strings.ToLower(value) != "false"
	if on && strings.ToLower(value) != "true" {
		log.Printf("FXA_ACCOUNT_EVENTS=%q: the accounts service takes it as true, use true or false", value)
	}
	return on
}
