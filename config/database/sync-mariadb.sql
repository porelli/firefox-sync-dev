-- The Sync server on your MariaDB 10.10+ or MySQL 8.0/8.4 server (DATABASES.md).
-- Run as an administrator of the server. prepare_environment.sh fills in the placeholders
-- from .env and writes the result to database-setup.sql.
-- Two databases: the migrations of both keep their state in a table of the same name.
CREATE DATABASE IF NOT EXISTS `@TOKENSERVER_DATABASE@`;
CREATE DATABASE IF NOT EXISTS `@SYNCSTORAGE_DATABASE@`;
CREATE USER IF NOT EXISTS '@TOKENSERVER_USER@'@'%' IDENTIFIED BY '@TOKENSERVER_PASSWORD@';
CREATE USER IF NOT EXISTS '@SYNCSTORAGE_USER@'@'%' IDENTIFIED BY '@SYNCSTORAGE_PASSWORD@';
-- (again: a new password after prepare_environment.sh ran again)
ALTER USER '@TOKENSERVER_USER@'@'%' IDENTIFIED BY '@TOKENSERVER_PASSWORD@';
ALTER USER '@SYNCSTORAGE_USER@'@'%' IDENTIFIED BY '@SYNCSTORAGE_PASSWORD@';
-- tables (migrations; REFERENCES for their foreign keys on MySQL 8.0.22+), the init
-- container's config table, CheckUserLimit procedure and BeforeInsertUser trigger (MAX_USERS),
-- the admin UI's ffs_metrics, ffs_events and ffs_gauges tables
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
  CREATE ROUTINE, ALTER ROUTINE, EXECUTE, TRIGGER ON `@TOKENSERVER_DATABASE@`.* TO '@TOKENSERVER_USER@'@'%';
-- tables (migrations; one of them creates, calls and drops a procedure)
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
  CREATE ROUTINE, ALTER ROUTINE, EXECUTE ON `@SYNCSTORAGE_DATABASE@`.* TO '@SYNCSTORAGE_USER@'@'%';
