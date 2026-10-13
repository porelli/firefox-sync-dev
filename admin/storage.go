package main

import (
	"context"
	"database/sql"
	"net"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

// The storage database of syncstorage-rs: what each account keeps on the server.
// MariaDB has its own database (MARIADB_SYNCSTORAGE_*), PostgreSQL shares the one
// of the tokenserver. The user id is the tokenserver uid.
type StorageDB struct {
	db       *sql.DB
	postgres bool

	mu     sync.Mutex
	cached map[int64]Usage
	at     time.Time
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
	cfg.User, cfg.Passwd, cfg.DBName = env("STORAGE_DB_USER", ""), env("STORAGE_DB_PASSWORD", ""), env("STORAGE_DB_NAME", "")
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
