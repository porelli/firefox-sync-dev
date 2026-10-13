-- Self-hosted Mozilla accounts on your MySQL 8.0/8.4 server (DATABASES.md); MariaDB: fxa-mariadb.sql.
-- Run as an administrator of the server. prepare_environment.sh fills in the placeholders
-- from .env and writes the result to database-setup-fxa.sql.
-- The server needs (my.cnf, or the parameter group of a managed service):
--   mysql_native_password=ON           (8.4: FxA's driver supports nothing else)
--   log_bin_trust_function_creators=ON (the sign-up policy's function and trigger)
-- The database names are fixed: fxa, fxa_oauth, fxa_profile, pushbox and ffs.
-- (again: a new password after prepare_environment.sh ran again)
CREATE USER IF NOT EXISTS '@FXA_USER@'@'%' IDENTIFIED WITH mysql_native_password BY '@FXA_PASSWORD@';
ALTER USER '@FXA_USER@'@'%' IDENTIFIED WITH mysql_native_password BY '@FXA_PASSWORD@';
-- the migrations create these 4 databases and ~400 procedures; the accounts services use them
GRANT ALL PRIVILEGES ON `fxa`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `fxa_oauth`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `fxa_profile`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `pushbox`.* TO '@FXA_USER@'@'%';
-- the sign-up policy (fxa-policy): the database ffs, a trigger on fxa.accounts, views and
-- procedures reading and deleting tokens with its privileges (SELECT on fxa_profile and
-- pushbox: their sizes in the admin UI), and the column grants of the admin UI's user
CREATE USER IF NOT EXISTS '@FXA_POLICY_USER@'@'%' IDENTIFIED BY '@FXA_POLICY_PASSWORD@';
ALTER USER '@FXA_POLICY_USER@'@'%' IDENTIFIED BY '@FXA_POLICY_PASSWORD@';
GRANT ALL PRIVILEGES ON `ffs`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT, UPDATE, DELETE, TRIGGER ON `fxa`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT, DELETE ON `fxa_oauth`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT ON `fxa_profile`.* TO '@FXA_POLICY_USER@'@'%';
GRANT SELECT ON `pushbox`.* TO '@FXA_POLICY_USER@'@'%';
-- the admin UI's user, created here: CREATE USER would let the policy user change the
-- password of any account on the server. fxa-policy gives it column grants once the
-- tables exist
CREATE USER IF NOT EXISTS 'ffs_admin'@'%' IDENTIFIED BY '@FXA_ADMIN_PASSWORD@';
ALTER USER 'ffs_admin'@'%' IDENTIFIED BY '@FXA_ADMIN_PASSWORD@';
