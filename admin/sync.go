package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/go-sql-driver/mysql"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// Tokenserver database (MariaDB or PostgreSQL), the tables of syncstorage-rs plus
// the config table of syncstorage-rs-init (max_users), and the admin UI's own tables
type SyncDB struct {
	db       *sql.DB
	postgres bool
	// own: the admin UI's own database (ADMIN_DB_NAME, owndb.go), where its tables are,
	// out of the Sync server's reach; nil: they are in the tokenserver database (an
	// install from before ADMIN_DB_PASSWORD)
	own     *sql.DB
	ownName string
	// what moving the tables of before into own did (owndb.go)
	moved moveState
}

type SyncNode struct {
	ID          int64
	Node        string
	Capacity    int
	CurrentLoad int
	Available   int
	Downed      bool
	Backoff     int
	Users       int // accounts on it (their current row)
}

type SyncUser struct {
	UID       string // FxA uid, the local part of the tokenserver email
	StorageID int64  // tokenserver uid of the current keys: the user id in the storage database
	CreatedAt time.Time
}

type SyncStatus struct {
	MaxUsers int
	// MAX_USERS=unlimited: no limit (MaxUsers 0)
	Unlimited bool
	Users     int
	Nodes     []SyncNode
}

// Limit: the accounts against max users
func (st *SyncStatus) Limit() Limit {
	return Limit{Count: st.Users, Max: st.MaxUsers, Unlimited: st.Unlimited}
}

func openSyncDB() (*SyncDB, error) {
	kind := env("TOKENSERVER_DB_TYPE", "mysql")
	host := env("TOKENSERVER_DB_HOST", "")
	if host == "" {
		return nil, fmt.Errorf("TOKENSERVER_DB_HOST is not set")
	}
	if kind != "mysql" && kind != "postgres" {
		return nil, fmt.Errorf("TOKENSERVER_DB_TYPE must be mysql or postgres, not %q", kind)
	}
	user, password, ownUser, own, err := dbCredentials("TOKENSERVER")
	if err != nil {
		return nil, err
	}
	s := &SyncDB{postgres: kind == "postgres"}
	if s.db, err = openDB(kind, host, user, password, env("TOKENSERVER_DB_NAME", "")); err != nil {
		return nil, err
	}
	if own != "" {
		// on the same server, as its other user (owndb.go)
		if s.own, err = openDB(kind, host, ownUser, password, own); err != nil {
			return nil, err
		}
		s.ownName = own
	}
	return s, nil
}

// openDB: a pool on a database of the tokenserver's server (TOKENSERVER_DB_PORT...)
func openDB(kind, host, user, password, name string) (*sql.DB, error) {
	var db *sql.DB
	var err error
	if kind == "mysql" {
		cfg := mysql.NewConfig()
		cfg.Net = "tcp"
		cfg.Addr = net.JoinHostPort(host, env("TOKENSERVER_DB_PORT", "3306"))
		cfg.User, cfg.Passwd, cfg.DBName = user, password, name
		cfg.Timeout = 5 * time.Second
		db, err = sql.Open("mysql", cfg.FormatDSN())
	} else {
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
	}
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetConnMaxLifetime(5 * time.Minute)
	return db, nil
}

// mine: where the admin UI's own tables are (the event log, the audit trail, notes...)
func (s *SyncDB) mine() *sql.DB {
	if s.own != nil {
		return s.own
	}
	return s.db
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
	// a number, or unlimited (db_init.sql); anything else denies, as the trigger does
	st.MaxUsers, st.Unlimited, _ = parseLimitValue(maxUsers.String)
	// accounts, not rows: syncstorage-rs adds a row when the keys of an account change
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(DISTINCT email) FROM users").Scan(&st.Users); err != nil {
		return nil, err
	}
	perNode := map[int64]int{}
	rows, err := s.db.QueryContext(ctx, "SELECT nodeid, COUNT(DISTINCT email) FROM users WHERE replaced_at IS NULL GROUP BY nodeid")
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id int64
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			rows.Close()
			return nil, err
		}
		perNode[id] = n
	}
	rows.Close()
	rows, err = s.db.QueryContext(ctx, `SELECT n.id, n.node, n.capacity, n.current_load, n.available, n.downed, n.backoff
		FROM nodes n JOIN services s ON n.service = s.id WHERE s.service = 'sync-1.5' ORDER BY n.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var n SyncNode
		var downed int
		if err := rows.Scan(&n.ID, &n.Node, &n.Capacity, &n.CurrentLoad, &n.Available, &downed, &n.Backoff); err != nil {
			return nil, err
		}
		n.Downed, n.Users = downed != 0, perNode[n.ID]
		st.Nodes = append(st.Nodes, n)
	}
	return st, rows.Err()
}

// EmailDomains: the accounts of the tokenserver per domain of their email
// (<uid>@FXA_EMAIL_DOMAIN of when they first synced)
func (s *SyncDB) EmailDomains(ctx context.Context) (map[string]int, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT DISTINCT email FROM users")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	domains := map[string]int{}
	for rows.Next() {
		var email string
		if err := rows.Scan(&email); err != nil {
			return nil, err
		}
		_, domain, _ := strings.Cut(email, "@")
		domains[strings.ToLower(domain)]++
	}
	return domains, rows.Err()
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

// maxUsersEditable tells from MAX_USERS (as in .env) whether the admin UI manages the
// limit: with initial:N the init container sets it only when there is none yet. N or
// fixed:N is set again on every start, so a change here would not last: read-only, and
// so when MAX_USERS is not given.
func maxUsersEditable(maxUsers string) bool {
	return limitEditable(maxUsers, false)
}

// SetMaxUsers changes the limit enforced by the tokenserver trigger (syncstorage-rs-init),
// with MAX_USERS=initial:N (see maxUsersEditable); unlimited: no limit
func (s *SyncDB) SetMaxUsers(ctx context.Context, maxUsers int, unlimited bool) error {
	if !unlimited && (maxUsers < 0 || maxUsers > math.MaxInt32) {
		// the triggers read it into an INT: refusing every new account
		return fmt.Errorf("max users must be from 0 to %d", math.MaxInt32)
	}
	value := Limit{Max: maxUsers, Unlimited: unlimited}.Setting()
	// MariaDB and MySQL: a procedure of the init container, the admin UI's user cannot
	// write the tokenserver's tables (PostgreSQL: a grant on this column, by their owner)
	query, args := "CALL ffs_set_max_users(?)", []any{value}
	if s.postgres {
		query, args = "UPDATE config SET config_value = $1 WHERE config_key = $2", []any{value, "max_users"}
	}
	res, err := s.db.ExecContext(ctx, query, args...)
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

// Notes and labels of the accounts (ffs_account_notes), by uid: the FxA uid, or with
// Mozilla's accounts the local part of the tokenserver email
type Note struct {
	Text      string
	UpdatedAt time.Time
	UpdatedBy string
}

const maxNote = 500

func (s *SyncDB) Notes(ctx context.Context) (map[string]Note, error) {
	rows, err := s.mine().QueryContext(ctx, "SELECT uid, note, updated_at, updated_by FROM ffs_account_notes")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	notes := map[string]Note{}
	for rows.Next() {
		var uid string
		var n Note
		var at int64
		if err := rows.Scan(&uid, &n.Text, &at, &n.UpdatedBy); err != nil {
			return nil, err
		}
		n.UpdatedAt = ms(at)
		notes[uid] = n
	}
	return notes, rows.Err()
}

// Note of an account, nil without one
func (s *SyncDB) Note(ctx context.Context, uid string) (*Note, error) {
	var n Note
	var at int64
	err := s.mine().QueryRowContext(ctx, s.q("SELECT note, updated_at, updated_by FROM ffs_account_notes WHERE uid = ?"), uid).Scan(&n.Text, &at, &n.UpdatedBy)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	n.UpdatedAt = ms(at)
	return &n, nil
}

// cleanNote: one line, without control characters (strings.Map also makes it valid
// UTF-8, which the database insists on); an error over maxNote characters
func cleanNote(note string) (string, error) {
	note = strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, note))
	if n := utf8.RuneCountInString(note); n > maxNote {
		return "", fmt.Errorf("a note has at most %d characters, not %d", maxNote, n)
	}
	return note, nil
}

// SetNote replaces the note of an account ("": removes it)
func (s *SyncDB) SetNote(ctx context.Context, uid, note, by string) error {
	note, err := cleanNote(note)
	if err != nil {
		return err
	}
	if note == "" {
		_, err := s.mine().ExecContext(ctx, s.q("DELETE FROM ffs_account_notes WHERE uid = ?"), uid)
		return err
	}
	upsert := `INSERT INTO ffs_account_notes (uid, note, updated_at, updated_by) VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE note = VALUES(note), updated_at = VALUES(updated_at), updated_by = VALUES(updated_by)`
	if s.postgres {
		upsert = `INSERT INTO ffs_account_notes (uid, note, updated_at, updated_by) VALUES ($1, $2, $3, $4)
		ON CONFLICT (uid) DO UPDATE SET note = EXCLUDED.note, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by`
	}
	_, err = s.mine().ExecContext(ctx, upsert, uid, note, time.Now().UnixMilli(), oneLine(by, 255))
	return err
}

func (s *SyncDB) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

// Size of the database (with PostgreSQL also the storage, it is the same database)
func (s *SyncDB) Size(ctx context.Context) (int64, error) {
	return dbSize(ctx, s.db, s.postgres)
}

func dbSize(ctx context.Context, db *sql.DB, postgres bool) (int64, error) {
	var n int64
	if postgres {
		err := db.QueryRowContext(ctx, `SELECT pg_database_size(current_database())`).Scan(&n)
		return n, err
	}
	err := withFreshStats(ctx, db, func(c *sql.Conn) error {
		return c.QueryRowContext(ctx, `SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()`).Scan(&n)
	})
	return n, err
}

// withFreshStats runs the query of a size on a connection that reads the sizes of
// the tables from InnoDB: MySQL 8 caches them in information_schema for a day
// (information_schema_stats_expiry), and a database growing fast would show a day
// late. MariaDB has no cache (nor the variable: error 1193)
func withFreshStats(ctx context.Context, db *sql.DB, query func(*sql.Conn) error) error {
	c, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	if _, err := c.ExecContext(ctx, "SET SESSION information_schema_stats_expiry = 0"); err != nil {
		var e *mysql.MySQLError
		if !errors.As(err, &e) || e.Number != 1193 {
			return err
		}
	}
	return query(c)
}
