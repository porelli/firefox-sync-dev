package main

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// Tokenserver database (MariaDB or PostgreSQL), the tables of syncstorage-rs plus
// the config table of syncstorage-rs-init (max_users)
type SyncDB struct {
	db       *sql.DB
	postgres bool
}

type SyncNode struct {
	Node        string
	Capacity    int
	CurrentLoad int
	Available   int
	Downed      bool
}

type SyncUser struct {
	UID       string // FxA uid, the local part of the tokenserver email
	StorageID int64  // tokenserver uid of the current keys: the user id in the storage database
	CreatedAt time.Time
}

type SyncStatus struct {
	MaxUsers int
	Users    int
	Nodes    []SyncNode
}

func openSyncDB() (*SyncDB, error) {
	kind := env("TOKENSERVER_DB_TYPE", "mysql")
	host := env("TOKENSERVER_DB_HOST", "")
	if host == "" {
		return nil, fmt.Errorf("TOKENSERVER_DB_HOST is not set")
	}
	user, password, name := env("TOKENSERVER_DB_USER", ""), env("TOKENSERVER_DB_PASSWORD", ""), env("TOKENSERVER_DB_NAME", "")
	var db *sql.DB
	var err error
	switch kind {
	case "mysql":
		cfg := mysql.NewConfig()
		cfg.Net = "tcp"
		cfg.Addr = net.JoinHostPort(host, env("TOKENSERVER_DB_PORT", "3306"))
		cfg.User, cfg.Passwd, cfg.DBName = user, password, name
		cfg.Timeout = 5 * time.Second
		db, err = sql.Open("mysql", cfg.FormatDSN())
	case "postgres":
		dsn := url.URL{
			Scheme: "postgres",
			User:   url.UserPassword(user, password),
			Host:   net.JoinHostPort(host, env("TOKENSERVER_DB_PORT", "5432")),
			Path:   "/" + name,
		}
		q := dsn.Query()
		q.Set("sslmode", env("TOKENSERVER_DB_SSLMODE", "disable"))
		q.Set("connect_timeout", "5")
		dsn.RawQuery = q.Encode()
		db, err = sql.Open("pgx", dsn.String())
	default:
		return nil, fmt.Errorf("TOKENSERVER_DB_TYPE must be mysql or postgres, not %q", kind)
	}
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetConnMaxLifetime(5 * time.Minute)
	return &SyncDB{db: db, postgres: kind == "postgres"}, nil
}

// q turns the ? placeholders into $1, $2... for PostgreSQL
func (s *SyncDB) q(query string) string {
	if !s.postgres {
		return query
	}
	var b strings.Builder
	n := 0
	for _, c := range query {
		if c == '?' {
			n++
			b.WriteString("$" + strconv.Itoa(n))
		} else {
			b.WriteRune(c)
		}
	}
	return b.String()
}

func (s *SyncDB) Status(ctx context.Context) (*SyncStatus, error) {
	st := &SyncStatus{}
	var maxUsers sql.NullString
	err := s.db.QueryRowContext(ctx, s.q("SELECT config_value FROM config WHERE config_key = ?"), "max_users").Scan(&maxUsers)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	st.MaxUsers, _ = strconv.Atoi(maxUsers.String)
	// accounts, not rows: syncstorage-rs adds a row when the keys of an account change
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(DISTINCT email) FROM users").Scan(&st.Users); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT n.node, n.capacity, n.current_load, n.available, n.downed
		FROM nodes n JOIN services s ON n.service = s.id WHERE s.service = 'sync-1.5' ORDER BY n.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var n SyncNode
		var downed int
		if err := rows.Scan(&n.Node, &n.Capacity, &n.CurrentLoad, &n.Available, &downed); err != nil {
			return nil, err
		}
		n.Downed = downed != 0
		st.Nodes = append(st.Nodes, n)
	}
	return st, rows.Err()
}

func (s *SyncDB) Users(ctx context.Context) ([]SyncUser, error) {
	// a new row (and storage user id) every time the keys of an account change
	rows, err := s.db.QueryContext(ctx, `SELECT email, MIN(created_at), COALESCE(MAX(CASE WHEN replaced_at IS NULL THEN uid END), MAX(uid))
		FROM users GROUP BY email ORDER BY MIN(created_at)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var users []SyncUser
	for rows.Next() {
		var email string
		var created, id int64
		if err := rows.Scan(&email, &created, &id); err != nil {
			return nil, err
		}
		uid, _, _ := strings.Cut(email, "@")
		users = append(users, SyncUser{UID: strings.ToLower(uid), StorageID: id, CreatedAt: time.UnixMilli(created)})
	}
	return users, rows.Err()
}

func (s *SyncDB) User(ctx context.Context, uid string) (*SyncUser, error) {
	users, err := s.Users(ctx)
	if err != nil {
		return nil, err
	}
	for i := range users {
		if users[i].UID == uid {
			return &users[i], nil
		}
	}
	return nil, nil
}

// SetMaxUsers changes the limit enforced by the tokenserver trigger (syncstorage-rs-init).
// MAX_USERS in .env replaces it again only when it is changed there.
func (s *SyncDB) SetMaxUsers(ctx context.Context, maxUsers int) error {
	if maxUsers < 0 || maxUsers > math.MaxInt32 {
		// the triggers read it into an INT: refusing every new account
		return fmt.Errorf("max users must be from 0 to %d", math.MaxInt32)
	}
	res, err := s.db.ExecContext(ctx, s.q("UPDATE config SET config_value = ? WHERE config_key = ?"), strconv.Itoa(maxUsers), "max_users")
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		// MariaDB counts changed rows: same value, or the init container never ran
		var exists int
		if err := s.db.QueryRowContext(ctx, s.q("SELECT COUNT(*) FROM config WHERE config_key = ?"), "max_users").Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			return fmt.Errorf("no max_users setting, has the tokenserver init container run?")
		}
	}
	return nil
}

func (s *SyncDB) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

// Size of the database (with PostgreSQL also the storage, it is the same database)
func (s *SyncDB) Size(ctx context.Context) (int64, error) {
	return dbSize(ctx, s.db, s.postgres)
}

func dbSize(ctx context.Context, db *sql.DB, postgres bool) (int64, error) {
	query := `SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()`
	if postgres {
		query = `SELECT pg_database_size(current_database())`
	}
	var n int64
	err := db.QueryRowContext(ctx, query).Scan(&n)
	return n, err
}
