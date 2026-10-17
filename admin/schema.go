package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"strconv"
	"time"
)

// Schema levels of the databases: the migrations syncstorage-rs ran (diesel), and
// FxA's schema-patch-level of each accounts database. A change is an event (and an
// alert): an upgrade that migrated, or a database restored from an older backup.

type SchemaLevel struct {
	Database string // Tokenserver, Sync storage, fxa, fxa_oauth...
	Level    string
	At       time.Time // when it was applied, zero when the database does not say
}

// dieselLevel: the newest migration of a database of syncstorage-rs
func dieselLevel(ctx context.Context, db *sql.DB, postgres bool) (string, time.Time, error) {
	query := `SELECT version, CAST(UNIX_TIMESTAMP(run_on) AS SIGNED) FROM __diesel_schema_migrations ORDER BY version DESC LIMIT 1`
	if postgres {
		query = `SELECT version, CAST(EXTRACT(EPOCH FROM run_on) AS BIGINT) FROM __diesel_schema_migrations ORDER BY version DESC LIMIT 1`
	}
	var version string
	var at int64
	if err := db.QueryRowContext(ctx, query).Scan(&version, &at); err != nil {
		return "", time.Time{}, err
	}
	return version, time.Unix(at, 0), nil
}

// SchemaLevels of the Sync databases (with PostgreSQL one for both)
func (s *SyncDB) SchemaLevels(ctx context.Context, storage *StorageDB) ([]SchemaLevel, error) {
	name := "Tokenserver"
	if s.postgres {
		name = "Sync (tokenserver and storage)"
	}
	version, at, err := dieselLevel(ctx, s.db, s.postgres)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	levels := []SchemaLevel{{name, version, at}}
	if storage != nil && !s.postgres {
		version, at, err := dieselLevel(ctx, storage.db, false)
		if err != nil {
			return levels, fmt.Errorf("Sync storage: %w", err)
		}
		levels = append(levels, SchemaLevel{"Sync storage", version, at})
	}
	return levels, nil
}

// SchemaLevels of the accounts databases, through a view of fxa-init over their dbMetadata
func (f *FxaDB) SchemaLevels(ctx context.Context) ([]SchemaLevel, error) {
	rows, err := f.db.QueryContext(ctx, "SELECT db, value FROM ffs.schema_levels WHERE name = 'schema-patch-level' ORDER BY db")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var levels []SchemaLevel
	for rows.Next() {
		var l SchemaLevel
		if err := rows.Scan(&l.Database, &l.Level); err != nil {
			return nil, err
		}
		levels = append(levels, l)
	}
	return levels, rows.Err()
}

// StoredLevels: the levels seen last time (ffs_schema_levels, so that an upgrade of
// the whole stack, the admin UI too, is still noticed)
func (s *SyncDB) StoredLevels(ctx context.Context) (map[string]string, error) {
	rows, err := s.mine().QueryContext(ctx, "SELECT name, level FROM ffs_schema_levels")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	levels := map[string]string{}
	for rows.Next() {
		var name, level string
		if err := rows.Scan(&name, &level); err != nil {
			return nil, err
		}
		levels[name] = level
	}
	return levels, rows.Err()
}

func (s *SyncDB) StoreLevel(ctx context.Context, l SchemaLevel) error {
	upsert := `INSERT INTO ffs_schema_levels (name, level, updated_at) VALUES (?, ?, ?)
		ON DUPLICATE KEY UPDATE level = VALUES(level), updated_at = VALUES(updated_at)`
	if s.postgres {
		upsert = `INSERT INTO ffs_schema_levels (name, level, updated_at) VALUES ($1, $2, $3)
		ON CONFLICT (name) DO UPDATE SET level = EXCLUDED.level, updated_at = EXCLUDED.updated_at`
	}
	_, err := s.mine().ExecContext(ctx, upsert, oneLine(l.Database, 64), oneLine(l.Level, 255), time.Now().UnixMilli())
	return err
}

// schemaChanges: the levels to store (new or changed) and the events of the changed
// ones; a database seen for the first time is no change
func schemaChanges(stored map[string]string, current []SchemaLevel) (store []SchemaLevel, events []string) {
	for _, l := range current {
		old, seen := stored[l.Database]
		if seen && old == l.Level {
			continue
		}
		store = append(store, l)
		if seen {
			events = append(events, fmt.Sprintf("Schema of the %s database changed from %s to %s", l.Database, old, l.Level))
		}
	}
	return store, events
}

// watchSchema reads the levels, records their changes
func (h *Health) watchSchema(ctx context.Context) {
	levels, err := h.app.sync.SchemaLevels(ctx, h.app.storage)
	var errs []string
	if err != nil {
		errs = append(errs, err.Error())
	}
	if h.app.fxa != nil {
		fxa, err := h.app.fxa.SchemaLevels(ctx)
		if err != nil {
			errs = append(errs, "accounts: "+err.Error())
		}
		levels = append(levels, fxa...)
	}
	// once per new error, not every minute
	if msg := fmt.Sprint(errs); len(errs) > 0 && msg != h.schemaErr {
		log.Printf("schema levels: %s", msg)
		h.schemaErr = msg
	}
	if len(levels) > 0 {
		stored, err := h.app.sync.StoredLevels(ctx)
		if err != nil {
			log.Printf("schema levels: %v", err)
			return
		}
		store, events := schemaChanges(stored, levels)
		for _, l := range store {
			if err := h.app.sync.StoreLevel(ctx, l); err != nil {
				log.Printf("schema levels: %v", err)
				return
			}
		}
		for _, e := range events {
			h.app.event("update", e)
		}
	}
	h.mu.Lock()
	h.schema = levels
	h.mu.Unlock()
}

func (h *Health) Schema() []SchemaLevel {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]SchemaLevel(nil), h.schema...)
}

// PruneLastRan: when the accounts database was last pruned (prune-last-ran of fxa, set
// by ffs.prune), zero: never
func (f *FxaDB) PruneLastRan(ctx context.Context) (time.Time, error) {
	var value string
	err := f.db.QueryRowContext(ctx, "SELECT value FROM ffs.schema_levels WHERE db = 'fxa' AND name = 'prune-last-ran'").Scan(&value)
	if err == sql.ErrNoRows {
		return time.Time{}, nil
	}
	if err != nil {
		return time.Time{}, err
	}
	n, _ := strconv.ParseInt(value, 10, 64)
	return ms(n), nil
}
