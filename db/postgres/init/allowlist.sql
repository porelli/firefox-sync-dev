-- SYNC_ALLOWED_ACCOUNTS, invite-only Sync (docs/limits.md#sync_allowed_accounts): applied
-- by db_init.sh after db_init.sql, every start, as the owner of the Sync tables. db_init.sh
-- appends the statements of the setting (the list, on or off in the config table).

-- the account ids (the uid of a Mozilla account, the part before the @ of the tokenserver's
-- email) that may start to sync
CREATE TABLE IF NOT EXISTS sync_allowed_accounts (
    uid VARCHAR(32) PRIMARY KEY,
    note VARCHAR(255) NOT NULL DEFAULT '',
    added_at BIGINT NOT NULL,
    added_by VARCHAR(255) NOT NULL
);

-- the accounts refused, the pending ones of the admin UI (rejected_at: rejected there)
CREATE TABLE IF NOT EXISTS sync_refused_accounts (
    uid VARCHAR(64) PRIMARY KEY,
    first_at BIGINT NOT NULL,
    last_at BIGINT NOT NULL,
    attempts INT NOT NULL DEFAULT 1,
    rejected_at BIGINT,
    rejected_by VARCHAR(255)
);

-- Before before_insert_user (SYNC_MAX_USERS: triggers fire in the order of their names): an
-- account not on the list is refused whether or not there is room. The row is skipped
-- (RETURN NULL, the later triggers do not run) rather than an error, so that its record in
-- sync_refused_accounts is kept; the tokenserver then finds no new row and answers with an
-- error. An email that has a row already is no new account (a keys change adds a row for
-- it, as do the accounts from before the allowlist): never refused here.
-- 'allowed_accounts' not 'on' (or no row): off, everyone gets in.
CREATE OR REPLACE FUNCTION ffs_check_allowed_account() RETURNS trigger AS $$
DECLARE
    account VARCHAR(255);
    now_ms BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM config WHERE config_key = 'allowed_accounts' AND config_value = 'on')
       AND NOT EXISTS (SELECT 1 FROM users WHERE email = NEW.email) THEN
        account := lower(split_part(NEW.email, '@', 1));
        IF NOT EXISTS (SELECT 1 FROM sync_allowed_accounts WHERE uid = account) THEN
            now_ms := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT;
            INSERT INTO sync_refused_accounts (uid, first_at, last_at, attempts)
            VALUES (left(account, 64), now_ms, now_ms, 1)
            ON CONFLICT (uid) DO UPDATE SET last_at = EXCLUDED.last_at, attempts = sync_refused_accounts.attempts + 1;
            RAISE WARNING 'Account % not on the allowlist (SYNC_ALLOWED_ACCOUNTS): refused', account;
            RETURN NULL;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS before_insert_allowed_user ON users;

CREATE TRIGGER before_insert_allowed_user
BEFORE INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION ffs_check_allowed_account();

-- What the admin UI changes, with the privileges of the owner of the tables (db_init.sh
-- gives its role EXECUTE, admin_grants.sql; nobody else has it): with
-- SYNC_ALLOWED_ACCOUNTS=admin or initial: allow an account (Approve, Allow a uid), remove it
-- from the list, reject a pending one
CREATE OR REPLACE FUNCTION ffs_allow_account(account TEXT, account_note TEXT, by_whom TEXT) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF account IS NULL OR lower(account) !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'an account id is 32 hexadecimal characters';
    END IF;
    INSERT INTO sync_allowed_accounts (uid, note, added_at, added_by)
    VALUES (lower(account), COALESCE(left(account_note, 255), ''), (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT, left(by_whom, 255))
    ON CONFLICT (uid) DO UPDATE SET note = EXCLUDED.note;
    DELETE FROM sync_refused_accounts WHERE uid = lower(account);
END;
$$;
REVOKE ALL ON FUNCTION ffs_allow_account(TEXT, TEXT, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ffs_remove_allowed_account(account TEXT) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    DELETE FROM sync_allowed_accounts WHERE uid = lower(account);
END;
$$;
REVOKE ALL ON FUNCTION ffs_remove_allowed_account(TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ffs_reject_account(account TEXT, by_whom TEXT) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE sync_refused_accounts
    SET rejected_at = (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT, rejected_by = left(by_whom, 255)
    WHERE uid = lower(account) AND rejected_at IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION ffs_reject_account(TEXT, TEXT) FROM PUBLIC;
