# Your own database server

By default the stack starts its own databases: two MariaDB containers ([docker-compose.yml](/docker-compose.yml), or [MySQL 8.4](#mariadb-or-mysql-containers)), one PostgreSQL container ([docker-compose.sync-postgres.yml](/docker-compose.sync-postgres.yml)), and with [self-hosted accounts](FXA.md) one MySQL (or [MariaDB](FXA.md#mysql-or-mariadb)) container (`fxa-db`); the [Helm chart](HELM.md) the same servers as StatefulSets. You can use a MariaDB, MySQL or PostgreSQL server you already run instead.

What changes:
- `SYNC_DB_CONTAINERS=0` (and `FXA_DB_CONTAINERS=0` for the accounts) in `.env`: those containers are not started, everything else is the same. With the Helm chart `database.bundled: false`, see [Kubernetes](#kubernetes).
- You create the databases and users once, with the SQL below. The stack never needs an administrator account on your server.
- The migrations and the init container still run at every start, as the users below: the tables, the max users trigger and the sign-up policy are created and updated by the stack.
- The admin UI has a database and two users of its own there too (the database `ffs_admin`, `ADMIN_DB_NAME`; the users `ffs_admin_ui`, `ADMIN_DB_USER`, for it, and `ffs_admin_sync`, `ADMIN_DB_SYNC_USER`, for the Sync data), which the Sync server's users cannot reach: see [The admin UI's own database](#the-admin-uis-own-database). With self-hosted accounts the admin UI also has a user on the accounts' server named `ffs_admin` too (`FXA_ADMIN_DB_PASSWORD`, [below](#databases-and-users)): a user, not that database, and with one server for both they live side by side without a grant on each other.
- Backups are yours: the stack's volumes are not used, and the backup service (`COMPOSE_PROFILES=backup`) is for the database containers (the Helm chart's backups run on your server too, as its users). Your backup job can record its runs for the admin UI, which then shows the last one and alerts when it fails or gets old: see [ADMIN.md](ADMIN.md#your-own-database-servers).

## MariaDB or MySQL containers

This section is about the database containers of the stack, not your own server. The two Sync databases (`syncstorage_db`, `tokenserver_db`) run on MariaDB (`mariadb:lts`) by default. With `SYNC_DB=mysql` they run on MySQL 8.4 instead, which is what upstream syncstorage-rs is developed and tested on. On MariaDB upstream's tokenserver test `test_user_creation` failed because MariaDB orders the nodes differently: our images have the fix proposed upstream ([mozilla-services/syncstorage-rs#2638](https://github.com/mozilla-services/syncstorage-rs/pull/2638), see [upstream-patches.yml](/upstream-patches.yml)), and `tests/e2e.sh` skips that test only for images without it (their label `org.firefox-sync.upstream-patches` does not list it). The images (`syncstorage-rs-mysql`, `syncstorage-rs-mysql-init`) and the `MARIADB_*` settings of `.env` stay the same.

- `prepare_environment.sh`: answer `mysql` to the database backend question. It writes `SYNC_DB=mysql` and `SYNC_DB_TLS_VERIFY=false`, and adds [docker-compose.sync-mysql.yml](/docker-compose.sync-mysql.yml) to `COMPOSE_FILE`. With Quadlets the units of [config/quadlet/sync-mysql/](/config/quadlet/sync-mysql) replace the two MariaDB units.
- By hand: `SYNC_DB=mysql` in `.env` and `COMPOSE_FILE=docker-compose.yml:docker-compose.sync-mysql.yml` (with the accounts `docker-compose.yml:docker-compose.sync-mysql.yml:docker-compose.fxa.yml`; with the Podman socket `-f docker-compose.yml -f docker-compose.podman.yml -f docker-compose.sync-mysql.yml`).
- Choose it before the first start. MySQL gets its own volumes (`syncstorage-db-mysql` and `tokenserver-db-mysql`, Quadlets: `firefox-sync-syncstorage-db-mysql` and `firefox-sync-tokenserver-db-mysql`), so it never opens MariaDB's data files. If you switch an existing install, MariaDB's data stays in its volumes and Sync starts with empty databases. Moving the data takes a dump and a reload, which is not tested here. Also, MariaDB's dumps use its `uca1400` collations, which MySQL rejects (see [Moving an existing install](#moving-an-existing-install)). Going back to MariaDB finds MariaDB's volumes as you left them.
- No binary logging (`--disable-log-bin`), the same as the MariaDB containers. No replica reads the log, and MySQL would keep 30 days of every change (`binlog_expire_logs_seconds`). With binary logging on, the init container could only create the max users procedure and trigger with `log_bin_trust_function_creators=ON` (`ERROR 1419`). If you want binary logs (a replica, point-in-time recovery), replace `--disable-log-bin` with `--log-bin-trust-function-creators=ON` in the `command` (Quadlets: `Exec=`). That combination is what the `EXTERNAL_DB=1` tests run.
- The users use MySQL 8.4's default `caching_sha2_password`, with no `mysql_native_password`. The Sync server and the admin UI connect without TLS, the same as with your own MySQL server. The init container's MariaDB client connects over TLS without checking MySQL's self-signed certificate, on the stack's own network (`SYNC_DB_TLS_VERIFY=false`, which `docker-compose.sync-mysql.yml` sets for compose; without it the init fails with `ERROR 2026`).
- `mysql:8.4` is the current MySQL LTS release.
- The Helm chart: `database.backend: mysql`, the same server (`database.image.mysql`), without binary logging, its certificate not checked. On kind or k3s on an Ubuntu host with `mysql-server`, see [HELM.md](HELM.md#troubleshooting) (AppArmor).

## Another PostgreSQL major

The `postgres_db` and `backup` services use `SYNC_POSTGRES_IMAGE` (`.env`): `postgres:18` for the new installs `prepare_environment.sh` sets up, also when it is not set, as the installs from before it. `./prepare_environment.sh --upgrade`, or running `prepare_environment.sh` again on the install, writes `SYNC_POSTGRES_IMAGE=postgres:18` for them, which pins the PostgreSQL major of each install. The official PostgreSQL image keeps its data at `/var/lib/postgresql/<major>/docker` and refuses to start when an older major's data is there: moving to a newer major needs a dump and restore ([ADMIN.md#restoring](ADMIN.md#restoring)) or `pg_upgrade` (not automated here), and the image fails loudly when neither was done — so no guard is needed, unlike MariaDB where the server silently upgrades the data.

The Helm chart has the same as `database.image.postgres` (and `database.image.mariadb`, `database.image.mysql`), `docker.io/library/postgres:18` by default ([HELM.md](HELM.md#upgrades)).

With your own database server (`EXTERNAL_DB=1`): `SYNC_POSTGRES_IMAGE` picks the backup client image (`postgres:18` by default): set it to your server's major, since `pg_dump` must be at least the server's major.

## Supported servers

| Component | Supported | Tested |
|---|---|---|
| Sync server | MariaDB 10.10+, MySQL 8.0 and 8.4, PostgreSQL 11+ | MariaDB 12.3, MySQL 8.4, PostgreSQL 18 |
| Accounts | MySQL 8.0 and 8.4, MariaDB 11.4 and later (12: with our accounts images) | MySQL 8.4, MariaDB 12 and 11.8 (and 11.4 once) |

Mozilla supports MySQL only for the accounts; MariaDB passes the same tests here (`FXA_DB=mariadb`, see [MySQL or MariaDB](FXA.md#mysql-or-mariadb)). On MariaDB 12 and later the accounts need our accounts images: Mozilla's migrations drop foreign keys by MySQL's names, which MariaDB 12 no longer gives them (`ER_CANT_DROP_FIELD_OR_KEY: Can't DROP FOREIGN KEY deviceCommands_ibfk_1`), and our images have the fix proposed upstream ([MariaDB 12](FXA.md#mariadb-12)). With Mozilla's own images, MariaDB 11.4 to 11.8. The `fxa-db` container of the stack runs `FXA_MARIADB_IMAGE`: `mariadb:12.3` for the new installs `prepare_environment.sh` sets up, `mariadb:11.8` when it is not set, as the installs from before it ([MySQL or MariaDB](FXA.md#mysql-or-mariadb)). MySQL 9 does not work either: it has no `mysql_native_password`, the only one the accounts' driver supports.

## Server requirements

- **Reachable from the containers.** `localhost` and `127.0.0.1` are the container itself, not your host. Use a host name or an IPv4 address: an IPv6 address would need `[ ]` in the database URLs, which `prepare_environment.sh` refuses.
    - A server on the Docker host: use the address of the Docker bridge (often `172.17.0.1`, see `ip addr show docker0`) and make the server listen there. The containers connect from the stack's own network, whose subnet compose picks from `172.16.0.0/12` or `192.168.0.0/16`: check it with `docker network inspect <project>_default` (the project is the directory name, e.g. `firefox-sync_default`) and allow it in the server's firewall and user hosts.
    - With Podman (Quadlets or the socket): `host.containers.internal`. It is the host's main address (`podman run --rm docker.io/library/busybox cat /etc/hosts` shows it), not `127.0.0.1`: a server that listens on `127.0.0.1` only (the usual default) cannot be reached that way. Make it listen on that address, and allow connections from that address in its users' host part and its firewall: the containers connect from it.
    - A server elsewhere: its host name or address.
    - Kubernetes (the Helm chart): a host name or IPv4 address the pods resolve and reach (a Service of type `ExternalName` works too). They connect from the pod network, or from the nodes' addresses when the cluster masquerades traffic leaving it: allow those in the firewall and the users' host part.
- **Plain connections, on a trusted network only.** The Sync server cannot use TLS to its database (its MySQL driver is built without TLS, its PostgreSQL driver connects without it), and neither can the accounts' driver. So the server must accept connections without TLS from these users: `host` lines (not `hostssl`) in PostgreSQL's `pg_hba.conf` (per user, so the other applications can keep `hostssl`), `require_secure_transport=OFF` on MySQL and MariaDB. That one is server-wide: on a server that enforces TLS for other applications, turning it off lets all of them connect without it. Either give those applications' accounts `REQUIRE SSL` (`ALTER USER 'app'@'%' REQUIRE SSL;`, per account) before turning it off, or leave it on and use a server or instance of its own for this stack. Keep the database on the same host, or on a private network or VPN you trust.
- **MariaDB and MySQL with binary logging** (the default on MySQL 8, `log_bin` on MariaDB): set `log_bin_trust_function_creators=ON`, otherwise the users below cannot create the max users trigger and the sign-up policy's function and trigger (`ERROR 1419`). On MySQL `SET PERSIST log_bin_trust_function_creators = ON;`, on MariaDB `SET GLOBAL log_bin_trust_function_creators = 1;` and the same in `my.cnf`. On managed services (RDS, Cloud SQL...) set it in the parameter group. Granting `SUPER` instead works too, but is not recommended.
- **MariaDB and MySQL:** `explicit_defaults_for_timestamp=ON`, the default since MySQL 8.0 and MariaDB 10.10.
- **The accounts on MySQL 8.4:** start it with `mysql_native_password=ON` (`--mysql-native-password=ON` or in `my.cnf`). On 8.0 it is on by default. MariaDB needs nothing: `db/mysql/fxa-mariadb.sql` creates the user with `mysql_native_password` explicitly.
- **PostgreSQL:** a `host` line for the containers' addresses with `scram-sha-256`, e.g. `host syncserver syncserver 172.16.0.0/12 scram-sha-256`.

## Databases and users

The SQL is in [db/mysql/](/db/mysql) (MariaDB and MySQL) and [db/postgres/](/db/postgres), with `@NAME@` placeholders. When you answer `y` to "Use an existing database server instead of starting one?" (or to the same question for the accounts), `prepare_environment.sh` fills them in with the names and the generated passwords of `.env` and writes `database-setup.sql` (and `database-setup-fxa.sql` for the accounts), readable by you only. Run it as an administrator of your server, then delete it:

```bash
mysql -h db.example.com -u root -p < database-setup.sql          # MySQL
mariadb -h db.example.com -u root -p < database-setup.sql        # MariaDB (its client may not install a mysql command)
psql -h db.example.com -U postgres -f database-setup.sql         # PostgreSQL
mysql -h db.example.com -u root -p < database-setup-fxa.sql      # the accounts, MySQL 8
mariadb -h db.example.com -u root -p < database-setup-fxa.sql    # the accounts, MariaDB 11.4 and later
```

Use only `A-Z a-z 0-9 . _ ~ -` in passwords (the generated ones are letters and digits): they are part of the database URLs. The Sync users need one: the init container refuses an empty password (or a `<REPLACE_WITH_...>` placeholder) for the tokenserver user, the PostgreSQL user and the Sync server's PostgreSQL role, so a passwordless login (`trust` in `pg_hba.conf`, a MariaDB user without a password), which used to work, now keeps the Sync server down: give the users a password. Names are `a-z`, `0-9` and `_`.

The users connect from `'%'`, any address: the passwords are the only check. Replace `'%'` in the file with your containers' network (e.g. `'172.16.0.0/255.240.0.0'`, see [Server requirements](#server-requirements)) before you run it, in every line.

Running `prepare_environment.sh` again makes new passwords, and new secrets for everything else (`SYNC_MASTER_SECRET`, the accounts' keys...). The SQL sets the passwords of users that already exist again, so a new setup matches its new `.env`. For an install that already runs, don't: keep its `.env` (see [Moving an existing install](#moving-an-existing-install)).

### Sync on MariaDB or MySQL: [db/mysql/sync.sql](/db/mysql/sync.sql)

```sql
CREATE DATABASE IF NOT EXISTS `@SYNC_TOKENSERVER_DATABASE@`;
CREATE DATABASE IF NOT EXISTS `@SYNC_STORAGE_DATABASE@`;
CREATE USER IF NOT EXISTS '@SYNC_TOKENSERVER_USER@'@'%' IDENTIFIED BY '@SYNC_TOKENSERVER_PASSWORD@';
CREATE USER IF NOT EXISTS '@SYNC_STORAGE_USER@'@'%' IDENTIFIED BY '@SYNC_STORAGE_PASSWORD@';
ALTER USER '@SYNC_TOKENSERVER_USER@'@'%' IDENTIFIED BY '@SYNC_TOKENSERVER_PASSWORD@';
ALTER USER '@SYNC_STORAGE_USER@'@'%' IDENTIFIED BY '@SYNC_STORAGE_PASSWORD@';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
  CREATE ROUTINE, ALTER ROUTINE, EXECUTE, TRIGGER ON `@SYNC_TOKENSERVER_DATABASE@`.* TO '@SYNC_TOKENSERVER_USER@'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
  CREATE ROUTINE, ALTER ROUTINE, EXECUTE ON `@SYNC_STORAGE_DATABASE@`.* TO '@SYNC_STORAGE_USER@'@'%';
CREATE DATABASE IF NOT EXISTS `@ADMIN_DATABASE@`;
CREATE USER IF NOT EXISTS '@ADMIN_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
CREATE USER IF NOT EXISTS '@ADMIN_SYNC_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
ALTER USER '@ADMIN_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
ALTER USER '@ADMIN_SYNC_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, LOCK TABLES ON `@ADMIN_DATABASE@`.* TO '@ADMIN_USER@'@'%';
GRANT SELECT, EXECUTE ON `@SYNC_TOKENSERVER_DATABASE@`.* TO '@ADMIN_SYNC_USER@'@'%';
GRANT SELECT, DELETE ON `@SYNC_STORAGE_DATABASE@`.* TO '@ADMIN_SYNC_USER@'@'%';
```

- The tokenserver user creates the tables (the migrations), the init container's `config` table, the `CheckUserLimit` procedure and the `BeforeInsertUser` trigger that enforce `SYNC_MAX_USERS` (a number in `config`, or `unlimited`: no check), and the three procedures the admin UI calls (`ffs_set_max_users`, `ffs_delete_user_row`, `ffs_drop_admin_tables`).
- The storage user creates the tables (the migrations; one of them creates, calls and drops a procedure).
- The admin UI's users: `ADMIN_DB_USER` (`ffs_admin_ui`) has its own database (`ADMIN_DB_NAME`, `ffs_admin`: the event log, the audit trail, notes, metrics, backup runs) and nothing else; `ADMIN_DB_SYNC_USER` (`ffs_admin_sync`) reads the Sync databases, changes them only as [below](#the-admin-uis-own-database), and has nothing on `ffs_admin`. The two users above cannot reach `ffs_admin`.
- With the storage on another server, run there the three statements of `ffs_admin_sync` commented at the end of the file (its `CREATE USER`, `ALTER USER` and the storage `GRANT`), and leave out the storage `GRANT` above on the tokenserver's server. `ffs_admin_ui` and `ffs_admin` are on the tokenserver's server only.
- `REFERENCES` is needed on MySQL 8.0.22+ for the tokenserver's foreign keys.
- Two databases, not one: both migrations keep their state in a table with the same name.

### Sync on PostgreSQL: [db/postgres/sync.sql](/db/postgres/sync.sql)

```sql
CREATE ROLE @SYNC_POSTGRES_USER@ LOGIN PASSWORD '@SYNC_POSTGRES_PASSWORD@';
ALTER ROLE @SYNC_POSTGRES_USER@ PASSWORD '@SYNC_POSTGRES_PASSWORD@';
GRANT @SYNC_POSTGRES_USER@ TO CURRENT_USER;
CREATE DATABASE @SYNC_POSTGRES_DATABASE@ OWNER @SYNC_POSTGRES_USER@;
REVOKE ALL ON DATABASE @SYNC_POSTGRES_DATABASE@ FROM PUBLIC;
CREATE ROLE @ADMIN_USER@ LOGIN PASSWORD '@ADMIN_PASSWORD@';
CREATE ROLE @ADMIN_SYNC_USER@ LOGIN PASSWORD '@ADMIN_PASSWORD@';
ALTER ROLE @ADMIN_USER@ PASSWORD '@ADMIN_PASSWORD@';
ALTER ROLE @ADMIN_SYNC_USER@ PASSWORD '@ADMIN_PASSWORD@';
GRANT @ADMIN_USER@ TO CURRENT_USER;
CREATE DATABASE @ADMIN_DATABASE@ OWNER @ADMIN_USER@;
REVOKE ALL ON DATABASE @ADMIN_DATABASE@ FROM PUBLIC;
```

- The owner of the database creates the tables, the `post_bso` type, the `check_user_limit()` function and its trigger, and the `ffs_drop_admin_tables()` function, and gives the admin UI's reader (`ffs_admin_sync`) its grants on them at every start. It needs no superuser, `CREATEDB` or `CREATEROLE`. Leave `SYNC_POSTGRES_APP_USER` empty: that is for the stack's container, where `SYNC_POSTGRES_USER` is a superuser.
- The admin UI's role `ffs_admin_ui` owns its own database (`ffs_admin`), closed to the other roles, the Sync server's and `ffs_admin_sync` too; `ffs_admin_sync` has nothing there. It is a copy of `template0`, not of `template1`, where on PostgreSQL 11 to 14 every role may create tables (the Sync server's role could leave `ffs_*` tables with triggers there, to be copied), and its `public` schema gives `PUBLIC` no `CREATE`. The admin UI does not start when something there (a table, function, operator, type or schema) is not `ffs_admin_ui`'s, and its setup check says what.
- Run it as a superuser, or as a role with `CREATEROLE` and `CREATEDB` (what managed services such as RDS or Cloud SQL give you, tested): the `GRANT` lets that role create a database owned by the new one, which PostgreSQL 16+ requires.
- Run again, `CREATE ROLE` and `CREATE DATABASE` fail with "already exists" and `psql -f` goes on: the `ALTER ROLE` sets the new password.
- The `REVOKE` keeps the other roles of a shared server out (no connections, no temporary tables).
- For a database that already exists: `ALTER DATABASE syncserver OWNER TO syncserver;`.
- PostgreSQL 11 to 14 let every role create objects in the `public` schema of every database. Close it in the new database, as a superuser: `psql -h db.example.com -U postgres -d syncserver -c 'REVOKE CREATE ON SCHEMA public FROM PUBLIC; ALTER SCHEMA public OWNER TO syncserver;'` (since PostgreSQL 15 that is the default, and the database owner owns `public`).

### The accounts on MySQL 8 or MariaDB 11: [db/mysql/fxa-mysql.sql](/db/mysql/fxa-mysql.sql), [db/mysql/fxa-mariadb.sql](/db/mysql/fxa-mariadb.sql)

`prepare_environment.sh` asks whether your server is MySQL or MariaDB and sets `FXA_DB`, which picks the file. They differ in the first two lines only. On MariaDB:

```sql
CREATE USER IF NOT EXISTS '@FXA_USER@'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('@FXA_PASSWORD@');
ALTER USER '@FXA_USER@'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('@FXA_PASSWORD@');
```

On MySQL, and the rest of both:

```sql
CREATE USER IF NOT EXISTS '@FXA_USER@'@'%' IDENTIFIED WITH mysql_native_password BY '@FXA_PASSWORD@';
ALTER USER '@FXA_USER@'@'%' IDENTIFIED WITH mysql_native_password BY '@FXA_PASSWORD@';
GRANT ALL PRIVILEGES ON `fxa`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `fxa_oauth`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `fxa_profile`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `pushbox`.* TO '@FXA_USER@'@'%';
CREATE USER IF NOT EXISTS '@FXA_POLICY_USER@'@'%' IDENTIFIED BY '@FXA_POLICY_PASSWORD@';
ALTER USER '@FXA_POLICY_USER@'@'%' IDENTIFIED BY '@FXA_POLICY_PASSWORD@';
GRANT ALL PRIVILEGES ON `ffs`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT, UPDATE, DELETE, TRIGGER, EXECUTE ON `fxa`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT, DELETE ON `fxa_oauth`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT, DELETE ON `fxa_profile`.* TO '@FXA_POLICY_USER@'@'%';
GRANT SELECT, DELETE ON `pushbox`.* TO '@FXA_POLICY_USER@'@'%';
CREATE USER IF NOT EXISTS 'ffs_admin'@'%' IDENTIFIED BY '@FXA_ADMIN_PASSWORD@';
ALTER USER 'ffs_admin'@'%' IDENTIFIED BY '@FXA_ADMIN_PASSWORD@';
```

- `FXA_MYSQL_USER` (`fxa`): Mozilla's migrations create the four databases, their tables and about 400 procedures, and the accounts services use them. It must use `mysql_native_password`.
- `FXA_MYSQL_POLICY_USER` (`ffs_policy`): `fxa-policy` installs the [sign-up policy](ADMIN.md#who-can-sign-up-self-hosted-accounts) at every start: the database `ffs` (with the sign-up settings and `FXA_MAX_ACCOUNTS` in `ffs.settings`), a trigger on `fxa.accounts` that checks both through `ffs.signup_refusal`, views and procedures that read the security history, read and delete tokens, disable and delete accounts, turn off two-step authentication, remove recovery keys, confirm emails and prune expired tokens with its privileges (they call Mozilla's own procedures, hence `EXECUTE` on `fxa`), and the grants of the admin UI's user (hence `WITH GRANT OPTION`): `SELECT` on a few columns of `fxa.accounts` and on the views (which leave out every secret), `EXECUTE` on those procedures, nothing that changes the accounts' tables directly. `SELECT` on `fxa_profile` and `pushbox` lets the admin UI show the size of all five databases, `DELETE` there removes the profile and the push messages of a deleted account. When a procedure it calls is missing (a newer FxA release, or no `EXECUTE`), `fxa-policy` logs a warning naming it and the accounts keep working, but what needs it in the admin UI answers with an error (ADMIN.md, Disabling an account).
- Upgrading from a version whose script had no `EXECUTE` in the policy user's grant on `fxa`: run ``GRANT EXECUTE ON `fxa`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;`` once, then restart `fxa-policy`.
- Upgrading from a version whose script had only `SELECT` on `fxa_profile` and `pushbox`: run ``GRANT DELETE ON `fxa_profile`.* TO '@FXA_POLICY_USER@'@'%'; GRANT DELETE ON `pushbox`.* TO '@FXA_POLICY_USER@'@'%';`` once, otherwise deleting an account in the admin UI fails (and changes nothing).
- `ffs_admin`, with `FXA_ADMIN_DB_PASSWORD`: the admin UI's user of the accounts database, created here and not by `fxa-policy`. Not the admin UI's own database of the same name (`ADMIN_DB_NAME`, in `database-setup.sql`, which only `ADMIN_DB_USER`, `ffs_admin_ui`, reaches): on one server for Sync and the accounts both are there, this user has no grant on that database. `CREATE USER` is a server-wide privilege that also lets its holder change the password of every other account (on MariaDB including `root`), so the policy user does not get it. `fxa-policy` finds `ffs_admin` there and only gives it its grants.
- The grants are on whole databases because the tables don't exist yet when you run this.
- The database names are fixed (`fxa`, `fxa_oauth`, `fxa_profile`, `pushbox`, `ffs`): a server or instance of its own for the accounts is best.
- One user for both is possible (tested): leave `FXA_MYSQL_POLICY_USER` empty (`FXA_MYSQL_POLICY_PASSWORD` is then not used, `fxa-policy` connects with `FXA_MYSQL_PASSWORD`). In `database-setup-fxa.sql`, delete the policy user's `CREATE USER` and `ALTER USER` lines and put the name of `FXA_MYSQL_USER` in its `GRANT`s. The accounts services, which face the internet, then also hold `GRANT OPTION` on `fxa`, `fxa_oauth` and `ffs`: they could pass their access to the accounts on to any other user of the server.

## Settings

All in `.env`. `prepare_environment.sh` writes them when you answer `y`. The Helm chart's values: [Kubernetes](#kubernetes).

| Setting | Default | Your own server |
|---|---|---|
| `SYNC_DB_CONTAINERS` | `1` | `0`: no `syncstorage_db`, `tokenserver_db` or `postgres_db` container |
| `SYNC_DB` | `mariadb` | not used: it picks the database containers, `mysql` for [MySQL 8.4](#mariadb-or-mysql-containers) |
| `SYNC_DB_TLS_VERIFY` | `true` | `false`: the init container's client checks the server's certificate, and MySQL's own is self-signed (the Sync server itself does not use TLS) |
| `SYNC_TOKENSERVER_DB_HOST`, `_PORT`, `_NAME`, `_USER`, `_PASSWORD` | `tokenserver_db`, `3306`, `tokenserver`, `tokenserver` | your server and the names of the SQL above |
| `SYNC_STORAGE_DB_HOST`, `_PORT`, `_NAME`, `_USER`, `_PASSWORD` | `syncstorage_db`, `3306`, `syncstorage`, `syncstorage` | the same server, or another one |
| `SYNC_POSTGRES_HOST`, `_PORT`, `_NAME`, `_USER`, `_PASSWORD` | `postgres_db`, `5432`, `syncserver`, `syncserver` | your server, with PostgreSQL |
| `FXA_DB_CONTAINERS` | `1` | `0`: no `fxa-db` container |
| `FXA_DB` | `mysql` | `mariadb` with a MariaDB server: the SQL above and the client in the instructions |
| `FXA_MYSQL_HOST`, `FXA_MYSQL_PORT` | `fxa-db`, `3306` | your MySQL 8 or MariaDB 11 server |
| `FXA_MYSQL_USER`, `FXA_MYSQL_PASSWORD` | `root` | `fxa` and its password |
| `FXA_MYSQL_POLICY_USER`, `FXA_MYSQL_POLICY_PASSWORD` | empty: `FXA_MYSQL_USER` and `FXA_MYSQL_PASSWORD` | `ffs_policy` and its password |
| `FXA_ADMIN_DB_PASSWORD` | generated | the password of the user `ffs_admin` of the accounts (the admin UI reads them as it) in `database-setup-fxa.sql` |
| `ADMIN_DB_NAME`, `ADMIN_DB_USER`, `ADMIN_DB_SYNC_USER` | `ffs_admin`, `ffs_admin_ui`, `ffs_admin_sync` | the admin UI's own database (not the accounts' user `ffs_admin`), its user, and its reader of the Sync data, in `database-setup.sql` |
| `ADMIN_DB_PASSWORD` | generated | the password of both (empty: an install from before it, see below) |
| `SYNC_POSTGRES_APP_USER`, `SYNC_POSTGRES_APP_PASSWORD` | `syncserver_app` and generated with the PostgreSQL container | empty: on your server `SYNC_POSTGRES_USER` is the owner, no superuser |

## The admin UI's own database

The [admin UI](ADMIN.md) keeps the event log, the audit trail (who did what, on which account), the notes, its metrics, the schema levels seen, its daily jobs and the backup runs in a database of its own, `ADMIN_DB_NAME` (`ffs_admin`), on the tokenserver's server (with PostgreSQL the same server). The Sync server's users have no grant on it: a Sync server that is broken into can change what it stores, but cannot read the audit trail or rewrite it.

The admin UI has two users, both with `ADMIN_DB_PASSWORD`, and the Sync users' passwords are not given to it:

- `ADMIN_DB_USER` (`ffs_admin_ui`) reaches `ffs_admin` and nothing else;
- `ADMIN_DB_SYNC_USER` (`ffs_admin_sync`) reads the Sync data and changes it only as below, and has nothing on `ffs_admin`.

Why two: the tokenserver user owns its database and can put code there, procedures, functions, views over its tables, with `SQL SECURITY INVOKER` (PostgreSQL: `SECURITY INVOKER`, the default). That code runs with the privileges of whoever calls it or reads the view, and on MariaDB and MySQL a session reaches every database by its name. With one user the Sync server's user could replace `ffs_set_max_users` with a procedure that deletes `ffs_admin.ffs_events`, and the next save of max users in the admin UI would run it with the rights on the audit trail. The admin UI only ever runs the Sync databases' code as `ffs_admin_sync` (`tests/e2e.sh` plants such a procedure and function and checks that the event log stays as it was).

What each user ends up with:

| User | MariaDB and MySQL | PostgreSQL |
|---|---|---|
| tokenserver (`SYNC_TOKENSERVER_DB_USER`) | everything on the tokenserver database (tables, the max users trigger, the procedures below), nothing on `ffs_admin` | the Sync server's role, the owner of the Sync tables, nothing on `ffs_admin` (no `CONNECT`): `SYNC_POSTGRES_APP_USER` (`syncserver_app`, no superuser) in the stack's container, `SYNC_POSTGRES_USER` on your own server |
| storage (`SYNC_STORAGE_DB_USER`) | everything on the storage database, nothing on `ffs_admin` | (the same role) |
| `SYNC_POSTGRES_USER` in the stack's container | | the image's superuser: `sync_role_init` and the init container only, for the roles, `ffs_admin`, the grants and the owner of the Sync tables (nothing that reads or writes them); its password is not given to the Sync server |
| `ffs_admin_ui` | on `ffs_admin`: `SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, LOCK TABLES` (`DROP` and `LOCK TABLES`: a restore of its dump); nothing on the Sync databases | owner of `ffs_admin`; nothing on the Sync database (no `CONNECT`) |
| `ffs_admin_sync` | on the tokenserver database: `SELECT, EXECUTE` (it changes max users and deletes rows of `users` only through `ffs_set_max_users` and `ffs_delete_user_row`, and drops the admin UI's old tables through `ffs_drop_admin_tables`, procedures of the init container that run as the tokenserver user); on the storage database: `SELECT, DELETE` (sizes, purges, resets); nothing on `ffs_admin` | on the Sync database `CONNECT`, `SELECT` on its tables, `UPDATE (config_value)` of `config` (max users), `DELETE` on `users`, `bsos`, `user_collections`, `batches` and `batch_bsos`, `EXECUTE` on `ffs_drop_admin_tables()`, given by the init container at every start; nothing on `ffs_admin` (no `CONNECT`) |

Who creates them:

- **The MariaDB and MySQL containers of the stack**: [db/mysql/admin-user.sh](/db/mysql/admin-user.sh) runs before the image's entrypoint and has the server run its statements with all privileges at every start (`--init-file`): the database, the two users with `ADMIN_DB_PASSWORD`, their grants. On the first start (MySQL: also through `mysqld --initialize`) and on the volumes of an existing install alike, whose root password is random: no administrator password is needed anywhere. The storage container gets `ffs_admin_sync` and its `SELECT, DELETE` only.
- **The PostgreSQL container**: the init container, as `SYNC_POSTGRES_USER`, which the image makes a superuser (a superuser reaches every database, `ffs_admin` too). So the Sync server does not connect as it: with `SYNC_POSTGRES_APP_USER` and `SYNC_POSTGRES_APP_PASSWORD` (`prepare_environment.sh` sets them) `sync_role_init` creates that role, no superuser, before the migrations, and gives it the right to create tables and every table, function and type of the Sync database (those of an install from before it, [sync_owner.sql](/db/postgres/init/sync_owner.sql)), at every start; the migrations, the init container's `db_init.sql` and the backups run as that role; then the admin UI's roles, `ffs_admin` and the grants. As the superuser only what runs no code of the Sync tables' owner: creating and changing roles and databases, the grants and the change of owner, with only `pg_catalog` in the search path. Whatever reads or writes those tables does it as their owner, over a login of its own (not `SET ROLE`, which code can undo): a trigger, rule, view or function the Sync server's role put there runs with its rights only (`tests/e2e.sh` has that role plant code that would make it a superuser: triggers on `config` and `nodes`, `config` itself as a view calling its function, an operator `<>` of its own in `public`; then starts the migrations and the init container again and checks that none of it ran as a superuser). So never run `psql` (or `pg_dump`, `pg_restore`) as `SYNC_POSTGRES_USER` on the Sync database yourself: connect as `SYNC_POSTGRES_APP_USER`, as [MIGRATING.md](MIGRATING.md) and [ADMIN.md#restoring](ADMIN.md#restoring) do. Without `SYNC_POSTGRES_APP_USER` (an install from before it) the Sync server stays `SYNC_POSTGRES_USER` and the setup check of the event log fails, saying so.
- **Your own server**: `database-setup.sql` above, as its administrator. Without the roles (PostgreSQL), the init container says so and the admin UI cannot connect.

### An install from before

An install from before `ADMIN_DB_PASSWORD` (its `.env` has none) keeps working as it did: the admin UI connects as the Sync users and keeps its tables in the tokenserver database. Its setup check of the event log fails and says how to move it, and its log says so at every start. To move it, as [MIGRATING.md](MIGRATING.md#older-firefox-sync-releases) says:

1. `./prepare_environment.sh --upgrade`: it adds to `.env` what this release needs and keeps every value already there (the old file is `.env.before-upgrade`): `ADMIN_DB_PASSWORD` (32 letters and digits), `ADMIN_DB_NAME`, `ADMIN_DB_USER`, `ADMIN_DB_SYNC_USER`, and with the PostgreSQL container `SYNC_POSTGRES_APP_USER` and `SYNC_POSTGRES_APP_PASSWORD`. By hand: `ADMIN_DB_PASSWORD=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 32)` in `.env`, the same for `SYNC_POSTGRES_APP_PASSWORD` with `SYNC_POSTGRES_APP_USER=syncserver_app`.
2. Your own server only: run the new `database-setup.sql` there (`--upgrade` writes it again; its statements can run again), or the admin UI's statements of the SQL above with that password.
3. `docker compose pull && docker compose up -d`. The database containers are created again with the users, the init container gives the grants (and with PostgreSQL the Sync tables to the Sync server's role), and at its first start the admin UI copies its tables of the tokenserver database into `ffs_admin` in one transaction (the events in their order, every note, metric and backup run), then drops them through `ffs_drop_admin_tables`. The event log has an event of kind `update` with what it moved; it is done once (recorded in `ffs_meta`). Admin UI tables found in the tokenserver database later (a backup of before restored, or rows the Sync server's user put there) are not copied again: the setup check names them.

If it cannot read them (a grant missing on your own server), it copies nothing, leaves them where they are and the setup check says why: nothing is lost, and the next start tries again. If it copied them but cannot drop them (no `EXECUTE`, an init image from before), they stay in the tokenserver database, within the Sync server's reach, until you drop them as the tokenserver user (`DROP TABLE ffs_events, ffs_metrics, ffs_gauges, ffs_account_notes, ffs_schema_levels, ffs_jobs, ffs_backups;`); the setup check says so too. If `ffs_admin_ui` cannot create its tables in `ffs_admin` (its grant missing), the admin UI does not start and says why, the old tables untouched. Your own backup jobs that record their runs: they now write into `ffs_admin` as `ffs_admin_ui` ([ADMIN.md](ADMIN.md#your-own-database-servers)).

`tests/e2e.sh` checks this upgrade from a checkout of the release before (`UPGRADE_FROM`: its compose files, admin UI and init image), with MariaDB, MySQL 8.4 and PostgreSQL, and `tests/podman.sh` with `prepare_environment.sh --upgrade`.

## docker compose

1. Create the databases and users (above) and check the [server requirements](#server-requirements).
1. A new install: run `./prepare_environment.sh`, or set the variables in `.env`. An install that already runs: [Moving an existing install](#moving-an-existing-install).
1. `docker compose up -d` (with `COMPOSE_FILE` as before). `deploy.replicas` of the database services is `0`, so compose starts the migrations without waiting for them.

`docker compose ps` shows no database container. Going back is `SYNC_DB_CONTAINERS=1` (and the default server names).

## Quadlets

`prepare_environment.sh` installs no `firefox-sync-syncstorage-db`, `firefox-sync-tokenserver-db` (with `SYNC_DB_CONTAINERS=0`) or `firefox-sync-fxa-db` (with `FXA_DB_CONTAINERS=0`) units, and removes them from the other units' `After=` and `Requires=`. The migrations retry until your server answers. A server on the same host is `host.containers.internal`, see [Server requirements](#server-requirements). Quadlets support MariaDB and MySQL only, as before.

## Kubernetes

The Helm chart ([HELM.md](HELM.md)), Sync only (the accounts are not in the chart):

1. Create the databases and users with [db/mysql/sync.sql](/db/mysql/sync.sql) or [db/postgres/sync.sql](/db/postgres/sync.sql) ([Databases and users](#databases-and-users)): no `prepare_environment.sh` here, replace each `@NAME@` by hand with the names of the values below and your passwords (`@ADMIN_DATABASE@`, `@ADMIN_USER@`, `@ADMIN_SYNC_USER@` are `database.admin.name`, `.user`, `.syncUser`; `@ADMIN_PASSWORD@` is `ADMIN_DB_PASSWORD`, not the admin UI's sign-in password). Check the [server requirements](#server-requirements).
1. A Secret with those passwords and the stack's secrets ([HELM.md](HELM.md#existingsecret)): `SYNC_MASTER_SECRET`, `METRICS_HASH_SECRET`, `ADMIN_DB_PASSWORD`, and `TOKENSERVER_DB_PASSWORD` and `STORAGE_DB_PASSWORD` (MariaDB, MySQL) or `POSTGRES_PASSWORD` (PostgreSQL: the owner's, `database.external.postgresUser`); the admin UI's optional ones if you use them. The chart refuses to render without it: it cannot generate passwords your server knows.
1. The values:

    ```yaml
    existingSecret: ffs-secrets
    database:
      backend: mysql            # mariadb, mysql or postgres: your server's
      bundled: false
      external:
        host: db.example.com
        port: ""                # empty: 3306, or 5432 for postgres
        # MariaDB, MySQL: the names of sync.sql (these are the defaults); storageHost and
        # storagePort for a storage database on another server
        tokenserverDatabase: tokenserver
        tokenserverUser: tokenserver
        storageDatabase: syncstorage
        storageUser: syncstorage
        # PostgreSQL: postgresDatabase and postgresUser (syncserver, syncserver)
        tlsVerify: false
    ```

| Values | `.env` | Default |
|---|---|---|
| `database.bundled` | `SYNC_DB_CONTAINERS` | `true`; `false`: your server |
| `database.external.host`, `.port` | `SYNC_TOKENSERVER_DB_HOST`, `_PORT` (or `SYNC_POSTGRES_HOST`, `_PORT`) | required; empty: `3306` or `5432` |
| `database.external.storageHost`, `.storagePort` | `SYNC_STORAGE_DB_HOST`, `_PORT` | empty: those of `host` and `port` |
| `database.external.tokenserverDatabase`, `.tokenserverUser` | `SYNC_TOKENSERVER_DB_NAME`, `_USER` | `tokenserver`, `tokenserver` |
| `database.external.storageDatabase`, `.storageUser` | `SYNC_STORAGE_DB_NAME`, `_USER` | `syncstorage`, `syncstorage` |
| `database.external.postgresDatabase`, `.postgresUser` | `SYNC_POSTGRES_NAME`, `_USER` | `syncserver`, `syncserver` (the owner, no superuser) |
| `database.external.tlsVerify` | `SYNC_DB_TLS_VERIFY` | `false` |
| `database.admin.name`, `.user`, `.syncUser` | `ADMIN_DB_NAME`, `ADMIN_DB_USER`, `ADMIN_DB_SYNC_USER` | `ffs_admin`, `ffs_admin_ui`, `ffs_admin_sync` |
| `database.image.<backend>` | `SYNC_POSTGRES_IMAGE` | the backups' client: `pg_dump` at least the server's major |

`database.external.tlsVerify` (MariaDB, MySQL): whether the init container and the backups check the server's certificate. `false` by default, as `prepare_environment.sh` writes for your own server: MySQL's own certificate is self-signed, and the CA of a managed service is not in the images (`ERROR 2026`). `true` only with a certificate from a CA the images trust (their system CAs), for that host name. The Sync server itself connects without TLS ([Server requirements](#server-requirements)).

The chart then has no database pods, volumes or Secret of its own; the Sync server's pod waits for your server in its `wait-db` init container, and stops in `migrate` while a login is refused (`kubectl logs deploy/<release>-firefox-sync-syncstorage -c migrate`). The backups (`backup.enabled`) dump your server as the users of its SQL, PostgreSQL as `postgresUser`. Moving a chart install with bundled databases to your server: the dumps of [HELM.md](HELM.md#restoring) loaded as in [Moving an existing install](#moving-an-existing-install), with the passwords of the chart's Secret in your SQL and your `existingSecret`.

## Moving an existing install

Moving from another Sync server instead of from this stack: see [MIGRATING.md](MIGRATING.md).

With docker compose. Not covered by the tests: check the result before you remove the old volumes. (Quadlets have these values written into their units by `prepare_environment.sh`: moving a Quadlet install is not described here.)

1. Don't run `prepare_environment.sh` again: it would replace `.env` with new secrets (`SYNC_MASTER_SECRET`, `SYNC_METRICS_HASH_SECRET`, the accounts' keys...) and new passwords. Keep your `.env` and change it by hand (step 5).
1. Stop the stack: `docker compose down` (not `-v`: that deletes the volumes with your data).
1. Dump the data, from the running database containers (start only them: `docker compose up -d tokenserver_db syncstorage_db`):
    - MariaDB: `docker compose exec tokenserver_db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --routines --triggers "$MARIADB_DATABASE"' > tokenserver.sql`, the same for `syncstorage_db`. These load into MariaDB 10.10+ only: their tables use MariaDB's `uca1400` collations, which MySQL rejects.
    - MySQL (`SYNC_DB=mysql`): `docker compose exec tokenserver_db sh -c 'mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --routines --triggers --no-tablespaces "$MYSQL_DATABASE"' > tokenserver.sql`, the same for `syncstorage_db` (`--no-tablespaces`: the stack's users have no `PROCESS` privilege)
    - PostgreSQL, as the Sync server's role, like the backups: `docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD="$POSTGRES_SYNC_PASSWORD" pg_dump -h "$POSTGRES_SERVER" -U "$POSTGRES_SYNC_USER" --no-owner --no-acl "$POSTGRES_DATABASE"' > syncserver.sql` (an install from before `SYNC_POSTGRES_APP_USER`: `docker compose exec postgres_db sh -c 'pg_dump -U "$POSTGRES_USER" --no-owner --no-acl "$POSTGRES_DB"' > syncserver.sql`, its Sync server is that superuser anyway)
    - the admin UI's database (the event log, the audit trail), as its user: `docker compose exec tokenserver_db sh -c 'mariadb-dump -u"$ADMIN_DB_USER" -p"$ADMIN_DB_PASSWORD" --single-transaction "$ADMIN_DB_NAME"' > ffs_admin.sql` (`mysqldump ... --no-tablespaces` with `SYNC_DB=mysql`; PostgreSQL: `docker compose exec postgres_db pg_dump -U ffs_admin_ui --no-owner --no-acl ffs_admin > ffs_admin.sql`)
    - the accounts: `docker compose exec fxa-db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --routines --triggers --databases fxa fxa_oauth fxa_profile pushbox ffs'  > fxa.sql` (`mariadb-dump` instead of `mysqldump` with `FXA_DB=mariadb`). Load it into the same kind of server: from MySQL to MariaDB or back is not tested
1. Create the databases and users on your server with the passwords already in your `.env`: copy the file of [Databases and users](#databases-and-users) (`db/mysql/sync.sql`, `db/postgres/sync.sql`, `db/mysql/fxa-<FXA_DB>.sql`) and replace each `@NAME@` with its value from `.env` (`@SYNC_TOKENSERVER_PASSWORD@` is `SYNC_TOKENSERVER_DB_PASSWORD`, `@FXA_ADMIN_PASSWORD@` is `FXA_ADMIN_DB_PASSWORD`, and so on; add `FXA_MYSQL_USER`, `FXA_MYSQL_POLICY_USER` and `FXA_MYSQL_POLICY_PASSWORD` to `.env`, it had `root`). Keep the database and user names of `.env`. Then load the dumps:
    ```bash
    mariadb -h db.example.com -u root -p tokenserver < tokenserver.sql
    mariadb -h db.example.com -u root -p syncstorage < syncstorage.sql
    psql -h db.example.com -U syncserver -d syncserver -f syncserver.sql    # as the owner: its tables
    mariadb -h db.example.com -u ffs_admin_ui -p ffs_admin < ffs_admin.sql   # psql -U ffs_admin_ui -d ffs_admin -f ffs_admin.sql
    mysql -h db.example.com -u root -p < fxa.sql                             # mariadb with FXA_DB=mariadb
    ```
    The accounts' dump creates its databases itself; its triggers, views and procedures name `root` as their definer: replace `DEFINER=\`root\`@\`%\`` with your `FXA_MYSQL_POLICY_USER` (for the `ffs` objects and the trigger on `fxa.accounts`) and `FXA_MYSQL_USER` (Mozilla's procedures) before loading it, or let `fxa-policy` recreate its own at the next start.
1. In `.env`: `SYNC_DB_CONTAINERS=0`, `SYNC_DB_TLS_VERIFY=false` and the `_HOST` and `_PORT` settings (`SYNC_TOKENSERVER_DB_HOST`, `SYNC_POSTGRES_HOST`...); for the accounts `FXA_DB_CONTAINERS=0`, `FXA_MYSQL_HOST`, `FXA_MYSQL_PORT` and the users of step 4 ([Settings](#settings)).
1. `docker compose up -d`. The old volumes stay until you remove them (`docker volume rm`, or `docker compose down -v` while `SYNC_DB_CONTAINERS=1`).

## Troubleshooting

- `ERROR 1419 ... You do not have the SUPER privilege and binary logging is enabled` (init container or `fxa-policy`): set `log_bin_trust_function_creators=ON`.
- `ERROR 2026 ... self-signed certificate in certificate chain`, then "Timeout waiting for database connection" in the init container: set `SYNC_DB_TLS_VERIFY=false` (Helm: `database.external.tlsVerify: false`).
- "Timeout waiting for database connection", or the migrations never finish: the containers cannot reach the server. Check the host (not `localhost`), the port, the server's listen address, the firewall and the users' host part. Test from the stack's network: `docker compose run --rm --no-deps --entrypoint mariadb tokenserver_db_init --host=... --user=... -p --skip-ssl-verify-server-cert -e 'SELECT 1'`. With the Helm chart: `kubectl logs deploy/<release>-firefox-sync-syncstorage -c wait-db` (the server answers) and `-c migrate` (the login).
- `ER_NOT_SUPPORTED_AUTH_MODE` from the accounts (fxa-migrations, fxa-auth): `FXA_MYSQL_USER` must use `mysql_native_password`, and MySQL 8.4 needs `mysql_native_password=ON`.
- `ER_CANT_DROP_FIELD_OR_KEY: Can't DROP FOREIGN KEY ..._ibfk_1` from fxa-migrations: the server is MariaDB 12 and the accounts image does not have [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494) (Mozilla's images, or ours from before, [MariaDB 12](FXA.md#mariadb-12)): use our current images, or MariaDB 11.4 to 11.8 on a new database.
- `Access denied` from PostgreSQL, or `no pg_hba.conf entry`: add a `host` line for the containers' addresses.
