-- The Sync server on your PostgreSQL 11+ server (DATABASES.md).
-- Run as a superuser (or a role with CREATEROLE and CREATEDB). prepare_environment.sh
-- fills in the placeholders from .env and writes the result to database-setup.sql.
CREATE ROLE @SYNC_POSTGRES_USER@ LOGIN PASSWORD '@SYNC_POSTGRES_PASSWORD@';
-- (again, when the role exists: a new password after prepare_environment.sh ran again)
ALTER ROLE @SYNC_POSTGRES_USER@ PASSWORD '@SYNC_POSTGRES_PASSWORD@';
-- CREATE DATABASE ... OWNER needs the role's membership, which a CREATEROLE role
-- does not get by itself on PostgreSQL 16+
GRANT @SYNC_POSTGRES_USER@ TO CURRENT_USER;
-- the owner creates the tables (migrations), the post_bso type, check_user_limit() and
-- its trigger (MAX_USERS), and gives the admin UI's role its grants on them. No superuser
-- needed.
-- An existing database: ALTER DATABASE @SYNC_POSTGRES_DATABASE@ OWNER TO @SYNC_POSTGRES_USER@;
CREATE DATABASE @SYNC_POSTGRES_DATABASE@ OWNER @SYNC_POSTGRES_USER@;
-- other roles of a shared server: no connections, no temporary tables
REVOKE ALL ON DATABASE @SYNC_POSTGRES_DATABASE@ FROM PUBLIC;
-- The admin UI: its own database (the event log, the audit trail, notes, metrics, backup
-- runs), owned by @ADMIN_USER@ and closed to the other roles, the one above too; and
-- @ADMIN_SYNC_USER@, which reads the Sync tables and has nothing on the admin UI's database
-- (the code the owner above can put in its database runs as it). The init container (as
-- the owner of the Sync tables) gives it SELECT on them, UPDATE of max users, DELETE of rows
-- of users and of what they store (DATABASES.md)
CREATE ROLE @ADMIN_USER@ LOGIN PASSWORD '@ADMIN_PASSWORD@';
CREATE ROLE @ADMIN_SYNC_USER@ LOGIN PASSWORD '@ADMIN_PASSWORD@';
ALTER ROLE @ADMIN_USER@ PASSWORD '@ADMIN_PASSWORD@';
ALTER ROLE @ADMIN_SYNC_USER@ PASSWORD '@ADMIN_PASSWORD@';
GRANT @ADMIN_USER@ TO CURRENT_USER;
-- a copy of template0, not template1: on PostgreSQL 11 to 14 every role may create tables
-- in template1, the Sync server's role too (ffs_* tables of its own, with triggers, would
-- be copied here). No connection until PUBLIC lost them, no CREATE for PUBLIC in its public
-- schema (PostgreSQL 11 to 14 give it; as a role with CREATEROLE and CREATEDB only that
-- REVOKE may warn there: run it as a superuser). The admin UI does not start when a table
-- there is not its role's
CREATE DATABASE @ADMIN_DATABASE@ OWNER @ADMIN_USER@ TEMPLATE template0 ALLOW_CONNECTIONS false;
REVOKE ALL ON DATABASE @ADMIN_DATABASE@ FROM PUBLIC;
ALTER DATABASE @ADMIN_DATABASE@ ALLOW_CONNECTIONS true;
\connect @ADMIN_DATABASE@
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
