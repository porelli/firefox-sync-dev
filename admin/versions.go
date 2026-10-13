package main

import (
	"context"
	"database/sql"
	"strings"
)

// Versions of the components that have no /__version__ endpoint

// version is set at build time (-ldflags "-X main.version=..."), see Dockerfile
var version = "dev"

func dbVersion(ctx context.Context, db *sql.DB, postgres bool) (string, error) {
	var v string
	if postgres {
		// "PostgreSQL 18.0 (Debian 18.0-1.pgdg13+3) on ..." -> "PostgreSQL 18.0"
		if err := db.QueryRowContext(ctx, "SHOW server_version").Scan(&v); err != nil {
			return "", err
		}
		return "PostgreSQL " + strings.Fields(v)[0], nil
	}
	// "11.8.3-MariaDB-ubu2404" or "8.4.6"
	if err := db.QueryRowContext(ctx, "SELECT VERSION()").Scan(&v); err != nil {
		return "", err
	}
	if base, _, found := strings.Cut(v, "-MariaDB"); found {
		return "MariaDB " + base, nil
	}
	return "MySQL " + strings.SplitN(v, "-", 2)[0], nil
}

func (s *SyncDB) Version(ctx context.Context) (string, error) {
	return dbVersion(ctx, s.db, s.postgres)
}

func (s *StorageDB) Version(ctx context.Context) (string, error) {
	return dbVersion(ctx, s.db, s.postgres)
}

func (f *FxaDB) Version(ctx context.Context) (string, error) {
	return dbVersion(ctx, f.db, false)
}

// redisVersion reads redis_version from INFO server
func redisVersion(ctx context.Context, addr string) (string, error) {
	conn, err := dialRedis(ctx, addr)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	reply, err := conn.Do("INFO", "server")
	if err != nil {
		return "", err
	}
	info, _ := reply.(string)
	for _, line := range strings.Split(info, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "redis_version:"); ok {
			return "Redis " + v, nil
		}
	}
	return "", nil
}
