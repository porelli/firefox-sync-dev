package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"strings"
	"time"
)

// Installed (again) on every start, after FxA's migrations: idempotent
var fxaPolicySQL = []string{
	"CREATE DATABASE IF NOT EXISTS ffs",
	`CREATE TABLE IF NOT EXISTS ffs.settings (
		name VARCHAR(64) PRIMARY KEY,
		value TEXT NOT NULL,
		updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
	)`,
	`CREATE TABLE IF NOT EXISTS ffs.signup_allowlist (
		entry VARCHAR(255) PRIMARY KEY,
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	)`,
	"DROP FUNCTION IF EXISTS ffs.signup_allowed",
	// an email or its domain (@example.com) on the allowlist; anything but open,
	// allowlist or closed (e.g. a missing setting) denies
	`CREATE FUNCTION ffs.signup_allowed(address VARCHAR(255)) RETURNS BOOLEAN
	READS SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE mode VARCHAR(16) DEFAULT NULL;
		DECLARE normalized VARCHAR(255) DEFAULT LOWER(TRIM(address));
		SELECT value INTO mode FROM ffs.settings WHERE name = 'signups';
		IF mode = 'open' THEN
			RETURN TRUE;
		END IF;
		IF mode = 'allowlist' THEN
			RETURN EXISTS (SELECT 1 FROM ffs.signup_allowlist
				WHERE entry = normalized OR entry = CONCAT('@', SUBSTRING_INDEX(normalized, '@', -1)));
		END IF;
		RETURN FALSE;
	END`,
	// sizes of the accounts databases for the admin UI, which has no access to their
	// tables: the view runs with the privileges of its definer
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.database_sizes AS
		SELECT table_schema AS name, SUM(data_length + index_length) AS bytes
		FROM information_schema.tables
		WHERE table_schema IN ('fxa', 'fxa_oauth', 'fxa_profile', 'pushbox', 'ffs')
		GROUP BY table_schema`,
	// sessions and devices for the admin UI without their token ids: a session token id
	// signs in as its account (Bearer fxs_<id>), ffs_admin never reads one
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.sessions AS
		SELECT uid, LOWER(SHA2(tokenId, 256)) AS ref, uaBrowser, uaOS, createdAt, lastAccessTime
		FROM fxa.sessionTokens`,
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.devices AS
		SELECT d.uid, d.id, COALESCE(NULLIF(d.nameUtf8, ''), d.name) AS name, COALESCE(d.type, '') AS type,
			COALESCE(d.createdAt, 0) AS createdAt,
			GREATEST(COALESCE(s.lastAccessTime, 0), COALESCE(UNIX_TIMESTAMP(r.lastUsedAt) * 1000, 0)) AS lastUsed
		FROM fxa.devices d
		LEFT JOIN fxa.sessionTokens s ON s.tokenId = d.sessionTokenId
		LEFT JOIN fxa_oauth.refreshTokens r ON r.token = d.refreshTokenId`,
	// signing out reads the token ids too: MySQL needs SELECT on the columns of a
	// DELETE ... WHERE, so these run with the privileges of their definer
	"DROP PROCEDURE IF EXISTS ffs.sign_out_session",
	// p_ref: SHA-256 of the token id, as shown by ffs.sessions
	`CREATE PROCEDURE ffs.sign_out_session(p_uid BINARY(16), p_ref BINARY(32))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_token BINARY(32) DEFAULT NULL;
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		SELECT tokenId INTO v_token FROM fxa.sessionTokens WHERE uid = p_uid AND UNHEX(SHA2(tokenId, 256)) = p_ref;
		IF v_token IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such session';
		END IF;
		START TRANSACTION;
		DELETE FROM fxa.devices WHERE uid = p_uid AND sessionTokenId = v_token;
		DELETE FROM fxa.sessionTokens WHERE tokenId = v_token;
		COMMIT;
	END`,
	"DROP PROCEDURE IF EXISTS ffs.sign_out_device",
	`CREATE PROCEDURE ffs.sign_out_device(p_uid BINARY(16), p_device BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_found INT DEFAULT 0;
		DECLARE v_session, v_refresh BINARY(32) DEFAULT NULL;
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		SELECT COUNT(*), MAX(sessionTokenId), MAX(refreshTokenId) INTO v_found, v_session, v_refresh
			FROM fxa.devices WHERE uid = p_uid AND id = p_device;
		IF v_found = 0 THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such device';
		END IF;
		START TRANSACTION;
		IF v_session IS NOT NULL THEN
			DELETE FROM fxa.sessionTokens WHERE tokenId = v_session;
		END IF;
		IF v_refresh IS NOT NULL THEN
			DELETE FROM fxa_oauth.refreshTokens WHERE token = v_refresh;
		END IF;
		DELETE FROM fxa.devices WHERE uid = p_uid AND id = p_device;
		COMMIT;
	END`,
	"DROP TRIGGER IF EXISTS fxa.ffs_signup_policy",
	// the gate in front of the accounts API answers with a proper error first, this
	// catches whatever reaches the auth server another way
	`CREATE TRIGGER fxa.ffs_signup_policy BEFORE INSERT ON fxa.accounts FOR EACH ROW
	BEGIN
		IF NOT ffs.signup_allowed(NEW.normalizedEmail) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sign-up refused by the firefox-sync sign-up policy';
		END IF;
	END`,
}

// The admin UI connects as ffs_admin: it reads the accounts and can only disable
// them, sign out their devices and sessions, it cannot change anything else in FxA.
// Revoked first: what earlier versions granted goes (the token ids).
var fxaAdminGrants = []string{
	"REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'ffs_admin'@'%'",
	"GRANT SELECT, INSERT, UPDATE, DELETE ON ffs.settings TO 'ffs_admin'@'%'",
	"GRANT SELECT, INSERT, UPDATE, DELETE ON ffs.signup_allowlist TO 'ffs_admin'@'%'",
	// the views are updatable: SELECT only
	"GRANT SELECT ON ffs.database_sizes TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.sessions TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.devices TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON FUNCTION ffs.signup_allowed TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.sign_out_session TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.sign_out_device TO 'ffs_admin'@'%'",
	"GRANT SELECT (uid, email, emailVerified, createdAt, disabledAt), UPDATE (disabledAt) ON fxa.accounts TO 'ffs_admin'@'%'",
	// disabling an account signs it out everywhere
	"GRANT SELECT (uid), DELETE ON fxa.sessionTokens TO 'ffs_admin'@'%'",
	"GRANT SELECT (userId), DELETE ON fxa_oauth.refreshTokens TO 'ffs_admin'@'%'",
	"GRANT SELECT (userId), DELETE ON fxa_oauth.tokens TO 'ffs_admin'@'%'",
	"GRANT SELECT (userId), DELETE ON fxa_oauth.codes TO 'ffs_admin'@'%'",
}

func fxaInit(ctx context.Context) error {
	cfg := fxaConfig(env("FXA_DB_ROOT_USER", "root"), env("FXA_DB_ROOT_PASSWORD", ""))
	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	// the migrations create fxa.accounts, compose and the quadlets start this after them
	deadline := time.Now().Add(time.Duration(envInt("FXA_INIT_TIMEOUT", 120)) * time.Second)
	for {
		var n int
		err = db.QueryRowContext(ctx, `SELECT COUNT(*) FROM information_schema.tables
			WHERE table_schema = 'fxa' AND table_name = 'accounts'`).Scan(&n)
		if err == nil && n == 1 {
			break
		}
		if time.Now().After(deadline) {
			if err == nil {
				err = fmt.Errorf("fxa.accounts does not exist, did the FxA migrations run?")
			}
			return err
		}
		log.Printf("waiting for the accounts database: %v", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}

	for _, stmt := range fxaPolicySQL {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("%s: %w", strings.SplitN(stmt, "\n", 2)[0], err)
		}
	}

	if password := env("FXA_ADMIN_DB_PASSWORD", ""); password != "" {
		// FxA's MySQL only allows mysql_native_password (see docker-compose.fxa.yml)
		if _, err := db.ExecContext(ctx, "CREATE USER IF NOT EXISTS 'ffs_admin'@'%' IDENTIFIED BY ?", password); err != nil {
			return fmt.Errorf("creating ffs_admin: %w", err)
		}
		if _, err := db.ExecContext(ctx, "ALTER USER 'ffs_admin'@'%' IDENTIFIED BY ?", password); err != nil {
			return fmt.Errorf("setting the ffs_admin password: %w", err)
		}
		for _, stmt := range fxaAdminGrants {
			if _, err := db.ExecContext(ctx, stmt); err != nil {
				return fmt.Errorf("%s: %w", stmt, err)
			}
		}
	}

	policy, err := applyEnvPolicy(ctx, db)
	if err != nil {
		return err
	}
	log.Printf("sign-ups: %s", describePolicy(policy))
	return nil
}

// applyEnvPolicy sets FXA_SIGNUPS and FXA_SIGNUP_ALLOWLIST from .env when they changed
// since the last start (or on the first one); otherwise the values set in the admin
// UI stay
func applyEnvPolicy(ctx context.Context, db *sql.DB) (*SignupPolicy, error) {
	mode, err := ParseMode(env("FXA_SIGNUPS", SignupsOpen))
	if err != nil {
		return nil, err
	}
	allowlist, err := ParseAllowlist(env("FXA_SIGNUP_ALLOWLIST", ""))
	if err != nil {
		return nil, fmt.Errorf("FXA_SIGNUP_ALLOWLIST: %w", err)
	}
	if mode == SignupsAllowlist && len(allowlist) == 0 {
		log.Printf("warning: FXA_SIGNUPS=allowlist with an empty FXA_SIGNUP_ALLOWLIST, nobody can sign up")
	}
	policy := &SignupPolicy{Mode: mode, Allowlist: allowlist}
	snapshot := mode + " " + strings.Join(allowlist, ",")

	var last string
	err = db.QueryRowContext(ctx, "SELECT value FROM ffs.settings WHERE name = 'env'").Scan(&last)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	if err == nil && last == snapshot {
		current := &FxaDB{db: db}
		return current.Policy(ctx)
	}
	return policy, setPolicy(ctx, db, policy, snapshot)
}

func describePolicy(p *SignupPolicy) string {
	if p.Mode == SignupsAllowlist {
		return fmt.Sprintf("allowlist (%s)", strings.Join(p.Allowlist, ", "))
	}
	return p.Mode
}
