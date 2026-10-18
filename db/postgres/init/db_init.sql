-- Applied after syncstorage-rs has run its migrations.
-- The sync-1.5 service and the node for @DOMAIN@ are created by syncstorage-rs
-- itself (tokenserver migrations and SYNC_TOKENSERVER__INIT_NODE_URL).

-- Create configuration table if it doesn't exist
CREATE TABLE IF NOT EXISTS config (
    config_key VARCHAR(255) PRIMARY KEY,
    config_value VARCHAR(255) NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Keep a single sync node. If SYNCSTORAGE_DOMAIN changed, syncstorage-rs added a
-- node for the new domain but the old one is still in rotation and its users still
-- point to it: move them to the current node and take the old nodes out
UPDATE nodes n
SET downed = 0, available = n.capacity
FROM services s
WHERE s.service = 'sync-1.5' AND n.service = s.id
  AND n.node = '@DOMAIN@' AND n.downed = 1;

UPDATE users u
SET nodeid = n.id
FROM services s, nodes n
WHERE s.service = 'sync-1.5' AND u.service = s.id
  AND n.service = s.id AND n.node = '@DOMAIN@'
  AND u.nodeid <> n.id;

UPDATE nodes n
SET available = 0, downed = 1
FROM services s
WHERE s.service = 'sync-1.5' AND n.service = s.id
  AND n.node <> '@DOMAIN@';

-- MAX_USERS (validated by db_init.sh): N or fixed:N sets the limit on every start
-- (the flag below is TRUE), initial:N only when there is none yet (first start,
-- FALSE: nothing to do on conflict), then it is managed in the admin UI and kept.
INSERT INTO config (config_key, config_value)
VALUES ('max_users', '@MAX_USERS@')
ON CONFLICT (config_key) DO UPDATE
SET config_value = EXCLUDED.config_value, updated_at = CURRENT_TIMESTAMP
WHERE @MAX_USERS_FIXED@ AND config.config_value IS DISTINCT FROM EXCLUDED.config_value;

-- written by older versions, no longer used
DELETE FROM config WHERE config_key = 'max_users_env';

-- Create user limit function (idempotent)
-- syncstorage-rs inserts a new row for an existing account when its keys
-- change (e.g. password reset), so count accounts (emails), not rows, and
-- never block an account that is already registered.
CREATE OR REPLACE FUNCTION check_user_limit() RETURNS trigger AS $$
DECLARE
    user_count INT;
    max_users_value VARCHAR(255);
    max_users_setting INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE email = NEW.email) THEN
        -- Get max_users from config table, locking the row so concurrent
        -- sign-ups are counted one at a time; a missing value denies
        SELECT config_value INTO max_users_value
        FROM config
        WHERE config_key = 'max_users'
        FOR UPDATE;

        -- 'unlimited' (MAX_USERS=unlimited): no limit, nothing to count
        IF max_users_value IS DISTINCT FROM 'unlimited' THEN
            -- a number (db_init.sh and the admin UI write nothing else); anything else denies
            max_users_setting := CASE WHEN max_users_value ~ '^[0-9]{1,10}$'
                THEN LEAST(CAST(max_users_value AS BIGINT), 2147483647) ELSE 0 END;

            -- Get current account count
            SELECT COUNT(DISTINCT email) INTO user_count FROM users;

            -- Check if limit is exceeded
            IF user_count >= max_users_setting THEN
                RAISE EXCEPTION 'User limit exceeded';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger (idempotent)
DROP TRIGGER IF EXISTS before_insert_user ON users;

CREATE TRIGGER before_insert_user
BEFORE INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION check_user_limit();

-- The admin UI's tables of before ADMIN_DB_PASSWORD, once it moved them into its own
-- database: it calls this, with the privileges of the owner of the tables (db_init.sh
-- gives its role EXECUTE, nobody else has it)
CREATE OR REPLACE FUNCTION ffs_drop_admin_tables() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    DROP TABLE IF EXISTS ffs_events, ffs_metrics, ffs_gauges, ffs_account_notes,
        ffs_schema_levels, ffs_jobs, ffs_backups;
END;
$$;
REVOKE ALL ON FUNCTION ffs_drop_admin_tables() FROM PUBLIC;
