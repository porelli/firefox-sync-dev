-- SYNC_ALLOWED_ACCOUNTS, invite-only Sync (docs/limits.md#sync_allowed_accounts): applied
-- by db_init.sh after db_init.sql, every start. db_init.sh appends the statements of the
-- setting (the list, on or off in the config table) and creates sync_refused_accounts
-- before this file runs.

-- the account ids (the uid of a Mozilla account, the part before the @ of the tokenserver's
-- email) that may start to sync
CREATE TABLE IF NOT EXISTS sync_allowed_accounts (
    uid VARCHAR(32) PRIMARY KEY,
    note VARCHAR(255) NOT NULL DEFAULT '',
    added_at BIGINT NOT NULL,
    added_by VARCHAR(255) NOT NULL
) DEFAULT CHARSET=utf8mb4;

-- Before BeforeInsertUser (SYNC_MAX_USERS): an account not on the list is refused whether
-- or not there is room, and recorded in sync_refused_accounts, where the admin UI shows it
-- as pending. That table is MyISAM where it can be (db_init.sh): its row stays when SIGNAL
-- undoes the INSERT into users.
-- An email that has a row already is no new account (a keys change adds a row for it, as
-- do the accounts from before the allowlist): never refused here.
-- 'allowed_accounts' not 'on' (or no row): off, everyone gets in.
DROP PROCEDURE IF EXISTS ffs_check_allowed_account;

DELIMITER //
CREATE PROCEDURE ffs_check_allowed_account(IN new_email VARCHAR(255))
BEGIN
    DECLARE account VARCHAR(255);
    DECLARE now_ms BIGINT;

    IF EXISTS (SELECT 1 FROM config WHERE config_key = 'allowed_accounts' AND config_value = 'on')
       AND NOT EXISTS (SELECT 1 FROM users WHERE email = new_email) THEN
        SET account = LOWER(SUBSTRING_INDEX(new_email, '@', 1));
        IF NOT EXISTS (SELECT 1 FROM sync_allowed_accounts WHERE uid = account) THEN
            SET now_ms = CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS SIGNED);
            INSERT INTO sync_refused_accounts (uid, first_at, last_at, attempts)
            VALUES (LEFT(account, 64), now_ms, now_ms, 1)
            ON DUPLICATE KEY UPDATE last_at = now_ms, attempts = attempts + 1;
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Account not on the allowlist (SYNC_ALLOWED_ACCOUNTS)';
        END IF;
    END IF;
END //
DELIMITER ;

DROP TRIGGER IF EXISTS BeforeInsertAllowedUser;

DELIMITER //
CREATE TRIGGER BeforeInsertAllowedUser
BEFORE INSERT ON users
FOR EACH ROW PRECEDES BeforeInsertUser
BEGIN
    CALL ffs_check_allowed_account(NEW.email);
END //
DELIMITER ;

-- What the admin UI changes, with the privileges of this user (its own has SELECT and
-- EXECUTE here, see db/mysql/admin-user.sh): with SYNC_ALLOWED_ACCOUNTS=admin or initial:
-- allow an account (Approve, Allow a uid), remove it from the list, reject a pending one
DROP PROCEDURE IF EXISTS ffs_allow_account;

DELIMITER //
CREATE PROCEDURE ffs_allow_account(IN account VARCHAR(64), IN account_note VARCHAR(255), IN by_whom VARCHAR(255))
BEGIN
    IF account IS NULL OR LOWER(account) NOT REGEXP '^[0-9a-f]{32}$' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'an account id is 32 hexadecimal characters';
    END IF;
    INSERT INTO sync_allowed_accounts (uid, note, added_at, added_by)
    VALUES (LOWER(account), COALESCE(account_note, ''), CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS SIGNED), by_whom)
    ON DUPLICATE KEY UPDATE note = VALUES(note);
    DELETE FROM sync_refused_accounts WHERE uid = LOWER(account);
END //
DELIMITER ;

DROP PROCEDURE IF EXISTS ffs_remove_allowed_account;

DELIMITER //
CREATE PROCEDURE ffs_remove_allowed_account(IN account VARCHAR(64))
BEGIN
    DELETE FROM sync_allowed_accounts WHERE uid = LOWER(account);
END //
DELIMITER ;

DROP PROCEDURE IF EXISTS ffs_reject_account;

DELIMITER //
CREATE PROCEDURE ffs_reject_account(IN account VARCHAR(64), IN by_whom VARCHAR(255))
BEGIN
    UPDATE sync_refused_accounts
    SET rejected_at = CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS SIGNED), rejected_by = by_whom
    WHERE uid = LOWER(account) AND rejected_at IS NULL;
END //
DELIMITER ;
