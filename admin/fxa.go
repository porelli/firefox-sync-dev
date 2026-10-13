package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"regexp"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
)

// Self-hosted Mozilla accounts database (MySQL). The sign-up policy lives in its own
// database (ffs), FxA's migrations never touch it.

const (
	SignupsOpen      = "open"
	SignupsAllowlist = "allowlist"
	SignupsClosed    = "closed"
)

type FxaDB struct {
	db    *sql.DB
	redis string // host:port of FxA's Redis, for the access tokens
}

type FxaAccount struct {
	UID       string
	Email     string
	Verified  bool
	CreatedAt time.Time
	Disabled  bool
	Sync      bool // has used this Sync server
}

type SignupPolicy struct {
	Mode      string
	Allowlist []string
}

func fxaConfig(user, password string) *mysql.Config {
	cfg := mysql.NewConfig()
	cfg.Net = "tcp"
	cfg.Addr = net.JoinHostPort(env("FXA_DB_HOST", "fxa-db"), env("FXA_DB_PORT", "3306"))
	cfg.User, cfg.Passwd = user, password
	cfg.Timeout = 5 * time.Second
	// client side placeholders: CREATE USER and GRANT cannot be prepared
	cfg.InterpolateParams = true
	return cfg
}

func openFxaDB() (*FxaDB, error) {
	if env("FXA_DB_HOST", "") == "" {
		return nil, nil
	}
	db, err := sql.Open("mysql", fxaConfig(env("FXA_DB_USER", "ffs_admin"), env("FXA_DB_PASSWORD", "")).FormatDSN())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetConnMaxLifetime(5 * time.Minute)
	return &FxaDB{db: db, redis: env("FXA_REDIS", "fxa-redis:6379")}, nil
}

func (f *FxaDB) SignupAllowed(ctx context.Context, email string) (bool, error) {
	var allowed bool
	err := f.db.QueryRowContext(ctx, "SELECT ffs.signup_allowed(?)", email).Scan(&allowed)
	return allowed, err
}

func (f *FxaDB) Policy(ctx context.Context) (*SignupPolicy, error) {
	p := &SignupPolicy{}
	if err := f.db.QueryRowContext(ctx, "SELECT value FROM ffs.settings WHERE name = 'signups'").Scan(&p.Mode); err != nil {
		return nil, err
	}
	rows, err := f.db.QueryContext(ctx, "SELECT entry FROM ffs.signup_allowlist ORDER BY entry")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var e string
		if err := rows.Scan(&e); err != nil {
			return nil, err
		}
		p.Allowlist = append(p.Allowlist, e)
	}
	return p, rows.Err()
}

func (f *FxaDB) SetPolicy(ctx context.Context, p *SignupPolicy) error {
	return setPolicy(ctx, f.db, p, "")
}

// setPolicy replaces the sign-up mode and allowlist; envSnapshot, when set, records
// the .env values they came from (see applyEnvPolicy)
func setPolicy(ctx context.Context, db *sql.DB, p *SignupPolicy, envSnapshot string) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO ffs.settings (name, value) VALUES ('signups', ?)
		ON DUPLICATE KEY UPDATE value = VALUES(value)`, p.Mode); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM ffs.signup_allowlist"); err != nil {
		return err
	}
	for _, e := range p.Allowlist {
		if _, err := tx.ExecContext(ctx, "INSERT INTO ffs.signup_allowlist (entry) VALUES (?)", e); err != nil {
			return err
		}
	}
	if envSnapshot != "" {
		if _, err := tx.ExecContext(ctx, `INSERT INTO ffs.settings (name, value) VALUES ('env', ?)
			ON DUPLICATE KEY UPDATE value = VALUES(value)`, envSnapshot); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (f *FxaDB) Accounts(ctx context.Context) ([]FxaAccount, error) {
	rows, err := f.db.QueryContext(ctx, `SELECT HEX(uid), email, emailVerified, createdAt, disabledAt IS NOT NULL
		FROM fxa.accounts ORDER BY createdAt`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var accounts []FxaAccount
	for rows.Next() {
		var a FxaAccount
		var created int64
		if err := rows.Scan(&a.UID, &a.Email, &a.Verified, &created, &a.Disabled); err != nil {
			return nil, err
		}
		a.UID = strings.ToLower(a.UID)
		a.CreatedAt = time.UnixMilli(created)
		accounts = append(accounts, a)
	}
	return accounts, rows.Err()
}

// SetDisabled disables or re-enables an account. FxA refuses sign-ins and sessions of
// disabled accounts, but not the OAuth tokens Firefox already has (Mozilla's own admin
// panel leaves them too): revoke them. The tokenserver remembers a verified access
// token for 5 minutes, and the Sync tokens it gave out last up to 1 hour.
func (f *FxaDB) SetDisabled(ctx context.Context, uid string, disabled bool) error {
	id, err := hex.DecodeString(uid)
	if err != nil || len(id) != 16 {
		return fmt.Errorf("invalid account id")
	}
	tx, err := f.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var res sql.Result
	if disabled {
		res, err = tx.ExecContext(ctx, "UPDATE fxa.accounts SET disabledAt = ? WHERE uid = ? AND disabledAt IS NULL", time.Now().UnixMilli(), id)
	} else {
		res, err = tx.ExecContext(ctx, "UPDATE fxa.accounts SET disabledAt = NULL WHERE uid = ?", id)
	}
	if err != nil {
		return err
	}
	if disabled {
		if n, _ := res.RowsAffected(); n == 0 {
			var exists int
			if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM fxa.accounts WHERE uid = ?", id).Scan(&exists); err != nil {
				return err
			}
			if exists == 0 {
				return fmt.Errorf("no such account")
			}
		}
		for _, q := range []string{
			"DELETE FROM fxa.sessionTokens WHERE uid = ?",
			"DELETE FROM fxa_oauth.refreshTokens WHERE userId = ?",
			"DELETE FROM fxa_oauth.tokens WHERE userId = ?",
			// the token endpoint does not check disabledAt: no code traded for new tokens
			"DELETE FROM fxa_oauth.codes WHERE userId = ?",
		} {
			if _, err := tx.ExecContext(ctx, q, id); err != nil {
				return err
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if disabled {
		if _, err := revokeRedisTokens(ctx, f.redis, strings.ToLower(uid)); err != nil {
			return fmt.Errorf("account disabled, but its access tokens are still valid until they expire: %w", err)
		}
	}
	return nil
}

func (f *FxaDB) Ping(ctx context.Context) error {
	return f.db.PingContext(ctx)
}

var (
	emailEntry  = regexp.MustCompile(`^[^@\s,;]+@[a-z0-9-]+(\.[a-z0-9-]+)+$`)
	domainEntry = regexp.MustCompile(`^@?[a-z0-9-]+(\.[a-z0-9-]+)+$`)
)

// ParseAllowlist takes emails (alice@example.com) and domains (@example.com or
// example.com), separated by commas, spaces or new lines
func ParseAllowlist(s string) ([]string, error) {
	seen := map[string]bool{}
	var entries []string
	for _, e := range strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return r == ',' || r == ';' || r == ' ' || r == '\n' || r == '\r' || r == '\t'
	}) {
		switch {
		case emailEntry.MatchString(e):
		case domainEntry.MatchString(e):
			if !strings.HasPrefix(e, "@") {
				e = "@" + e
			}
		default:
			return nil, fmt.Errorf("not an email or a domain: %q", e)
		}
		if len(e) > 255 {
			return nil, fmt.Errorf("too long: %q", e)
		}
		if !seen[e] {
			seen[e] = true
			entries = append(entries, e)
		}
	}
	return entries, nil
}

func ParseMode(s string) (string, error) {
	switch m := strings.ToLower(strings.TrimSpace(s)); m {
	case SignupsOpen, SignupsAllowlist, SignupsClosed:
		return m, nil
	}
	return "", fmt.Errorf("sign-ups must be open, allowlist or closed, not %q", s)
}

type Device struct {
	ID         string
	Name, Type string
	CreatedAt  time.Time
	LastUsed   time.Time
}

type Session struct {
	// SHA-256 of the token id: the id itself signs in (Bearer fxs_<id>), never show it
	Ref         string
	Browser, OS string
	CreatedAt   time.Time
	LastUsed    time.Time
}

// Devices registered by the browsers of an account (Firefox names them, e.g.
// "Firefox on laptop"), with when they last used it
func (f *FxaDB) Devices(ctx context.Context, uid string) ([]Device, []Session, error) {
	id, err := hex.DecodeString(uid)
	if err != nil || len(id) != 16 {
		return nil, nil, fmt.Errorf("invalid account id")
	}
	rows, err := f.db.QueryContext(ctx, `SELECT LOWER(HEX(id)), name, type, createdAt, lastUsed
		FROM ffs.devices WHERE uid = ? ORDER BY createdAt`, id)
	if err != nil {
		return nil, nil, err
	}
	var devices []Device
	for rows.Next() {
		var d Device
		var name sql.NullString
		var created int64
		var used float64
		if err := rows.Scan(&d.ID, &name, &d.Type, &created, &used); err != nil {
			rows.Close()
			return nil, nil, err
		}
		d.Name, d.CreatedAt, d.LastUsed = name.String, ms(created), ms(int64(used))
		devices = append(devices, d)
	}
	rows.Close()
	rows, err = f.db.QueryContext(ctx, `SELECT ref, COALESCE(uaBrowser, ''), COALESCE(uaOS, ''), createdAt, COALESCE(lastAccessTime, 0)
		FROM ffs.sessions WHERE uid = ? ORDER BY createdAt DESC`, id)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var sessions []Session
	for rows.Next() {
		var s Session
		var created, used int64
		if err := rows.Scan(&s.Ref, &s.Browser, &s.OS, &created, &used); err != nil {
			return nil, nil, err
		}
		s.CreatedAt, s.LastUsed = ms(created), ms(used)
		sessions = append(sessions, s)
	}
	return devices, sessions, rows.Err()
}

// Recent sign-ups and new devices, for the activity log
func (f *FxaDB) Recent(ctx context.Context, since time.Time) ([]Event, error) {
	var events []Event
	rows, err := f.db.QueryContext(ctx, "SELECT email, createdAt FROM fxa.accounts WHERE createdAt >= ?", since.UnixMilli())
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var email string
		var at int64
		if err := rows.Scan(&email, &at); err != nil {
			rows.Close()
			return nil, err
		}
		events = append(events, Event{At: ms(at), Kind: "sign-up", Detail: email})
	}
	rows.Close()
	rows, err = f.db.QueryContext(ctx, `SELECT a.email, COALESCE(d.name, ''), d.type, d.createdAt
		FROM ffs.devices d JOIN fxa.accounts a ON a.uid = d.uid WHERE d.createdAt >= ?`, since.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var email, name, kind string
		var at int64
		if err := rows.Scan(&email, &name, &kind, &at); err != nil {
			return nil, err
		}
		events = append(events, Event{At: ms(at), Kind: "new device", Detail: fmt.Sprintf("%s: %s (%s)", email, name, kind)})
	}
	return events, rows.Err()
}

// SignOutDevice removes a device and the tokens it signed in with, like "sign out"
// in the devices list of the account settings; the account stays usable elsewhere.
// Its access tokens live on until they expire (FXA_ACCESS_TOKEN_LIFETIME).
func (f *FxaDB) SignOutDevice(ctx context.Context, uid, deviceID string) error {
	account, err := hex.DecodeString(uid)
	if err != nil || len(account) != 16 {
		return fmt.Errorf("invalid account id")
	}
	device, err := hex.DecodeString(deviceID)
	if err != nil || len(device) != 16 {
		return fmt.Errorf("invalid device id")
	}
	// a procedure of fxa-init: ffs_admin cannot read the token ids
	_, err = f.db.ExecContext(ctx, "CALL ffs.sign_out_device(?, ?)", account, device)
	return procedureError(err)
}

// SignOutSession ends one session (ref: SHA-256 of its token id), and its device
func (f *FxaDB) SignOutSession(ctx context.Context, uid, ref string) error {
	account, err := hex.DecodeString(uid)
	if err != nil || len(account) != 16 {
		return fmt.Errorf("invalid account id")
	}
	hash, err := hex.DecodeString(ref)
	if err != nil || len(hash) != 32 {
		return fmt.Errorf("invalid session")
	}
	_, err = f.db.ExecContext(ctx, "CALL ffs.sign_out_session(?, ?)", account, hash)
	return procedureError(err)
}

// procedureError: the message of SIGNAL in the procedures (no such device...) as is
func procedureError(err error) error {
	var e *mysql.MySQLError
	if errors.As(err, &e) && e.SQLState == [5]byte{'4', '5', '0', '0', '0'} {
		return errors.New(e.Message)
	}
	return err
}

// Size of the accounts databases, through a view of fxa-init (ffs_admin cannot see
// the tables themselves)
func (f *FxaDB) Size(ctx context.Context) (int64, error) {
	var n int64
	err := f.db.QueryRowContext(ctx, "SELECT COALESCE(SUM(bytes), 0) FROM ffs.database_sizes").Scan(&n)
	return n, err
}
