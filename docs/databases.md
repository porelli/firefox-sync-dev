# Databases

This page is for choosing the database of the Sync server and of the self-hosted accounts, and for running them on a server you already have. It holds the only table of supported versions. Read your install page first: [docker compose](install/compose.md), [Podman](install/podman.md) or [Helm](install/helm.md).

## Choose a backend

By default the stack starts its own database containers. You choose the server software once, before the first start.

| Component | Backend | How to choose it |
|---|---|---|
| Sync server | MariaDB (the default) | nothing to do |
| Sync server | MySQL | [MySQL instead of MariaDB](#mysql-instead-of-mariadb) |
| Sync server | PostgreSQL | [PostgreSQL](#postgresql). Not with Quadlets |
| Self-hosted accounts | MySQL (the default, what Mozilla runs) | nothing to do |
| Self-hosted accounts | MariaDB | [MySQL or MariaDB](accounts.md#mysql-or-mariadb) |

Each backend has volumes of its own. Switching an existing install starts with empty databases and leaves the old data in the old volumes. Moving data between MariaDB and MySQL takes a dump and a reload, which is not tested here.

To use a server you already run instead of the containers, see [Your own server](#your-own-server).

## Supported versions

### Servers

"Tested" is what CI runs on every image before it is published. Which job runs which one: [the test matrix](development/testing.md#test-matrix).

| Component | Backend | Supported | Tested |
|---|---|---|---|
| Sync server | MariaDB | 10.10 and later | `mariadb:lts` (12 today) |
| Sync server | MySQL | 8.0 and later, 9 included | `mysql:lts` (9 today) and `mysql:8` (8.4) |
| Sync server | PostgreSQL | 11 and later | `postgres:latest` (18 today) |
| Accounts | MySQL | 8.4 and 9 | `mysql:lts` (9 today), and `mysql:8` (8.4) with `mysql_native_password` |
| Accounts | MariaDB | 11.4 and later | `mariadb:lts` (12 today) and `mariadb:11` (11.8) |
| Accounts | Redis (cache, no volume) | the image's | `redis:alpine` |

MySQL 8.0 reached its end of life in April 2026. It still works for the Sync server, but it is not tested here.

Some of these need an accounts image with [the upstream patches](reference/images.md#upstream-patches):

| Accounts database | Our accounts images | Mozilla's image, or ours built before the patch |
|---|---|---|
| MySQL 9 | yes | no: MySQL 9 has no `mysql_native_password`, the only method Mozilla's driver speaks |
| MySQL 8.4 with its default `caching_sha2_password` | yes | no |
| MySQL 8.4 with `mysql_native_password=ON`, the accounts' user on it | yes | yes |
| MariaDB 12 and later | yes | no: the migrations stop with `ER_CANT_DROP_FIELD_OR_KEY` |
| MariaDB 11.4 to 11.8 | yes | yes |

The patches are [mozilla/fxa#21554](https://github.com/mozilla/fxa/pull/21554) for MySQL ([MySQL 9](accounts.md#mysql-9)) and [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494) for MariaDB ([MariaDB 12](accounts.md#mariadb-12)). The Sync server's patches fix an upstream test and the order of tied nodes. They don't change which servers the Sync server supports.

### Default tags and pins

The defaults follow each database's long-term tag: `mariadb:lts` and `mysql:lts`. PostgreSQL has no such tag, so each install is pinned to the major `postgres:latest` had when it was set up. When `lts` moves, the server upgrades the data at its first start on it, and there is no way back but a backup.

Each setting, its default, the pins `prepare_environment.sh` writes, and how to move to a newer major: [Database majors](upgrading.md#database-majors). The images the stack builds on top of these (the init containers): [Images](reference/images.md#sync-server).

## MySQL instead of MariaDB

This is about the stack's database containers for Sync. The two Sync databases (`syncstorage_db`, `tokenserver_db`) can run on MySQL instead of MariaDB. MySQL is what upstream syncstorage-rs is developed and tested on. The Sync images (`syncstorage-rs-mysql`, `syncstorage-rs-mysql-init`) are the same for both.

To choose it:

- With `prepare_environment.sh`: answer `mysql` to the database backend question. It writes `SYNC_DB=mysql` and `SYNC_DB_TLS_VERIFY=false`, and adds [docker-compose.sync-mysql.yml](/docker-compose.sync-mysql.yml) to `COMPOSE_FILE`.
- By hand, in `.env`:

  ```ini
  SYNC_DB=mysql
  COMPOSE_FILE=docker-compose.yml:docker-compose.sync-mysql.yml
  ```

  With the accounts, add `:docker-compose.fxa.yml`. With the Podman socket, use `-f docker-compose.yml -f docker-compose.podman.yml -f docker-compose.sync-mysql.yml`.
- With Quadlets, the units of [config/quadlet/sync-mysql/](/config/quadlet/sync-mysql) replace the two MariaDB units.
- With the Helm chart: `database.backend: mysql`.

What differs from MariaDB:

- MySQL has its own volumes: `syncstorage-db-mysql` and `tokenserver-db-mysql` (Quadlets: `firefox-sync-syncstorage-db-mysql` and `firefox-sync-tokenserver-db-mysql`). Going back to MariaDB finds MariaDB's volumes as you left them.
- MariaDB's dumps use its `uca1400` collations, which MySQL rejects. See [Move an existing install](#move-an-existing-install).
- No binary logging (`--disable-log-bin`), as in the MariaDB containers. No replica reads it, and MySQL would keep 30 days of every change.
- The users use MySQL's default `caching_sha2_password`.
- The init container's client connects over TLS without checking MySQL's self-signed certificate (`SYNC_DB_TLS_VERIFY=false`). Without it the init fails with `ERROR 2026`.
- The image is `SYNC_MYSQL_IMAGE`, see [Database majors](upgrading.md#database-majors).

To keep binary logs (a replica, point-in-time recovery), replace `--disable-log-bin` with `--log-bin-trust-function-creators=ON` in the `command` (Quadlets: `Exec=`). Without that flag the init container cannot create the max users procedure and trigger (`ERROR 1419`).

On kind or k3s on an Ubuntu host with `mysql-server` installed, see [Troubleshooting](troubleshooting.md#kubernetes) (AppArmor).

## PostgreSQL

The Sync server can run on PostgreSQL, with the `syncstorage-rs-postgres` images and [docker-compose.sync-postgres.yml](/docker-compose.sync-postgres.yml). `prepare_environment.sh` sets both when you answer `postgres` to the database backend question. The self-hosted accounts cannot use PostgreSQL, and Quadlets don't support it: with Podman, `prepare_environment.sh` falls back to docker compose on the Podman socket.

`SYNC_POSTGRES_IMAGE` pins the PostgreSQL major of each install, for `postgres_db` and the backups: see [PostgreSQL](upgrading.md#postgresql).

With your own server, `SYNC_POSTGRES_IMAGE` is only the client of the backups. `pg_dump` must be at least the server's major: set it to your server's major or a newer one. With Helm, the same goes for `database.image.postgres`.

## Your own server

You can use a MariaDB, MySQL or PostgreSQL server you already run instead of the stack's containers. Check its version in [Supported versions](#supported-versions).

What changes:

- `SYNC_DB_CONTAINERS=0` in `.env`, and `FXA_DB_CONTAINERS=0` for the accounts. Those containers are not started; everything else is the same. With Helm: `database.bundled: false`, see [With Helm](#with-helm).
- You create the databases and users once, as an administrator of your server. The stack never needs an administrator account there.
- The migrations and the init container still run at every start, as those users. The stack creates and updates the tables, the max users trigger and the sign-up policy.
- The admin UI has a database and two users of its own on that server, out of the Sync server's reach. See [Database users](reference/database-users.md#the-admin-uis-own-database).
- Backups are yours: the backup service dumps the stack's containers only. Your backup job can record its runs for the admin UI, see [Backups](backups.md#your-own-database-server). The Helm chart's backups do run against your server, as its users.

Every setting, with its Helm value: [Settings](reference/settings.md#your-own-database-server).

### Server requirements

- **Reachable from the containers.** `localhost` and `127.0.0.1` are the container itself, not your host. Use a host name or an IPv4 address: `prepare_environment.sh` refuses an IPv6 address.
    - A server on the Docker host: the address of the Docker bridge (often `172.17.0.1`), with the server listening there. The containers connect from the stack's own network: allow its subnet (`docker network inspect firefox-sync_default`) in the firewall and in the users' host part. See [Docker's networking docs](https://docs.docker.com/engine/network/).
    - With Podman: `host.containers.internal`, the host's main address, not `127.0.0.1`. The server must listen there and accept connections from that address. See [Podman's networking docs](https://docs.podman.io/en/latest/markdown/podman-network.1.html).
    - A server elsewhere: its host name or address.
    - Kubernetes: a host name or IPv4 address the pods resolve and reach. A Service of type `ExternalName` works too. Allow the pod network, or the nodes' addresses if the cluster masquerades outgoing traffic.
- **Plain connections, on a trusted network only.** The Sync server and the accounts cannot use TLS to their database. Keep the database on the same host, or on a private network or VPN you trust.
    - PostgreSQL: `host` lines (not `hostssl`) in `pg_hba.conf` for these users, with `scram-sha-256`. For example: `host syncserver syncserver 172.16.0.0/12 scram-sha-256`.
    - MariaDB and MySQL: `require_secure_transport=OFF`. This setting is server-wide. If other applications on that server need TLS, give this stack a server or instance of its own ([MySQL's docs](https://dev.mysql.com/doc/refman/8.4/en/using-encrypted-connections.html)).
- **MariaDB and MySQL with binary logging** (the default on MySQL): `log_bin_trust_function_creators=ON`. Without it the users cannot create the max users trigger or the sign-up policy's function and trigger (`ERROR 1419`). On MySQL:

  ```sql
  SET PERSIST log_bin_trust_function_creators = ON;
  ```

  On MariaDB, run this and set the same in `my.cnf`:

  ```sql
  SET GLOBAL log_bin_trust_function_creators = 1;
  ```

  Granting `SUPER` instead works too, but is not recommended.
- **MariaDB and MySQL:** `explicit_defaults_for_timestamp=ON`, the default since MySQL 8.0 and MariaDB 10.10.
- **The accounts on MySQL with an image without mozilla/fxa#21554:** MySQL 8.4 started with `mysql_native_password=ON`, and the accounts' user created with it. `prepare_environment.sh` writes the SQL that way for such an image. With our images nothing is needed. MariaDB needs nothing either.

### Create the databases and users

The SQL is in [db/mysql/](/db/mysql) (MariaDB and MySQL) and [db/postgres/](/db/postgres), with `@NAME@` placeholders. What each user gets, and why: [Database users](reference/database-users.md).

1. Run `./prepare_environment.sh` and answer `y` to "Use an existing database server instead of starting one?". For the accounts, answer `y` to the same question about them too.

   It fills in the placeholders with the names and generated passwords of `.env`, and writes `database-setup.sql` (and `database-setup-fxa.sql` for the accounts), readable by you only.
1. Optional: replace `'%'` in every line of the file with your containers' network, for example `'172.16.0.0/255.240.0.0'`. With `'%'` the users connect from any address, and the passwords are the only check.
1. Run the file as an administrator of your server:

   ```bash
   mysql -h db.example.com -u root -p < database-setup.sql          # MySQL
   mariadb -h db.example.com -u root -p < database-setup.sql        # MariaDB (its client may not install a mysql command)
   psql -h db.example.com -U postgres -f database-setup.sql         # PostgreSQL
   mysql -h db.example.com -u root -p < database-setup-fxa.sql      # the accounts, MySQL
   mariadb -h db.example.com -u root -p < database-setup-fxa.sql    # the accounts, MariaDB
   ```

1. Delete the file: it holds the passwords.

Rules for names and passwords:

- Passwords: only `A-Z a-z 0-9 . _ ~ -`, because they are part of the database URLs. The generated ones are letters and digits.
- The Sync users need a password. The init container refuses an empty one or a `<REPLACE_WITH_...>` placeholder, so a passwordless login (`trust` in `pg_hba.conf`) keeps the Sync server down.
- Names: `a-z`, `0-9` and `_`.

Running `prepare_environment.sh` again makes new passwords and new secrets for everything else (`SYNC_MASTER_SECRET`, the accounts' keys). The SQL sets the passwords of existing users again, so a new setup matches its new `.env`. For an install that already runs, don't: see [Move an existing install](#move-an-existing-install).

### With docker compose

1. Create the databases and users, and check the [server requirements](#server-requirements).
1. For a new install, run `./prepare_environment.sh`, or set the variables in `.env` by hand. For an install that already runs, see [Move an existing install](#move-an-existing-install).
1. Start the stack, with `COMPOSE_FILE` as before:

   ```bash
   docker compose up -d
   ```

   `deploy.replicas` of the database services is `0`, so compose starts the migrations without waiting for them.

`docker compose ps` then shows no database container. To go back, set `SYNC_DB_CONTAINERS=1` and the default server names.

### With Quadlets

With `SYNC_DB_CONTAINERS=0`, `prepare_environment.sh` installs no `firefox-sync-syncstorage-db` or `firefox-sync-tokenserver-db` unit. With `FXA_DB_CONTAINERS=0`, no `firefox-sync-fxa-db` unit. It removes them from the other units' `After=` and `Requires=`.

The migrations retry until your server answers. A server on the same host is `host.containers.internal`, see [Server requirements](#server-requirements). Quadlets support MariaDB and MySQL only.

### With Helm

<!-- helm-fxa: accounts values go here -->

There is no `prepare_environment.sh` here: you fill in the SQL by hand.

1. Create the databases and users with [db/mysql/sync.sql](/db/mysql/sync.sql) or [db/postgres/sync.sql](/db/postgres/sync.sql). Replace each `@NAME@` with the names of the values below and your passwords:
    - `@ADMIN_DATABASE@`, `@ADMIN_USER@` and `@ADMIN_SYNC_USER@` are `database.admin.name`, `.user` and `.syncUser`.
    - `@ADMIN_PASSWORD@` is `ADMIN_DB_PASSWORD`, not the admin UI's sign-in password.

   Check the [server requirements](#server-requirements).
1. Create a Secret with those passwords and the stack's secrets: see [existingSecret](install/helm.md#existingsecret) for its keys per backend. The chart refuses to render without it.
1. Set the values:

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

Each value and its `.env` name: [Settings](reference/settings.md#your-own-database-server).

`database.external.tlsVerify` (MariaDB, MySQL) says whether the init container and the backups check the server's certificate. It is `false` by default: MySQL's own certificate is self-signed, and a managed service's CA is not in the images (`ERROR 2026`). Set `true` only with a certificate from a CA the images trust, for that host name.

The chart then has no database pods, volumes or Secret of its own. The Sync server's pod waits for your server in its `wait-db` init container, and stops in `migrate` while a login is refused:

```bash
kubectl logs deploy/<release>-firefox-sync-syncstorage -c migrate
```

To move a chart install with bundled databases to your server: dump it as in [Restore on Kubernetes](backups.md#restore-on-kubernetes), load the dumps as in [Move an existing install](#move-an-existing-install), and use the passwords of the chart's Secret in your SQL and your `existingSecret`.

## Move an existing install

From the stack's containers to your own server, with docker compose. Moving from another Sync server instead: see [Migrating](migrating.md).

Not covered by the tests: check the result before you remove the old volumes. Moving a Quadlet install is not described here: `prepare_environment.sh` writes these values into its units.

1. Keep your `.env`, and don't run `prepare_environment.sh` again. It would replace `.env` with new secrets and passwords. You change `.env` by hand in step 6.
1. Stop the stack, without `-v` (that deletes the volumes with your data):

   ```bash
   docker compose down
   ```

1. Start only the database containers: `postgres_db` instead with PostgreSQL, and `fxa-db` too with the accounts.

   ```bash
   docker compose up -d tokenserver_db syncstorage_db
   ```

1. Dump the data:
    - MariaDB, the same for `syncstorage_db`:

      ```bash
      docker compose exec tokenserver_db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --routines --triggers "$MARIADB_DATABASE"' > tokenserver.sql
      ```

      These dumps load into MariaDB 10.10 and later only: MySQL rejects their `uca1400` collations.
    - MySQL (`SYNC_DB=mysql`), the same for `syncstorage_db`. The stack's users have no `PROCESS` privilege, hence `--no-tablespaces`:

      ```bash
      docker compose exec tokenserver_db sh -c 'mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --routines --triggers --no-tablespaces "$MYSQL_DATABASE"' > tokenserver.sql
      ```

    - PostgreSQL, as the Sync server's role, like the backups:

      ```bash
      docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD="$POSTGRES_SYNC_PASSWORD" pg_dump -h "$POSTGRES_SERVER" -U "$POSTGRES_SYNC_USER" --no-owner --no-acl "$POSTGRES_DATABASE"' > syncserver.sql
      ```

      An install from before `SYNC_POSTGRES_APP_USER` runs its Sync server as the superuser anyway:

      ```bash
      docker compose exec postgres_db sh -c 'pg_dump -U "$POSTGRES_USER" --no-owner --no-acl "$POSTGRES_DB"' > syncserver.sql
      ```

    - The admin UI's database (the event log, the audit trail), as its user. Use `mysqldump ... --no-tablespaces` with `SYNC_DB=mysql`:

      ```bash
      docker compose exec tokenserver_db sh -c 'mariadb-dump -u"$ADMIN_DB_USER" -p"$ADMIN_DB_PASSWORD" --single-transaction "$ADMIN_DB_NAME"' > ffs_admin.sql
      docker compose exec postgres_db pg_dump -U ffs_admin_ui --no-owner --no-acl ffs_admin > ffs_admin.sql   # PostgreSQL
      ```

    - The accounts. Use `mariadb-dump` instead of `mysqldump` with `FXA_DB=mariadb`, and load it into the same kind of server (MySQL to MariaDB or back is not tested):

      ```bash
      docker compose exec fxa-db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --routines --triggers --databases fxa fxa_oauth fxa_profile pushbox ffs'  > fxa.sql
      ```

1. Create the databases and users on your server with the passwords already in your `.env`:
    1. Copy [db/mysql/sync.sql](/db/mysql/sync.sql), [db/postgres/sync.sql](/db/postgres/sync.sql) or `db/mysql/fxa-<FXA_DB>.sql`.
    1. Replace each `@NAME@` with its value from `.env`: `@SYNC_TOKENSERVER_PASSWORD@` is `SYNC_TOKENSERVER_DB_PASSWORD`, `@FXA_ADMIN_PASSWORD@` is `FXA_ADMIN_DB_PASSWORD`, and so on. Keep the database and user names of `.env`.
    1. For the accounts, add `FXA_MYSQL_USER`, `FXA_MYSQL_POLICY_USER` and `FXA_MYSQL_POLICY_PASSWORD` to `.env`: the containers used `root`.
    1. Run the SQL as in [Create the databases and users](#create-the-databases-and-users), then load the dumps:

       ```bash
       mariadb -h db.example.com -u root -p tokenserver < tokenserver.sql
       mariadb -h db.example.com -u root -p syncstorage < syncstorage.sql
       psql -h db.example.com -U syncserver -d syncserver -f syncserver.sql    # as the owner: its tables
       mariadb -h db.example.com -u ffs_admin_ui -p ffs_admin < ffs_admin.sql   # psql -U ffs_admin_ui -d ffs_admin -f ffs_admin.sql
       mysql -h db.example.com -u root -p < fxa.sql                             # mariadb with FXA_DB=mariadb
       ```

   The accounts' dump creates its databases itself. Its triggers, views and procedures name `root` as their definer. Before loading it, replace ``DEFINER=`root`@`%` `` with `FXA_MYSQL_POLICY_USER` for the `ffs` objects and the trigger on `fxa.accounts`, and with `FXA_MYSQL_USER` for Mozilla's procedures. Or let `fxa-policy` recreate its own objects at the next start.
1. In `.env`, set `SYNC_DB_CONTAINERS=0`, `SYNC_DB_TLS_VERIFY=false` and the `_HOST` and `_PORT` settings (`SYNC_TOKENSERVER_DB_HOST`, `SYNC_POSTGRES_HOST` and so on). For the accounts, also `FXA_DB_CONTAINERS=0`, `FXA_MYSQL_HOST`, `FXA_MYSQL_PORT` and the users of step 5.
1. Start the stack:

   ```bash
   docker compose up -d
   ```

The old volumes stay until you remove them, with `docker volume rm`, or `docker compose down -v` while `SYNC_DB_CONTAINERS=1`.

## Troubleshooting

Errors from the database, the init container and the accounts' migrations: see [Troubleshooting](troubleshooting.md#databases).
