package main

import (
	"context"
	"fmt"
	"sort"
	"time"
)

// Backups: the runs of the backup service (config/backup/backup.sh, COMPOSE_PROFILES=backup
// or the Quadlets' timer), one row of ffs_backups per run and scope, written as the
// tokenserver user; with your own database servers by your own backups (ADMIN.md#backups).
// The admin UI only reads them: it has no access to the backups volume.

// the last good backup may be this old: a nightly run missed once is still fine
const backupMaxAge = 36 * time.Hour

type BackupRun struct {
	Scope             string
	Started, Finished time.Time
	OK                bool
	Bytes             int64
	Error, Location   string
}

// BackupStatus: the newest run of a scope and its newest good one (zero Finished: none)
type BackupStatus struct {
	Scope        string
	Last, LastOK BackupRun
}

var backupTitles = map[string]string{"sync": "Sync databases", "accounts": "accounts databases"}

func (b BackupStatus) Title() string {
	if t, ok := backupTitles[b.Scope]; ok {
		return t
	}
	return b.Scope
}

// state: ok, failed (the newest run), stale (no good one in backupMaxAge)
func (b BackupStatus) state(now time.Time) string {
	switch {
	case !b.Last.OK:
		return "failed"
	case now.Sub(b.LastOK.Finished) > backupMaxAge:
		return "stale"
	}
	return "ok"
}

// Problem: what is wrong in one sentence, "" when nothing
func (b BackupStatus) Problem(now time.Time) string {
	switch b.state(now) {
	case "failed":
		text := fmt.Sprintf("the backup of the %s failed on %s", b.Title(), formatTime(b.Last.Finished, adminZone))
		if b.Last.Error != "" {
			text += ": " + b.Last.Error
		}
		return text
	case "stale":
		return fmt.Sprintf("the last backup of the %s is from %s, more than %d hours ago: is the backup service running?",
			b.Title(), formatTime(b.LastOK.Finished, adminZone), int(backupMaxAge.Hours()))
	}
	return ""
}

func (s *SyncDB) backupsSchema() string {
	if s.postgres {
		return `CREATE TABLE IF NOT EXISTS ffs_backups (id BIGSERIAL PRIMARY KEY, scope VARCHAR(32) NOT NULL, started BIGINT NOT NULL,
			finished BIGINT NOT NULL, ok SMALLINT NOT NULL, bytes BIGINT NOT NULL, error VARCHAR(512) NOT NULL DEFAULT '', location VARCHAR(255) NOT NULL DEFAULT '')`
	}
	// the same as config/backup/backup.sh, which creates it when the admin UI does not run
	return `CREATE TABLE IF NOT EXISTS ffs_backups (id BIGINT AUTO_INCREMENT PRIMARY KEY, scope VARCHAR(32) NOT NULL, started BIGINT NOT NULL,
		finished BIGINT NOT NULL, ok SMALLINT NOT NULL, bytes BIGINT NOT NULL, error VARCHAR(512) NOT NULL DEFAULT '', location VARCHAR(255) NOT NULL DEFAULT '',
		KEY ffs_backups_started (started))`
}

// Backups: the status of each scope that has runs, from the newest runs
func (s *SyncDB) Backups(ctx context.Context) ([]BackupStatus, error) {
	// newest first; the same millisecond: the row written last
	rows, err := s.db.QueryContext(ctx, "SELECT scope, started, finished, ok, bytes, error, location FROM ffs_backups ORDER BY started DESC, id DESC LIMIT 1000")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var runs []BackupRun
	for rows.Next() {
		var r BackupRun
		var started, finished, ok int64
		if err := rows.Scan(&r.Scope, &started, &finished, &ok, &r.Bytes, &r.Error, &r.Location); err != nil {
			return nil, err
		}
		r.Started, r.Finished, r.OK = ms(started), ms(finished), ok != 0
		r.Error, r.Location = oneLine(r.Error, 400), oneLine(r.Location, 255)
		runs = append(runs, r)
	}
	return backupStatuses(runs), rows.Err()
}

// backupStatuses: per scope (sync first) the newest run and the newest good one, of
// runs newest first
func backupStatuses(runs []BackupRun) []BackupStatus {
	byScope := map[string]*BackupStatus{}
	for _, r := range runs {
		b := byScope[r.Scope]
		if b == nil {
			b = &BackupStatus{Scope: r.Scope, Last: r}
			byScope[r.Scope] = b
		}
		if r.OK && b.LastOK.Finished.IsZero() {
			b.LastOK = r
		}
	}
	list := make([]BackupStatus, 0, len(byScope))
	for _, b := range byScope {
		list = append(list, *b)
	}
	order := map[string]int{"sync": 0, "accounts": 1}
	sort.Slice(list, func(i, j int) bool {
		oi, iok := order[list[i].Scope]
		oj, jok := order[list[j].Scope]
		if iok != jok || oi != oj {
			return iok && (!jok || oi < oj)
		}
		return list[i].Scope < list[j].Scope
	})
	return list
}

// watchBackups records (and alerts) a backup that failed or got too old, once per
// change of its state, and when it works again
func (h *Health) watchBackups(ctx context.Context, now time.Time) {
	backups, err := h.app.sync.Backups(ctx)
	if err != nil {
		h.logOnce("backups", err)
		return
	}
	h.logOnce("backups", nil)
	h.mu.Lock()
	h.backups = backups
	h.mu.Unlock()
	for _, b := range backups {
		state := b.state(now)
		if !h.changed("backup:"+b.Scope, state) {
			continue
		}
		if state == "ok" {
			h.app.event("backup", fmt.Sprintf("The backup of the %s works again (%s, %s)", b.Title(), formatTime(b.LastOK.Finished, adminZone), humanBytes(b.LastOK.Bytes)))
		} else {
			h.app.event("backup", upperFirst(b.Problem(now)))
		}
	}
}

func (h *Health) Backups() []BackupStatus {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]BackupStatus(nil), h.backups...)
}

func upperFirst(s string) string {
	if s == "" || s[0] < 'a' || s[0] > 'z' {
		return s
	}
	return string(s[0]-'a'+'A') + s[1:]
}

// Old: the newest run worked, but more than backupMaxAge ago
func (b BackupStatus) Old() bool { return b.Last.OK && b.state(time.Now()) == "stale" }

// localClock: a time of day in UTC (BACKUP_TIME, 03:00) in the zone of the pages, today;
// as given when it is not one
func localClock(utc string, now time.Time, zone *time.Location) string {
	t, err := time.Parse("15:04", utc)
	if err != nil {
		return utc
	}
	y, m, d := now.UTC().Date()
	return time.Date(y, m, d, t.Hour(), t.Minute(), 0, 0, time.UTC).In(zone).Format("15:04")
}
