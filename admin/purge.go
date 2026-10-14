package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// Sync data nobody reads any more: orphans (storage of replaced keys, of deleted
// accounts, with no tokenserver row) and expired items and batches. A report on the
// overview, a purge on a confirm page and, with ADMIN_PURGE=1, every day.

const (
	// a replaced row is kept a day: a device still on the old keys may need it to sync
	// once more before it notices
	replacedGrace = 24 * time.Hour
	// syncstorage-rs's batches live 2 hours (BATCH_LIFETIME); MySQL's batch id is its
	// creation time in milliseconds
	batchLifetime = 2 * time.Hour
	// storage with no row that changed this recently may belong to a row created since
	// the rows were read
	unknownGrace = time.Hour
)

// orphan kinds
const (
	orphanReplaced = "replaced keys"
	orphanDeleted  = "account deleted"
	orphanNoRow    = "no tokenserver row"
)

// Orphan: storage (and rows) nobody reads any more
type Orphan struct {
	Kind    string
	Account string  // the uid of the email, "" without a row
	Email   string  // the tokenserver email, "" without a row
	Rows    []int64 // tokenserver rows to delete with it
	Storage []int64 // storage user ids to empty
	Usage   Usage
}

// OtherDomain: rows of an email domain other than FXA_EMAIL_DOMAIN whose account is
// not in the accounts database: listed, never purged automatically (an earlier
// FXA_EMAIL_DOMAIN, or Mozilla's accounts before)
type OtherDomain struct {
	Email string
	Rows  int
	Usage Usage
}

// classifyOrphans finds the orphans among the tokenserver rows and the storage user ids:
// replaced rows older than a day that are not the current one of their email; with the
// self-hosted accounts (accounts not nil, as uids) the rows of FXA_EMAIL_DOMAIN whose
// account is gone; storage with no row at all. The rows are marked current (markCurrent)
func classifyOrphans(rows []UserRow, usage map[int64]StoredUsage, accounts map[string]bool, emailDomain string, now time.Time) ([]Orphan, []OtherDomain) {
	var orphans []Orphan
	var others []OtherDomain
	byEmail := map[string][]UserRow{}
	var emails []string
	known := map[int64]bool{}
	var maxID int64
	for _, r := range rows {
		email := strings.ToLower(r.Email)
		if _, ok := byEmail[email]; !ok {
			emails = append(emails, email)
		}
		byEmail[email] = append(byEmail[email], r)
		known[r.ID] = true
		if r.ID > maxID {
			maxID = r.ID
		}
	}
	for _, email := range emails {
		mine := byEmail[email]
		uid, domain, _ := strings.Cut(email, "@")
		if accounts != nil && !accounts[uid] {
			if emailDomain != "" && domain == emailDomain {
				o := Orphan{Kind: orphanDeleted, Account: uid, Email: email}
				for _, r := range mine {
					o.Rows, o.Storage = append(o.Rows, r.ID), append(o.Storage, r.ID)
					o.Usage = addUsage(o.Usage, usage[r.ID].total())
				}
				orphans = append(orphans, o)
			} else {
				d := OtherDomain{Email: email, Rows: len(mine)}
				for _, r := range mine {
					d.Usage = addUsage(d.Usage, usage[r.ID].total())
				}
				others = append(others, d)
			}
			continue
		}
		for _, r := range mine {
			if r.Current || !r.Replaced() || now.Sub(r.ReplacedAt) < replacedGrace {
				continue
			}
			orphans = append(orphans, Orphan{Kind: orphanReplaced, Account: uid, Email: email, Rows: []int64{r.ID}, Storage: []int64{r.ID}, Usage: usage[r.ID].total()})
		}
	}
	ids := make([]int64, 0, len(usage))
	for id := range usage {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		u := usage[id]
		// newer than every row read: a row created since, unless it has not changed for a while
		if known[id] || (id > maxID && now.Sub(u.total().LastModified) < unknownGrace) {
			continue
		}
		orphans = append(orphans, Orphan{Kind: orphanNoRow, Storage: []int64{id}, Usage: u.total()})
	}
	return orphans, others
}

func addUsage(a, b Usage) Usage {
	return Usage{Items: a.Items + b.Items, Bytes: a.Bytes + b.Bytes, LastModified: latest(a.LastModified, b.LastModified)}
}

// StorageReport: the storage section of the overview
type StorageReport struct {
	Live, Expired, Orphaned Usage
	Orphans                 []Orphan
	OtherDomains            []OtherDomain
	// stale batches: batches past their lifetime and their items
	StaleBatches int64
	StaleItems   Usage
	Top          []TopAccount
	// MariaDB/MySQL: space the tables keep after deletions (OPTIMIZE TABLE gives it back)
	DataFree int64
	Postgres bool
	// without the self-hosted accounts, or when they could not be read: no deleted accounts
	Accounts bool
	// for the guards of the automatic purge: the accounts read, the tokenserver rows,
	// the storage user ids
	AccountCount, RowCount, StorageUsers int
}

type TopAccount struct {
	UID, Email string
	Usage      Usage
}

// Empty: nothing to purge
func (r *StorageReport) Empty() bool {
	return len(r.Orphans) == 0 && r.Expired.Items == 0 && r.StaleBatches == 0 && r.StaleItems.Items == 0
}

// Purgeable: what a purge removes (expired, orphaned and stale), for the line of the overview
func (r *StorageReport) Purgeable() Usage {
	return addUsage(addUsage(r.Expired, r.Orphaned), r.StaleItems)
}

// storageReport reads the storage, the tokenserver rows and the accounts
func (a *App) storageReport(ctx context.Context) (*StorageReport, error) {
	if a.storage == nil {
		return nil, nil
	}
	usage, err := a.storage.AllUsage(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := a.sync.AllUserRows(ctx)
	if err != nil {
		return nil, err
	}
	rep := &StorageReport{Postgres: a.storage.postgres, RowCount: len(rows), StorageUsers: len(usage)}
	var accounts map[string]bool
	emails := map[string]string{}
	if a.fxa != nil {
		list, err := a.fxa.Accounts(ctx)
		if err != nil {
			return nil, fmt.Errorf("accounts: %w", err)
		}
		accounts = map[string]bool{}
		for _, acc := range list {
			accounts[acc.UID] = true
			emails[acc.UID] = acc.Email
		}
		rep.Accounts, rep.AccountCount = true, len(list)
	}
	rep.Orphans, rep.OtherDomains = classifyOrphans(rows, usage, accounts, a.emailDomain, time.Now())
	orphaned := map[int64]bool{}
	for _, o := range rep.Orphans {
		rep.Orphaned = addUsage(rep.Orphaned, o.Usage)
		for _, id := range o.Storage {
			orphaned[id] = true
		}
	}
	current := map[int64]string{}
	for _, r := range rows {
		if r.Current {
			current[r.ID] = localPart(r.Email)
		}
	}
	for id, u := range usage {
		if orphaned[id] {
			continue
		}
		rep.Live = addUsage(rep.Live, u.Live)
		rep.Expired = addUsage(rep.Expired, u.Expired)
		if uid, ok := current[id]; ok && u.Live.Bytes > 0 {
			rep.Top = append(rep.Top, TopAccount{UID: uid, Email: emails[uid], Usage: u.Live})
		}
	}
	sort.Slice(rep.Top, func(i, j int) bool { return rep.Top[i].Usage.Bytes > rep.Top[j].Usage.Bytes })
	if len(rep.Top) > 10 {
		rep.Top = rep.Top[:10]
	}
	if rep.StaleBatches, rep.StaleItems, err = a.storage.StaleBatches(ctx, time.Now()); err != nil {
		return nil, err
	}
	if !a.storage.postgres {
		if rep.DataFree, err = a.storage.DataFree(ctx); err != nil {
			return nil, err
		}
	}
	return rep, nil
}

// StaleBatches: batches past their lifetime, and their items
func (s *StorageDB) StaleBatches(ctx context.Context, now time.Time) (int64, Usage, error) {
	var batches int64
	var items Usage
	if s.postgres {
		if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM batches WHERE expiry < NOW()").Scan(&batches); err != nil {
			return 0, items, err
		}
		err := s.db.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(SUM(OCTET_LENGTH(i.payload)), 0) FROM batch_bsos i
			JOIN batches b ON b.user_id = i.user_id AND b.collection_id = i.collection_id AND b.batch_id = i.batch_id
			WHERE b.expiry < NOW()`).Scan(&items.Items, &items.Bytes)
		return batches, items, err
	}
	before := now.Add(-batchLifetime).UnixMilli()
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM batch_uploads WHERE batch < ?", before).Scan(&batches); err != nil {
		return 0, items, err
	}
	err := s.db.QueryRowContext(ctx, "SELECT COUNT(*), COALESCE(SUM(LENGTH(payload)), 0) FROM batch_upload_items WHERE batch < ?", before).Scan(&items.Items, &items.Bytes)
	return batches, items, err
}

// DataFree: what the tables of the storage database keep allocated after deletions
func (s *StorageDB) DataFree(ctx context.Context) (int64, error) {
	var n int64
	err := s.db.QueryRowContext(ctx, "SELECT COALESCE(SUM(data_free), 0) FROM information_schema.tables WHERE table_schema = DATABASE()").Scan(&n)
	return n, err
}

// PurgeExpired deletes the items past their TTL and the stale batches, in chunks
func (s *StorageDB) PurgeExpired(ctx context.Context, now time.Time) (items, batches int64, err error) {
	defer s.forget()
	if s.postgres {
		if items, err = s.chunked(ctx, fmt.Sprintf("DELETE FROM bsos WHERE ctid IN (SELECT ctid FROM bsos WHERE expiry < NOW() LIMIT %d)", deleteChunk)); err != nil {
			return items, 0, err
		}
		// their items go with them (cascade)
		batches, err = s.chunked(ctx, fmt.Sprintf("DELETE FROM batches WHERE ctid IN (SELECT ctid FROM batches WHERE expiry < NOW() LIMIT %d)", deleteChunk))
		return items, batches, err
	}
	if items, err = s.chunked(ctx, fmt.Sprintf("DELETE FROM bso WHERE ttl < ? LIMIT %d", deleteChunk), now.UnixMilli()); err != nil {
		return items, 0, err
	}
	before := now.Add(-batchLifetime).UnixMilli()
	if _, err = s.chunked(ctx, fmt.Sprintf("DELETE FROM batch_upload_items WHERE batch < ? LIMIT %d", deleteChunk), before); err != nil {
		return items, 0, err
	}
	batches, err = s.chunked(ctx, fmt.Sprintf("DELETE FROM batch_uploads WHERE batch < ? LIMIT %d", deleteChunk), before)
	return items, batches, err
}

// PurgeResult: what a purge removed
type PurgeResult struct {
	Orphans  int
	Orphaned Removed
	Rows     int
	Expired  Removed
	Batches  int64
	// deleted accounts and storage without a row left out of an automatic purge, see purge
	SkippedDeleted, SkippedNoRow int
}

func (p PurgeResult) String() string {
	s := fmt.Sprintf("%d orphans (%s, %d tokenserver rows), %d expired items (%s), %d stale batches",
		p.Orphans, p.Orphaned, p.Rows, p.Expired.Items, humanBytes(p.Expired.Bytes), p.Batches)
	if p.SkippedDeleted > 0 {
		s += fmt.Sprintf("; %d deleted accounts left for a purge from the overview: too many at once for the automatic purge (more than half of the accounts using Sync, or no account left)", p.SkippedDeleted)
	}
	if p.SkippedNoRow > 0 {
		s += fmt.Sprintf("; %d storage user ids without a tokenserver row left for a purge from the overview: too many at once for the automatic purge (more than half of the storage, or no tokenserver row left)", p.SkippedNoRow)
	}
	return s
}

// purging: one purge at a time
var purging sync.Mutex

// purge removes the orphans and the expired data of a fresh report. automatic (the
// daily ADMIN_PURGE) leaves what looks like a database that came back empty or from an
// older backup, not users: see skipOrphans
func (a *App) purge(ctx context.Context, automatic bool) (PurgeResult, error) {
	purging.Lock()
	defer purging.Unlock()
	var res PurgeResult
	if a.storage == nil {
		return res, nil
	}
	a.storage.forget()
	rep, err := a.storageReport(ctx)
	if err != nil || rep == nil {
		return res, err
	}
	syncing := -1
	if st, err := a.sync.Status(ctx); err == nil {
		syncing = st.Users
	}
	skipDeleted, skipNoRow := false, false
	if automatic {
		skipDeleted, skipNoRow = skipOrphans(rep, syncing)
	}
	for _, o := range rep.Orphans {
		if o.Kind == orphanDeleted && skipDeleted {
			res.SkippedDeleted++
			continue
		}
		if o.Kind == orphanNoRow && skipNoRow {
			res.SkippedNoRow++
			continue
		}
		for _, id := range o.Storage {
			n, err := a.storage.DeleteStorage(ctx, id, "")
			res.Orphaned.add(n)
			if err != nil {
				return res, err
			}
		}
		if err := a.sync.DeleteUserRows(ctx, o.Rows); err != nil {
			return res, err
		}
		if o.Kind == orphanDeleted {
			// personal data, and no account page left to remove it from
			if err := a.sync.SetNote(ctx, o.Account, "", ""); err != nil {
				return res, err
			}
		}
		res.Orphans++
		res.Rows += len(o.Rows)
	}
	res.Expired.Bytes = rep.Expired.Bytes
	res.Expired.Items, res.Batches, err = a.storage.PurgeExpired(ctx, time.Now())
	if res.Expired.Items != rep.Expired.Items {
		// more expired since the report: the size is that of the report
		log.Printf("purge: %d expired items, %d in the report", res.Expired.Items, rep.Expired.Items)
	}
	return res, err
}

// skipOrphans: whether the automatic purge leaves the deleted accounts, and the storage
// without a row. Deleted accounts are left when they are more than half of the accounts using Sync
// (syncing, -1: unknown) or none is left: an accounts database that came back empty
// (a new volume, EXTERNAL_DB pointed at a new server). Storage without a row is left
// when the tokenserver has no row, or it is more than half of the storage: a tokenserver
// database that is empty or restored from an older backup
func skipOrphans(rep *StorageReport, syncing int) (deleted, noRow bool) {
	nDeleted, nNoRow := 0, 0
	for _, o := range rep.Orphans {
		switch o.Kind {
		case orphanDeleted:
			nDeleted++
		case orphanNoRow:
			nNoRow++
		}
	}
	deleted = nDeleted > 0 && (syncing < 0 || nDeleted*2 > syncing || rep.AccountCount == 0)
	noRow = nNoRow > 0 && (rep.RowCount == 0 || nNoRow*2 > rep.StorageUsers)
	return deleted, noRow
}

// purgeNow: the purge of the overview's confirm page. It goes on in the background past
// 20 seconds, its event says when it is done
func (a *App) purgeNow(w http.ResponseWriter, r *http.Request, s *session) {
	if a.storage == nil {
		http.NotFound(w, r)
		return
	}
	reason := r.PostFormValue("reason")
	done := make(chan string, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Hour)
		defer cancel()
		res, err := a.purge(ctx, false)
		detail := "Purged the Sync storage: " + res.String()
		if err != nil {
			detail += " (stopped: " + err.Error() + ")"
		}
		a.event("admin", auditText(s, detail, reason))
		done <- detail
	}()
	message := "The purge goes on in the background: the event log says when it is done"
	select {
	case message = <-done:
	case <-time.After(20 * time.Second):
	}
	a.mu.Lock()
	s.message, s.failed = message, ""
	a.mu.Unlock()
	http.Redirect(w, r, "/#storage", http.StatusSeeOther)
}

// confirmPurge: what a purge would remove
func (a *App) confirmPurge(w http.ResponseWriter, r *http.Request, s *session) {
	if a.storage == nil {
		http.NotFound(w, r)
		return
	}
	rep, err := a.storageReport(r.Context())
	if err != nil {
		http.Error(w, "Sync storage: "+err.Error(), http.StatusInternalServerError)
		return
	}
	data := a.base(s)
	effects := []string{
		fmt.Sprintf("%d orphans: %d items, %s (listed below).", len(rep.Orphans), rep.Orphaned.Items, humanBytes(rep.Orphaned.Bytes)),
		fmt.Sprintf("%d expired items, %s: past their time to live, the Sync server no longer returns them.", rep.Expired.Items, humanBytes(rep.Expired.Bytes)),
		fmt.Sprintf("%d stale batches (%d items): uploads that were never committed, past their 2 hours.", rep.StaleBatches, rep.StaleItems.Items),
		"Live data stays. It runs in chunks of 1000 items, the Sync server keeps answering.",
	}
	if len(rep.OtherDomains) > 0 {
		effects = append(effects, fmt.Sprintf("The %d accounts of another email domain stay: delete them from their account page if they are really gone.", len(rep.OtherDomains)))
	}
	data["Name"], data["Back"], data["MaxReason"], data["Post"] = "the Sync storage", "/#storage", maxReason, "/storage/purge"
	data["Action"] = confirmAction{Title: "Purge", Button: "Purge", Effects: effects}
	data["Orphans"] = rep.Orphans
	a.render(w, "confirm.html", data)
}
