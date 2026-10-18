package main

import (
	"context"
	"database/sql"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

// The storage database of syncstorage-rs: what each account keeps on the server.
// MariaDB has its own database (SYNC_STORAGE_DB_* in .env), PostgreSQL shares the one
// of the tokenserver. The user id is the tokenserver uid.
type StorageDB struct {
	db       *sql.DB
	postgres bool

	mu     sync.Mutex
	cached map[int64]Usage
	at     time.Time
	// AllUsage's
	allCached map[int64]StoredUsage
	allAt     time.Time
	allMark   [2]int64 // the collections when it was read
}

type Usage struct {
	Items        int64
	Bytes        int64
	LastModified time.Time
}

type CollectionUsage struct {
	Name string
	Usage
}

func openStorageDB(syncDB *SyncDB) (*StorageDB, error) {
	if syncDB.postgres {
		// same database as the tokenserver
		return &StorageDB{db: syncDB.db, postgres: true}, nil
	}
	host := env("STORAGE_DB_HOST", "")
	if host == "" {
		return nil, nil
	}
	cfg := mysql.NewConfig()
	cfg.Net = "tcp"
	cfg.Addr = net.JoinHostPort(host, env("STORAGE_DB_PORT", "3306"))
	user, password, _, _, err := dbCredentials("STORAGE")
	if err != nil {
		return nil, err
	}
	cfg.User, cfg.Passwd, cfg.DBName = user, password, env("STORAGE_DB_NAME", "")
	cfg.Timeout = 5 * time.Second
	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	return &StorageDB{db: db}, nil
}

func ms(v int64) time.Time {
	if v <= 0 {
		return time.Time{}
	}
	return time.UnixMilli(v)
}

// Totals per user, cached for a minute: it reads every stored item
func (s *StorageDB) Totals(ctx context.Context) (map[int64]Usage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cached != nil && time.Since(s.at) < time.Minute {
		return s.cached, nil
	}
	items, last := `SELECT userid, COUNT(*), COALESCE(SUM(LENGTH(payload)), 0) FROM bso WHERE ttl > ? GROUP BY userid`,
		`SELECT userid, MAX(last_modified) FROM user_collections GROUP BY userid`
	args := []any{time.Now().UnixMilli()}
	if s.postgres {
		items, last = `SELECT user_id, COUNT(*), COALESCE(SUM(OCTET_LENGTH(payload)), 0) FROM bsos WHERE expiry > NOW() GROUP BY user_id`,
			`SELECT user_id, CAST(EXTRACT(EPOCH FROM MAX(modified)) * 1000 AS BIGINT) FROM user_collections GROUP BY user_id`
		args = nil
	}
	totals := map[int64]Usage{}
	rows, err := s.db.QueryContext(ctx, items, args...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id int64
		var u Usage
		if err := rows.Scan(&id, &u.Items, &u.Bytes); err != nil {
			rows.Close()
			return nil, err
		}
		totals[id] = u
	}
	rows.Close()
	rows, err = s.db.QueryContext(ctx, last)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, modified int64
		if err := rows.Scan(&id, &modified); err != nil {
			return nil, err
		}
		u := totals[id]
		u.LastModified = ms(modified)
		totals[id] = u
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	s.cached, s.at = totals, time.Now()
	return totals, nil
}

// LastWrite: the latest change of any collection (zero: none), one MAX of the collections
// (one row per account and collection, every write changes one)
func (s *StorageDB) LastWrite(ctx context.Context) (time.Time, error) {
	query := "SELECT COALESCE(MAX(last_modified), 0) FROM user_collections"
	if s.postgres {
		query = "SELECT COALESCE(CAST(EXTRACT(EPOCH FROM MAX(modified)) * 1000 AS BIGINT), 0) FROM user_collections"
	}
	var modified int64
	if err := s.db.QueryRowContext(ctx, query).Scan(&modified); err != nil {
		return time.Time{}, err
	}
	return ms(modified), nil
}

func (s *StorageDB) Collections(ctx context.Context, id int64) ([]CollectionUsage, error) {
	query := `SELECT c.name, COUNT(b.id), COALESCE(SUM(LENGTH(b.payload)), 0), uc.last_modified
		FROM user_collections uc JOIN collections c ON c.id = uc.collection
		LEFT JOIN bso b ON b.userid = uc.userid AND b.collection = uc.collection AND b.ttl > ?
		WHERE uc.userid = ? GROUP BY c.name, uc.last_modified ORDER BY c.name`
	args := []any{time.Now().UnixMilli(), id}
	if s.postgres {
		query = `SELECT c.name, COUNT(b.bso_id), COALESCE(SUM(OCTET_LENGTH(b.payload)), 0), CAST(EXTRACT(EPOCH FROM uc.modified) * 1000 AS BIGINT)
		FROM user_collections uc JOIN collections c ON c.collection_id = uc.collection_id
		LEFT JOIN bsos b ON b.user_id = uc.user_id AND b.collection_id = uc.collection_id AND b.expiry > NOW()
		WHERE uc.user_id = $1 GROUP BY c.name, uc.modified ORDER BY c.name`
		args = []any{id}
	}
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var collections []CollectionUsage
	for rows.Next() {
		var c CollectionUsage
		var modified int64
		if err := rows.Scan(&c.Name, &c.Items, &c.Bytes, &modified); err != nil {
			return nil, err
		}
		c.LastModified = ms(modified)
		collections = append(collections, c)
	}
	return collections, rows.Err()
}

func (s *StorageDB) Size(ctx context.Context) (int64, error) {
	return dbSize(ctx, s.db, s.postgres)
}

// StoredUsage: what a storage user id holds, live and expired (past its TTL: the Sync
// server no longer returns it, it stays until purged)
type StoredUsage struct {
	Live, Expired Usage
}

func (u StoredUsage) total() Usage {
	return Usage{Items: u.Live.Items + u.Expired.Items, Bytes: u.Live.Bytes + u.Expired.Bytes, LastModified: latest(u.Live.LastModified, u.Expired.LastModified)}
}

// AllUsage: every user id of the storage (also those with collections and no items),
// live and expired. It reads every item: cached for a minute while the collections
// (one row per account and collection, every write changes one) stay the same
func (s *StorageDB) AllUsage(ctx context.Context) (map[int64]StoredUsage, error) {
	query := "SELECT COUNT(*), COALESCE(MAX(last_modified), 0) FROM user_collections"
	if s.postgres {
		query = "SELECT COUNT(*), COALESCE(CAST(EXTRACT(EPOCH FROM MAX(modified)) * 1000000 AS BIGINT), 0) FROM user_collections"
	}
	var mark [2]int64
	if err := s.db.QueryRowContext(ctx, query).Scan(&mark[0], &mark[1]); err != nil {
		return nil, err
	}
	s.mu.Lock()
	if s.allCached != nil && s.allMark == mark && time.Since(s.allAt) < time.Minute {
		all := s.allCached
		s.mu.Unlock()
		return all, nil
	}
	s.mu.Unlock()
	all, err := s.usage(ctx, nil)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.allCached, s.allAt, s.allMark = all, time.Now(), mark
	s.mu.Unlock()
	return all, nil
}

// UsageOf: AllUsage for these user ids only (an account's rows)
func (s *StorageDB) UsageOf(ctx context.Context, ids []int64) (map[int64]StoredUsage, error) {
	if len(ids) == 0 {
		return map[int64]StoredUsage{}, nil
	}
	return s.usage(ctx, ids)
}

// usage of the ids, nil: all
func (s *StorageDB) usage(ctx context.Context, ids []int64) (map[int64]StoredUsage, error) {
	column, itemArgs := "userid", []any{time.Now().UnixMilli()}
	if s.postgres {
		column, itemArgs = "user_id", nil
	}
	// the ids are numbers: no placeholders to number for PostgreSQL
	where := ""
	if ids != nil {
		list := make([]string, len(ids))
		for i, id := range ids {
			list[i] = strconv.FormatInt(id, 10)
		}
		where = " WHERE " + column + " IN (" + strings.Join(list, ", ") + ")"
	}
	items := `SELECT userid, CASE WHEN ttl > ? THEN 1 ELSE 0 END AS live, COUNT(*), COALESCE(SUM(LENGTH(payload)), 0) FROM bso` + where + ` GROUP BY userid, live`
	last := `SELECT userid, MAX(last_modified) FROM user_collections` + where + ` GROUP BY userid`
	if s.postgres {
		items = `SELECT user_id, CASE WHEN expiry > NOW() THEN 1 ELSE 0 END AS live, COUNT(*), COALESCE(SUM(OCTET_LENGTH(payload)), 0) FROM bsos` + where + ` GROUP BY user_id, live`
		last = `SELECT user_id, CAST(EXTRACT(EPOCH FROM MAX(modified)) * 1000 AS BIGINT) FROM user_collections` + where + ` GROUP BY user_id`
	}
	all := map[int64]StoredUsage{}
	rows, err := s.db.QueryContext(ctx, items, itemArgs...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id, live int64
		var u Usage
		if err := rows.Scan(&id, &live, &u.Items, &u.Bytes); err != nil {
			rows.Close()
			return nil, err
		}
		su := all[id]
		if live == 1 {
			su.Live = u
		} else {
			su.Expired = u
		}
		all[id] = su
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows, err = s.db.QueryContext(ctx, last)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, modified int64
		if err := rows.Scan(&id, &modified); err != nil {
			return nil, err
		}
		su := all[id]
		su.Live.LastModified = ms(modified)
		all[id] = su
	}
	return all, rows.Err()
}

// rows deleted per statement: the Sync server keeps answering while a big account goes
const deleteChunk = 1000

// chunked runs a DELETE of at most deleteChunk rows until fewer go, and counts them
func (s *StorageDB) chunked(ctx context.Context, query string, args ...any) (int64, error) {
	var total int64
	for {
		res, err := s.db.ExecContext(ctx, query, args...)
		if err != nil {
			return total, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return total, err
		}
		total += n
		if n < deleteChunk {
			return total, nil
		}
		select {
		case <-ctx.Done():
			return total, ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// DeleteStorage deletes what a user id stores, or one collection of it ("": all): its
// items, collections and batches; what it removed (items and their size)
func (s *StorageDB) DeleteStorage(ctx context.Context, id int64, collection string) (Removed, error) {
	defer s.forget()
	var removed Removed
	var coll int64
	if collection != "" {
		query := "SELECT id FROM collections WHERE name = ?"
		if s.postgres {
			query = "SELECT collection_id FROM collections WHERE name = $1"
		}
		if err := s.db.QueryRowContext(ctx, query, collection).Scan(&coll); err == sql.ErrNoRows {
			return removed, fmt.Errorf("no collection %q", collection)
		} else if err != nil {
			return removed, err
		}
	}
	// "AND collection = ?" only for one collection
	where, args := "userid = ?", []any{id}
	if s.postgres {
		where = "user_id = $1"
	}
	if collection != "" {
		where, args = where+" AND collection = ?", append(args, coll)
		if s.postgres {
			where = "user_id = $1 AND collection_id = $2"
		}
	}
	count := "SELECT COUNT(*), COALESCE(SUM(LENGTH(payload)), 0) FROM bso WHERE " + where
	if s.postgres {
		count = "SELECT COUNT(*), COALESCE(SUM(OCTET_LENGTH(payload)), 0) FROM bsos WHERE " + where
	}
	if err := s.db.QueryRowContext(ctx, count, args...).Scan(&removed.Items, &removed.Bytes); err != nil {
		return removed, err
	}
	if s.postgres {
		// the collections cascade to their items, batches and batch items: the items first, in chunks
		if _, err := s.chunked(ctx, fmt.Sprintf("DELETE FROM bsos WHERE ctid IN (SELECT ctid FROM bsos WHERE %s LIMIT %d)", where, deleteChunk), args...); err != nil {
			return removed, err
		}
		_, err := s.db.ExecContext(ctx, "DELETE FROM user_collections WHERE "+where, args...)
		return removed, err
	}
	if _, err := s.chunked(ctx, fmt.Sprintf("DELETE FROM bso WHERE %s LIMIT %d", where, deleteChunk), args...); err != nil {
		return removed, err
	}
	items, itemArgs := "userid = ?", []any{id}
	if collection != "" {
		items, itemArgs = "userid = ? AND batch IN (SELECT batch FROM batch_uploads WHERE userid = ? AND collection = ?)", []any{id, id, coll}
	}
	if _, err := s.chunked(ctx, fmt.Sprintf("DELETE FROM batch_upload_items WHERE %s LIMIT %d", items, deleteChunk), itemArgs...); err != nil {
		return removed, err
	}
	for _, table := range []string{"batch_uploads", "user_collections"} {
		if _, err := s.db.ExecContext(ctx, "DELETE FROM "+table+" WHERE "+where, args...); err != nil {
			return removed, err
		}
	}
	return removed, nil
}

// forget drops the cached totals: they changed
func (s *StorageDB) forget() {
	s.mu.Lock()
	s.cached, s.allCached = nil, nil
	s.mu.Unlock()
}
