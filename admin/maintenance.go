package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Maintenance: what runs by itself. Every minute the second passes of deleted accounts;
// every day the pruning of the accounts database (expired tokens and codes), and when
// asked the purge of the Sync storage (ADMIN_PURGE=1) and the deletion of old
// unconfirmed accounts (ADMIN_DELETE_UNCONFIRMED_DAYS). When each last ran, and what it
// did, is in ffs_jobs (the admin UI's database): a restart does not run them again.

const (
	jobInterval = 24 * time.Hour
	// a failed job runs again sooner: the first run at start may meet a database still starting
	jobRetry = time.Hour
)

// Job: a row of ffs_jobs
type Job struct {
	Name    string
	LastRun time.Time
	Result  string
	Failed  bool
}

var jobTitles = map[string]string{
	"prune":              "Prune the accounts database",
	"purge":              "Purge the Sync storage (ADMIN_PURGE=1)",
	"delete-unconfirmed": "Delete old unconfirmed accounts (ADMIN_DELETE_UNCONFIRMED_DAYS)",
}

func (j Job) Title() string {
	if t, ok := jobTitles[j.Name]; ok {
		return t
	}
	return j.Name
}

func (s *SyncDB) Jobs(ctx context.Context) (map[string]Job, error) {
	rows, err := s.mine().QueryContext(ctx, "SELECT name, last_run, result, failed FROM ffs_jobs")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	jobs := map[string]Job{}
	for rows.Next() {
		var j Job
		var at, failed int64
		if err := rows.Scan(&j.Name, &at, &j.Result, &failed); err != nil {
			return nil, err
		}
		j.LastRun, j.Failed = ms(at), failed != 0
		jobs[j.Name] = j
	}
	return jobs, rows.Err()
}

func (s *SyncDB) StoreJob(ctx context.Context, j Job) error {
	upsert := `INSERT INTO ffs_jobs (name, last_run, result, failed) VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE last_run = VALUES(last_run), result = VALUES(result), failed = VALUES(failed)`
	if s.postgres {
		upsert = `INSERT INTO ffs_jobs (name, last_run, result, failed) VALUES ($1, $2, $3, $4)
		ON CONFLICT (name) DO UPDATE SET last_run = EXCLUDED.last_run, result = EXCLUDED.result, failed = EXCLUDED.failed`
	}
	failed := 0
	if j.Failed {
		failed = 1
	}
	_, err := s.mine().ExecContext(ctx, upsert, j.Name, j.LastRun.UnixMilli(), oneLine(j.Result, 500), failed)
	return err
}

// maintain runs the second passes and the daily jobs
func (a *App) maintain(ctx context.Context) {
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		a.runSecondPasses(ctx, time.Now())
		a.dailyJobs(ctx, time.Now())
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// dueJobs: the jobs on here that did not run in the last day, or failed more than an
// hour ago
func dueJobs(enabled []string, jobs map[string]Job, now time.Time) []string {
	var due []string
	for _, name := range enabled {
		j, ok := jobs[name]
		every := jobInterval
		if j.Failed {
			every = jobRetry
		}
		if !ok || now.Sub(j.LastRun) >= every {
			due = append(due, name)
		}
	}
	return due
}

func (a *App) enabledJobs() []string {
	var on []string
	if a.fxa != nil {
		on = append(on, "prune")
	}
	if a.autoPurge && a.storage != nil {
		on = append(on, "purge")
	}
	if a.fxa != nil && a.unconfirmedDays > 0 {
		on = append(on, "delete-unconfirmed")
	}
	return on
}

func (a *App) dailyJobs(ctx context.Context, now time.Time) {
	jobs, err := a.sync.Jobs(ctx)
	if err != nil {
		log.Printf("maintenance: %v", err)
		return
	}
	for _, name := range dueJobs(a.enabledJobs(), jobs, now) {
		a.runJob(ctx, name, now)
	}
}

// runJob runs one job now, records it and what it did
func (a *App) runJob(ctx context.Context, name string, now time.Time) (string, error) {
	jctx, cancel := context.WithTimeout(ctx, time.Hour)
	defer cancel()
	var result string
	var err error
	switch name {
	case "prune":
		var counts PruneCounts
		counts, err = a.fxa.Prune(jctx, now, now.AddDate(0, 0, -a.retentionDays()))
		result = "Pruned the accounts database: " + counts.String()
	case "purge":
		var res PurgeResult
		res, err = a.purge(jctx, true)
		result = "Purged the Sync storage: " + res.String()
	case "delete-unconfirmed":
		var deleted []FxaAccount
		deleted, err = a.deleteUnconfirmedAccounts(jctx, now.AddDate(0, 0, -a.unconfirmedDays))
		result = unconfirmedResult(deleted, a.unconfirmedDays)
	default:
		return "", fmt.Errorf("no job %q", name)
	}
	if err != nil {
		result += " (failed: " + err.Error() + ")"
		log.Printf("maintenance %s: %v", name, err)
	}
	if e := a.sync.StoreJob(ctx, Job{Name: name, LastRun: now, Result: result, Failed: err != nil}); e != nil {
		log.Printf("maintenance: %v", e)
	}
	a.event("maintenance", result)
	return result, err
}

// plural: "1 day", "3 days"
func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return fmt.Sprintf("%d %ss", n, word)
}

func (a *App) retentionDays() int {
	if a.rec != nil && a.rec.keepDays > 0 {
		return a.rec.keepDays
	}
	return 30
}

// pruneNow: the button of the Activity page
func (a *App) pruneNow(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Minute)
	defer cancel()
	result, err := a.runJob(ctx, "prune", time.Now())
	if err != nil {
		err = &partialError{err}
	}
	a.doneTo(w, r, s, "/activity#maintenance", result, err)
}

// PruneCounts: what ffs.prune removed, by its columns
type PruneCounts map[string]int64

var pruneLabels = []struct{ column, label string }{
	{"unblock_codes", "unblock codes"}, {"signin_codes", "sign-in codes"}, {"account_tokens", "reset and password tokens"},
	{"sessions", "sessions without a device"}, {"oauth_codes", "OAuth codes"}, {"security_events", "security events"},
}

func (c PruneCounts) String() string {
	parts := make([]string, 0, len(pruneLabels))
	for _, l := range pruneLabels {
		parts = append(parts, fmt.Sprintf("%d %s", c[l.column], l.label))
	}
	return strings.Join(parts, ", ")
}

// Prune runs ffs.prune: expired tokens and codes, sessions without a device older than
// 4 weeks, security events before eventsBefore
func (f *FxaDB) Prune(ctx context.Context, now, eventsBefore time.Time) (PruneCounts, error) {
	rows, err := f.db.QueryContext(ctx, "CALL ffs.prune(?, ?)", now.UnixMilli(), eventsBefore.UnixMilli())
	if err != nil {
		return nil, procedureError(err)
	}
	counts, err := lastResultSet(rows, "unblock_codes")
	return PruneCounts(counts), procedureError(err)
}

// maxUnconfirmed: the accounts deleted in one run, the next run goes on
const maxUnconfirmed = 10000

// DeleteUnconfirmed deletes the accounts created before before that never confirmed an
// email, one CALL each: those deleted, also when it stops (a partialError then)
func (f *FxaDB) DeleteUnconfirmed(ctx context.Context, before time.Time) ([]FxaAccount, error) {
	accounts, err := f.Unconfirmed(ctx, before)
	if err != nil {
		return nil, err
	}
	var deleted []FxaAccount
	for _, acc := range accounts {
		id, err := accountID(acc.UID)
		if err != nil {
			return deleted, err
		}
		if _, err := f.db.ExecContext(ctx, "CALL ffs.delete_unconfirmed(?, ?)", id, before.UnixMilli()); err != nil {
			err = procedureError(err)
			if strings.Contains(err.Error(), errNotUnconfirmed) {
				continue // confirmed since it was listed
			}
			if len(deleted) > 0 {
				return deleted, &partialError{fmt.Errorf("stopped after %d of %d: %w", len(deleted), len(accounts), err)}
			}
			return nil, err
		}
		deleted = append(deleted, acc)
	}
	return deleted, nil
}

// the refusal of ffs.delete_unconfirmed for an account it may not delete
const errNotUnconfirmed = "not an account unconfirmed since before the cutoff"

// deleteUnconfirmedAccounts: DeleteUnconfirmed and the notes of those deleted
func (a *App) deleteUnconfirmedAccounts(ctx context.Context, before time.Time) ([]FxaAccount, error) {
	deleted, err := a.fxa.DeleteUnconfirmed(ctx, before)
	for _, acc := range deleted {
		if e := a.sync.SetNote(ctx, acc.UID, "", ""); e != nil {
			return deleted, joinPartial(err, fmt.Errorf("the note of %s was not removed: %w", oneLine(acc.Email, 255), e))
		}
	}
	return deleted, err
}

// unconfirmedResult: how many went and which, for the event log (its detail is 512
// characters: the emails that fit, then how many more)
func unconfirmedResult(deleted []FxaAccount, days int) string {
	text := fmt.Sprintf("Deleted %d accounts that never confirmed their email in %s", len(deleted), plural(days, "day"))
	for i, acc := range deleted {
		email := oneLine(acc.Email, 100)
		if len(text)+len(email) > 330 {
			return text + fmt.Sprintf(" and %d more", len(deleted)-i)
		}
		if i == 0 {
			text += ": " + email
		} else {
			text += ", " + email
		}
	}
	return text
}

// Unconfirmed: the accounts ffs.delete_unconfirmed would delete, oldest first
func (f *FxaDB) Unconfirmed(ctx context.Context, before time.Time) ([]FxaAccount, error) {
	rows, err := f.db.QueryContext(ctx, `SELECT LOWER(HEX(a.uid)), a.email, a.createdAt FROM fxa.accounts a
		WHERE a.emailVerified = 0 AND a.createdAt < ?
		AND NOT EXISTS (SELECT 1 FROM ffs.emails e WHERE e.uid = a.uid AND e.isVerified)
		ORDER BY a.createdAt LIMIT ?`, before.UnixMilli(), maxUnconfirmed)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var accounts []FxaAccount
	for rows.Next() {
		var acc FxaAccount
		var created int64
		if err := rows.Scan(&acc.UID, &acc.Email, &created); err != nil {
			return nil, err
		}
		acc.CreatedAt = ms(created)
		accounts = append(accounts, acc)
	}
	return accounts, rows.Err()
}

// lastResultSet reads every result set of a CALL, to the end (the connection is not
// usable before), and returns the row of the one with column: a procedure that calls
// others sends their SELECTs first
func lastResultSet(rows *sql.Rows, column string) (map[string]int64, error) {
	defer rows.Close()
	var found map[string]int64
	for {
		cols, err := rows.Columns()
		if err != nil {
			return nil, err
		}
		mine := slices.Contains(cols, column)
		for rows.Next() {
			if !mine {
				continue
			}
			values := make([]sql.NullInt64, len(cols))
			ptrs := make([]any, len(cols))
			for i := range values {
				ptrs[i] = &values[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				return nil, err
			}
			found = map[string]int64{}
			for i, c := range cols {
				found[c] = values[i].Int64
			}
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
		if !rows.NextResultSet() {
			break
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if found == nil {
		return nil, errors.New("the procedure returned no counts")
	}
	return found, nil
}

// Old unconfirmed accounts, from the overview

func (a *App) unconfirmedCutoff(r *http.Request) (int, error) {
	days := a.unconfirmedDays
	if days < 1 {
		days = 30
	}
	if v := r.FormValue("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 36500 {
			return 0, errors.New("days: a number of at least 1")
		}
		days = n
	}
	return days, nil
}

func (a *App) confirmUnconfirmed(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	days, err := a.unconfirmedCutoff(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	accounts, err := a.fxa.Unconfirmed(r.Context(), time.Now().AddDate(0, 0, -days))
	if err != nil {
		http.Error(w, "Accounts: "+err.Error(), http.StatusInternalServerError)
		return
	}
	data := a.base(s)
	data["Name"], data["Back"], data["MaxReason"], data["Post"] = "the accounts unconfirmed for "+plural(days, "day"), "/", maxReason, "/accounts/unconfirmed"
	data["Action"] = confirmAction{Title: "Delete", Button: "Delete these accounts", Hidden: map[string]string{"days": strconv.Itoa(days)}, Effects: []string{
		fmt.Sprintf("Deletes the %d accounts below: created more than %s ago, their email never confirmed. Nobody can sign in to them; their owners can sign up again.", len(accounts), plural(days, "day")),
		"Fewer or other days: change days= in the address of this page.",
	}}
	data["Unconfirmed"] = accounts
	a.render(w, "confirm.html", data)
}

func (a *App) deleteUnconfirmed(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	days, err := a.unconfirmedCutoff(r)
	if err != nil {
		a.done(w, r, s, "", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Minute)
	defer cancel()
	deleted, err := a.deleteUnconfirmedAccounts(ctx, time.Now().AddDate(0, 0, -days))
	a.done(w, r, s, unconfirmedResult(deleted, days), err)
}

// Bursts of sign-ups: an alert once an hour while more than ADMIN_SIGNUP_BURST
// accounts were created in the last hour (0: never)

// CreatedSince: accounts created since then
func (f *FxaDB) CreatedSince(ctx context.Context, since time.Time) (int, error) {
	var n int
	err := f.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM fxa.accounts WHERE createdAt >= ?", since.UnixMilli()).Scan(&n)
	return n, err
}

// signupBurst: whether count new accounts in the last hour is worth an alert now
func (h *Health) signupBurst(count, threshold int, now time.Time) bool {
	if threshold <= 0 || count <= threshold || (!h.burstAlerted.IsZero() && now.Sub(h.burstAlerted) < time.Hour) {
		return false
	}
	h.burstAlerted = now
	return true
}

func (h *Health) watchSignupBurst(ctx context.Context, now time.Time) {
	if h.app.fxa == nil || h.app.signupBurst <= 0 {
		return
	}
	n, err := h.app.fxa.CreatedSince(ctx, now.Add(-time.Hour))
	if err != nil {
		log.Printf("watching sign-ups: %v", err)
		return
	}
	if h.signupBurst(n, h.app.signupBurst, now) {
		h.app.event("sign-up burst", fmt.Sprintf("%d new accounts in the last hour, more than ADMIN_SIGNUP_BURST (%d): look at the accounts list, close sign-ups if they are not yours", n, h.app.signupBurst))
	}
}
