# Your own database server

By default the stack starts its own databases: two MariaDB containers ([docker-compose.yml](/docker-compose.yml), or [MySQL 8.4](#mariadb-or-mysql-containers)), one PostgreSQL container ([docker-compose.postgres.yml](/docker-compose.postgres.yml)), and with [self-hosted accounts](FXA.md) one MySQL (or [MariaDB](FXA.md#mysql-or-mariadb)) container (`fxa-db`). You can use a MariaDB, MySQL or PostgreSQL server you already run instead.

What changes:
- `DB_CONTAINERS=0` (and `FXA_DB_CONTAINERS=0` for the accounts) in `.env`: those containers are not started, everything else is the same.
- You create the databases and users once, with the SQL below. The stack never needs an administrator account on your server.
- The migrations and the init container still run at every start, as the users below: the tables, the `MAX_USERS` trigger and the sign-up policy are created and updated by the stack.
- Backups are yours: the stack's volumes are not used, and the backup service (`COMPOSE_PROFILES=backup`) is for the database containers. Your backup job can record its runs for the admin UI, which then shows the last one and alerts when it fails or gets old: see [ADMIN.md](ADMIN.md#your-own-database-servers).

## MariaDB or MySQL containers

This section is about the database containers of the stack, not your own server. The two Sync databases (`syncstorage_db`, `tokenserver_db`) run on MariaDB (`mariadb:lts`) by default. With `SYNC_DB=mysql` they run on MySQL 8.4 instead, which is what upstream syncstorage-rs is developed and tested on. On MariaDB one of upstream's tokenserver tests is skipped here because MariaDB orders the nodes differently (see `tests/e2e.sh`); on MySQL it runs. The images (`syncstorage-rs-mysql`, `syncstorage-rs-mysql-init`) and the `MARIADB_*` settings of `.env` stay the same.

- `prepare_environment.sh`: answer `mysql` to the database backend question. It writes `SYNC_DB=mysql` and `MARIADB_TLS_VERIFY=false`, and adds [docker-compose.sync-mysql.yml](/docker-compose.sync-mysql.yml) to `COMPOSE_FILE`. With Quadlets the units of [config/quadlet/mysql/](/config/quadlet/mysql) replace the two MariaDB units.
- By hand: `SYNC_DB=mysql` in `.env` and `COMPOSE_FILE=docker-compose.yml:docker-compose.sync-mysql.yml` (with the accounts `docker-compose.yml:docker-compose.sync-mysql.yml:docker-compose.fxa.yml`; with the Podman socket `-f docker-compose.yml -f docker-compose.podman.yml -f docker-compose.sync-mysql.yml`).
- Choose it before the first start. MySQL gets its own volumes (`syncstorage-db-mysql` and `tokenserver-db-mysql`, Quadlets: `firefox-sync-syncstorage-db-mysql` and `firefox-sync-tokenserver-db-mysql`), so it never opens MariaDB's data files. If you switch an existing install, MariaDB's data stays in its volumes and Sync starts with empty databases. Moving the data takes a dump and a reload, which is not tested here. Also, MariaDB's dumps use its `uca1400` collations, which MySQL rejects (see [Moving an existing install](#moving-an-existing-install)). Going back to MariaDB finds MariaDB's volumes as you left them.
- No binary logging (`--disable-log-bin`), the same as the MariaDB containers. No replica reads the log, and MySQL would keep 30 days of every change (`binlog_expire_logs_seconds`). With binary logging on, the init container could only create the `MAX_USERS` procedure and trigger with `log_bin_trust_function_creators=ON` (`ERROR 1419`). If you want binary logs (a replica, point-in-time recovery), replace `--disable-log-bin` with `--log-bin-trust-function-creators=ON` in the `command` (Quadlets: `Exec=`). That combination is what the `EXTERNAL_DB=1` tests run.
- The users use MySQL 8.4's default `caching_sha2_password`, with no `mysql_native_password`. The Sync server and the admin UI connect without TLS, the same as with your own MySQL server. The init container's MariaDB client connects over TLS without checking MySQL's self-signed certificate, on the stack's own network (`MARIADB_TLS_VERIFY=false`, which `docker-compose.sync-mysql.yml` sets for compose; without it the init fails with `ERROR 2026`).
- `mysql:8.4` is the current MySQL LTS release.

## Supported servers

| Component | Supported | Tested |
|---|---|---|
| Sync server | MariaDB 10.10+, MySQL 8.0 and 8.4, PostgreSQL 11+ | MariaDB 12.3, MySQL 8.4, PostgreSQL 18 |
| Accounts | MySQL 8.0 and 8.4, MariaDB 11.4 to 11.8 | MySQL 8.4, MariaDB 11.8 (and 11.4 once) |

Mozilla supports MySQL only for the accounts; MariaDB passes the same tests here (`FXA_DB=mariadb`, see [MySQL or MariaDB](FXA.md#mysql-or-mariadb)). The accounts don't work on MariaDB 12 (`mariadb:lts` today): Mozilla's migrations drop foreign keys by MySQL's names, which MariaDB 12 no longer gives them (`ER_CANT_DROP_FIELD_OR_KEY: Can't DROP FOREIGN KEY deviceCommands_ibfk_1`). MySQL 9 does not work either: it has no `mysql_native_password`, the only one the accounts' driver supports.

## Server requirements

- **Reachable from the containers.** `localhost` and `127.0.0.1` are the container itself, not your host. Use a host name or an IPv4 address: an IPv6 address would need `[ ]` in the database URLs, which `prepare_environment.sh` refuses.
    - A server on the Docker host: use the address of the Docker bridge (often `172.17.0.1`, see `ip addr show docker0`) and make the server listen there. The containers connect from the stack's own network, whose subnet compose picks from `172.16.0.0/12` or `192.168.0.0/16`: check it with `docker network inspect <project>_default` (the project is the directory name, e.g. `firefox-sync_default`) and allow it in the server's firewall and user hosts.
    - With Podman (Quadlets or the socket): `host.containers.internal`. It is the host's main address (`podman run --rm docker.io/library/busybox cat /etc/hosts` shows it), not `127.0.0.1`: a server that listens on `127.0.0.1` only (the usual default) cannot be reached that way. Make it listen on that address, and allow connections from that address in its users' host part and its firewall: the containers connect from it.
    - A server elsewhere: its host name or address.
- **Plain connections, on a trusted network only.** The Sync server cannot use TLS to its database (its MySQL driver is built without TLS, its PostgreSQL driver connects without it), and neither can the accounts' driver. So the server must accept connections without TLS from these users: `host` lines (not `hostssl`) in PostgreSQL's `pg_hba.conf` (per user, so the other applications can keep `hostssl`), `require_secure_transport=OFF` on MySQL and MariaDB. That one is server-wide: on a server that enforces TLS for other applications, turning it off lets all of them connect without it. Either give those applications' accounts `REQUIRE SSL` (`ALTER USER 'app'@'%' REQUIRE SSL;`, per account) before turning it off, or leave it on and use a server or instance of its own for this stack. Keep the database on the same host, or on a private network or VPN you trust.
- **MariaDB and MySQL with binary logging** (the default on MySQL 8, `log_bin` on MariaDB): set `log_bin_trust_function_creators=ON`, otherwise the users below cannot create the `MAX_USERS` trigger and the sign-up policy's function and trigger (`ERROR 1419`). On MySQL `SET PERSIST log_bin_trust_function_creators = ON;`, on MariaDB `SET GLOBAL log_bin_trust_function_creators = 1;` and the same in `my.cnf`. On managed services (RDS, Cloud SQL...) set it in the parameter group. Granting `SUPER` instead works too, but is not recommended.
- **MariaDB and MySQL:** `explicit_defaults_for_timestamp=ON`, the default since MySQL 8.0 and MariaDB 10.10.
- **The accounts on MySQL 8.4:** start it with `mysql_native_password=ON` (`--mysql-native-password=ON` or in `my.cnf`). On 8.0 it is on by default. MariaDB needs nothing: `fxa-mariadb.sql` creates the user with `mysql_native_password` explicitly.
- **PostgreSQL:** a `host` line for the containers' addresses with `scram-sha-256`, e.g. `host syncserver syncserver 172.16.0.0/12 scram-sha-256`.

## Databases and users

The SQL is in [config/database/](/config/database), with `@NAME@` placeholders. When you answer `y` to "Use an existing database server instead of starting one?" (or to the same question for the accounts), `prepare_environment.sh` fills them in with the names and the generated passwords of `.env` and writes `database-setup.sql` (and `database-setup-fxa.sql` for the accounts), readable by you only. Run it as an administrator of your server, then delete it:

```bash
mysql -h db.example.com -u root -p < database-setup.sql          # MySQL
mariadb -h db.example.com -u root -p < database-setup.sql        # MariaDB (its client may not install a mysql command)
psql -h db.example.com -U postgres -f database-setup.sql         # PostgreSQL
mysql -h db.example.com -u root -p < database-setup-fxa.sql      # the accounts, MySQL 8
mariadb -h db.example.com -u root -p < database-setup-fxa.sql    # the accounts, MariaDB 11.4 to 11.8
```

Use only `A-Z a-z 0-9 . _ ~ -` in passwords (the generated ones are letters and digits): they are part of the database URLs. Names are `a-z`, `0-9` and `_`.

The users connect from `'%'`, any address: the passwords are the only check. Replace `'%'` in the file with your containers' network (e.g. `'172.16.0.0/255.240.0.0'`, see [Server requirements](#server-requirements)) before you run it, in every line.

Running `prepare_environment.sh` again makes new passwords, and new secrets for everything else (`SYNC_MASTER_SECRET`, the accounts' keys...). The SQL sets the passwords of users that already exist again, so a new setup matches its new `.env`. For an install that already runs, don't: keep its `.env` (see [Moving an existing install](#moving-an-existing-install)).

### Sync on MariaDB or MySQL: [sync-mariadb.sql](/config/database/sync-mariadb.sql)

```sql
CREATE DATABASE IF NOT EXISTS `@TOKENSERVER_DATABASE@`;
CREATE DATABASE IF NOT EXISTS `@SYNCSTORAGE_DATABASE@`;
CREATE USER IF NOT EXISTS '@TOKENSERVER_USER@'@'%' IDENTIFIED BY '@TOKENSERVER_PASSWORD@';
CREATE USER IF NOT EXISTS '@SYNCSTORAGE_USER@'@'%' IDENTIFIED BY '@SYNCSTORAGE_PASSWORD@';
ALTER USER '@TOKENSERVER_USER@'@'%' IDENTIFIED BY '@TOKENSERVER_PASSWORD@';
ALTER USER '@SYNCSTORAGE_USER@'@'%' IDENTIFIED BY '@SYNCSTORAGE_PASSWORD@';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
  CREATE ROUTINE, ALTER ROUTINE, EXECUTE, TRIGGER ON `@TOKENSERVER_DATABASE@`.* TO '@TOKENSERVER_USER@'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
  CREATE ROUTINE, ALTER ROUTINE, EXECUTE ON `@SYNCSTORAGE_DATABASE@`.* TO '@SYNCSTORAGE_USER@'@'%';
```

- The tokenserver user creates the tables (the migrations), the init container's `config` table, the `CheckUserLimit` procedure and the `BeforeInsertUser` trigger that enforce `MAX_USERS`, and the admin UI's `ffs_metrics`, `ffs_events`, `ffs_gauges`, `ffs_account_notes`, `ffs_schema_levels`, `ffs_jobs` and `ffs_backups` tables.
- The storage user creates the tables (the migrations; one of them creates, calls and drops a procedure).
- `REFERENCES` is needed on MySQL 8.0.22+ for the tokenserver's foreign keys.
- Two databases, not one: both migrations keep their state in a table with the same name.

### Sync on PostgreSQL: [sync-postgres.sql](/config/database/sync-postgres.sql)

```sql
CREATE ROLE @POSTGRES_USER@ LOGIN PASSWORD '@POSTGRES_PASSWORD@';
ALTER ROLE @POSTGRES_USER@ PASSWORD '@POSTGRES_PASSWORD@';
GRANT @POSTGRES_USER@ TO CURRENT_USER;
CREATE DATABASE @POSTGRES_DATABASE@ OWNER @POSTGRES_USER@;
REVOKE ALL ON DATABASE @POSTGRES_DATABASE@ FROM PUBLIC;
```

- The owner of the database creates the tables, the `post_bso` type, the `check_user_limit()` function and its trigger, and the admin UI's tables. It needs no superuser, `CREATEDB` or `CREATEROLE`.
- Run it as a superuser, or as a role with `CREATEROLE` and `CREATEDB` (what managed services such as RDS or Cloud SQL give you, tested): the `GRANT` lets that role create a database owned by the new one, which PostgreSQL 16+ requires.
- Run again, `CREATE ROLE` and `CREATE DATABASE` fail with "already exists" and `psql -f` goes on: the `ALTER ROLE` sets the new password.
- The `REVOKE` keeps the other roles of a shared server out (no connections, no temporary tables).
- For a database that already exists: `ALTER DATABASE syncserver OWNER TO syncserver;`.
- PostgreSQL 11 to 14 let every role create objects in the `public` schema of every database. Close it in the new database, as a superuser: `psql -h db.example.com -U postgres -d syncserver -c 'REVOKE CREATE ON SCHEMA public FROM PUBLIC; ALTER SCHEMA public OWNER TO syncserver;'` (since PostgreSQL 15 that is the default, and the database owner owns `public`).

### The accounts on MySQL 8 or MariaDB 11: [fxa-mysql.sql](/config/database/fxa-mysql.sql), [fxa-mariadb.sql](/config/database/fxa-mariadb.sql)

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
- `FXA_MYSQL_POLICY_USER` (`ffs_policy`): `fxa-policy` installs the [sign-up policy](ADMIN.md#who-can-sign-up-self-hosted-accounts) at every start: the database `ffs`, a trigger on `fxa.accounts`, views and procedures that read and delete tokens, disable and delete accounts, turn off two-step authentication, remove recovery keys, confirm emails and prune expired tokens with its privileges (they call Mozilla's own procedures, hence `EXECUTE` on `fxa`), and the grants of the admin UI's user (hence `WITH GRANT OPTION`): `SELECT` on a few columns of `fxa.accounts` and on the views (which leave out every secret), `EXECUTE` on those procedures, nothing that changes the accounts' tables directly. `SELECT` on `fxa_profile` and `pushbox` lets the admin UI show the size of all five databases, `DELETE` there removes the profile and the push messages of a deleted account. When a procedure it calls is missing (a newer FxA release, or no `EXECUTE`), `fxa-policy` logs a warning naming it and the accounts keep working, but what needs it in the admin UI answers with an error (ADMIN.md, Disabling an account).
- Upgrading from a version whose script had no `EXECUTE` in the policy user's grant on `fxa`: run ``GRANT EXECUTE ON `fxa`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;`` once, then restart `fxa-policy`.
- Upgrading from a version whose script had only `SELECT` on `fxa_profile` and `pushbox`: run ``GRANT DELETE ON `fxa_profile`.* TO '@FXA_POLICY_USER@'@'%'; GRANT DELETE ON `pushbox`.* TO '@FXA_POLICY_USER@'@'%';`` once, otherwise deleting an account in the admin UI fails (and changes nothing).
- `ffs_admin`, with `FXA_ADMIN_DB_PASSWORD`: the admin UI's user, created here and not by `fxa-policy`. `CREATE USER` is a server-wide privilege that also lets its holder change the password of every other account (on MariaDB including `root`), so the policy user does not get it. `fxa-policy` finds `ffs_admin` there and only gives it its grants.
- The grants are on whole databases because the tables don't exist yet when you run this.
- The database names are fixed (`fxa`, `fxa_oauth`, `fxa_profile`, `pushbox`, `ffs`): a server or instance of its own for the accounts is best.
- One user for both is possible (tested): leave `FXA_MYSQL_POLICY_USER` empty (`FXA_MYSQL_POLICY_PASSWORD` is then not used, `fxa-policy` connects with `FXA_MYSQL_PASSWORD`). In `database-setup-fxa.sql`, delete the policy user's `CREATE USER` and `ALTER USER` lines and put the name of `FXA_MYSQL_USER` in its `GRANT`s. The accounts services, which face the internet, then also hold `GRANT OPTION` on `fxa`, `fxa_oauth` and `ffs`: they could pass their access to the accounts on to any other user of the server.

## Settings

All in `.env`. `prepare_environment.sh` writes them when you answer `y`.

| Setting | Default | Your own server |
|---|---|---|
| `DB_CONTAINERS` | `1` | `0`: no `syncstorage_db`, `tokenserver_db` or `postgres_db` container |
| `SYNC_DB` | `mariadb` | not used: it picks the database containers, `mysql` for [MySQL 8.4](#mariadb-or-mysql-containers) |
| `MARIADB_TLS_VERIFY` | `true` | `false`: the init container's client checks the server's certificate, and MySQL's own is self-signed (the Sync server itself does not use TLS) |
| `MARIADB_TOKENSERVER_SERVER`, `_SERVER_PORT`, `_DATABASE`, `_USER`, `_PASSWORD` | `tokenserver_db`, `3306`, `tokenserver`, `tokenserver` | your server and the names of the SQL above |
| `MARIADB_SYNCSTORAGE_SERVER`, `_SERVER_PORT`, `_DATABASE`, `_USER`, `_PASSWORD` | `syncstorage_db`, `3306`, `syncstorage`, `syncstorage` | the same server, or another one |
| `POSTGRES_SERVER`, `_SERVER_PORT`, `_DATABASE`, `_USER`, `POSTGRES_PASSWORD` | `postgres_db`, `5432`, `syncserver`, `syncserver` | your server, with PostgreSQL |
| `FXA_DB_CONTAINERS` | `1` | `0`: no `fxa-db` container |
| `FXA_DB` | `mysql` | `mariadb` with a MariaDB server: the SQL above and the client in the instructions |
| `FXA_MYSQL_HOST`, `FXA_MYSQL_PORT` | `fxa-db`, `3306` | your MySQL 8 or MariaDB 11 server |
| `FXA_MYSQL_USER`, `FXA_MYSQL_PASSWORD` | `root` | `fxa` and its password |
| `FXA_MYSQL_POLICY_USER`, `FXA_MYSQL_POLICY_PASSWORD` | empty: `FXA_MYSQL_USER` and `FXA_MYSQL_PASSWORD` | `ffs_policy` and its password |
| `FXA_ADMIN_DB_PASSWORD` | generated | the password of `ffs_admin` in `database-setup-fxa.sql` |

The [admin UI](ADMIN.md) uses the same Sync users, and `ffs_admin` for the accounts: no extra grants.

## docker compose

1. Create the databases and users (above) and check the [server requirements](#server-requirements).
1. A new install: run `./prepare_environment.sh`, or set the variables in `.env`. An install that already runs: [Moving an existing install](#moving-an-existing-install).
1. `docker compose up -d` (with `COMPOSE_FILE` as before). `deploy.replicas` of the database services is `0`, so compose starts the migrations without waiting for them.

`docker compose ps` shows no database container. Going back is `DB_CONTAINERS=1` (and the default server names).

## Quadlets

`prepare_environment.sh` installs no `firefox-sync-syncstorage-db`, `firefox-sync-tokenserver-db` (with `DB_CONTAINERS=0`) or `firefox-sync-fxa-db` (with `FXA_DB_CONTAINERS=0`) units, and removes them from the other units' `After=` and `Requires=`. The migrations retry until your server answers. A server on the same host is `host.containers.internal`, see [Server requirements](#server-requirements). Quadlets support MariaDB and MySQL only, as before.

## Moving an existing install

With docker compose. Not covered by the tests: check the result before you remove the old volumes. (Quadlets have these values written into their units by `prepare_environment.sh`: moving a Quadlet install is not described here.)

1. Don't run `prepare_environment.sh` again: it would replace `.env` with new secrets (`SYNC_MASTER_SECRET`, `METRICS_HASH_SECRET`, the accounts' keys...) and new passwords. Keep your `.env` and change it by hand (step 5).
1. Stop the stack: `docker compose down` (not `-v`: that deletes the volumes with your data).
1. Dump the data, from the running database containers (start only them: `docker compose up -d tokenserver_db syncstorage_db`):
    - MariaDB: `docker compose exec tokenserver_db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --routines --triggers "$MARIADB_DATABASE"' > tokenserver.sql`, the same for `syncstorage_db`. These load into MariaDB 10.10+ only: their tables use MariaDB's `uca1400` collations, which MySQL rejects.
    - MySQL (`SYNC_DB=mysql`): `docker compose exec tokenserver_db sh -c 'mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --routines --triggers --no-tablespaces "$MYSQL_DATABASE"' > tokenserver.sql`, the same for `syncstorage_db` (`--no-tablespaces`: the stack's users have no `PROCESS` privilege)
    - PostgreSQL: `docker compose exec postgres_db sh -c 'pg_dump -U "$POSTGRES_USER" --no-owner --no-acl "$POSTGRES_DB"' > syncserver.sql`
    - the accounts: `docker compose exec fxa-db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --routines --triggers --databases fxa fxa_oauth fxa_profile pushbox ffs'  > fxa.sql` (`mariadb-dump` instead of `mysqldump` with `FXA_DB=mariadb`). Load it into the same kind of server: from MySQL to MariaDB or back is not tested
1. Create the databases and users on your server with the passwords already in your `.env`: copy the file of [config/database/](/config/database) and replace each `@NAME@` with its value from `.env` (`@TOKENSERVER_PASSWORD@` is `MARIADB_TOKENSERVER_PASSWORD`, `@FXA_ADMIN_PASSWORD@` is `FXA_ADMIN_DB_PASSWORD`, and so on; add `FXA_MYSQL_USER`, `FXA_MYSQL_POLICY_USER` and `FXA_MYSQL_POLICY_PASSWORD` to `.env`, it had `root`). Keep the database and user names of `.env`. Then load the dumps:
    ```bash
    mariadb -h db.example.com -u root -p tokenserver < tokenserver.sql
    mariadb -h db.example.com -u root -p syncstorage < syncstorage.sql
    psql -h db.example.com -U syncserver -d syncserver -f syncserver.sql    # as the owner: its tables
    mysql -h db.example.com -u root -p < fxa.sql                             # mariadb with FXA_DB=mariadb
    ```
    The accounts' dump creates its databases itself; its triggers, views and procedures name `root` as their definer: replace `DEFINER=\`root\`@\`%\`` with your `FXA_MYSQL_POLICY_USER` (for the `ffs` objects and the trigger on `fxa.accounts`) and `FXA_MYSQL_USER` (Mozilla's procedures) before loading it, or let `fxa-policy` recreate its own at the next start.
1. In `.env`: `DB_CONTAINERS=0`, `MARIADB_TLS_VERIFY=false` and the `_SERVER` and `_SERVER_PORT` settings (`POSTGRES_SERVER`...); for the accounts `FXA_DB_CONTAINERS=0`, `FXA_MYSQL_HOST`, `FXA_MYSQL_PORT` and the users of step 4 ([Settings](#settings)).
1. `docker compose up -d`. The old volumes stay until you remove them (`docker volume rm`, or `docker compose down -v` while `DB_CONTAINERS=1`).

## Troubleshooting

- `ERROR 1419 ... You do not have the SUPER privilege and binary logging is enabled` (init container or `fxa-policy`): set `log_bin_trust_function_creators=ON`.
- `ERROR 2026 ... self-signed certificate in certificate chain`, then "Timeout waiting for database connection" in the init container: set `MARIADB_TLS_VERIFY=false`.
- "Timeout waiting for database connection", or the migrations never finish: the containers cannot reach the server. Check the host (not `localhost`), the port, the server's listen address, the firewall and the users' host part. Test from the stack's network: `docker compose run --rm --no-deps --entrypoint mariadb tokenserver_db_init --host=... --user=... -p --skip-ssl-verify-server-cert -e 'SELECT 1'`.
- `ER_NOT_SUPPORTED_AUTH_MODE` from the accounts (fxa-migrations, fxa-auth): `FXA_MYSQL_USER` must use `mysql_native_password`, and MySQL 8.4 needs `mysql_native_password=ON`.
- `ER_CANT_DROP_FIELD_OR_KEY: Can't DROP FOREIGN KEY ..._ibfk_1` from fxa-migrations: the server is MariaDB 12, use 11.4 to 11.8.
- `Access denied` from PostgreSQL, or `no pg_hba.conf entry`: add a `host` line for the containers' addresses.
