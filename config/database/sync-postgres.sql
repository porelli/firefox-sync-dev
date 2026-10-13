-- The Sync server on your PostgreSQL 11+ server (DATABASES.md).
-- Run as a superuser (or a role with CREATEROLE and CREATEDB). prepare_environment.sh
-- fills in the placeholders from .env and writes the result to database-setup.sql.
CREATE ROLE @POSTGRES_USER@ LOGIN PASSWORD '@POSTGRES_PASSWORD@';
-- (again, when the role exists: a new password after prepare_environment.sh ran again)
ALTER ROLE @POSTGRES_USER@ PASSWORD '@POSTGRES_PASSWORD@';
-- CREATE DATABASE ... OWNER needs the role's membership, which a CREATEROLE role
-- does not get by itself on PostgreSQL 16+
GRANT @POSTGRES_USER@ TO CURRENT_USER;
-- the owner creates the tables (migrations), the post_bso type, check_user_limit() and
-- its trigger (MAX_USERS), the admin UI's tables. No superuser needed.
-- An existing database: ALTER DATABASE @POSTGRES_DATABASE@ OWNER TO @POSTGRES_USER@;
CREATE DATABASE @POSTGRES_DATABASE@ OWNER @POSTGRES_USER@;
-- other roles of a shared server: no connections, no temporary tables
REVOKE ALL ON DATABASE @POSTGRES_DATABASE@ FROM PUBLIC;
