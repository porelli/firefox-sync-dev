# Moving to firefox-sync from another Sync server

How to move from the other self-hosted Firefox Sync setups found on GitHub to this one. Each section says on its `Tested:` line whether and how it was tested. The database moves are tested by [`tests/migrate.sh`](tests/migrate.sh) `<scenario>`: an account of upstream's mock FxA writes its data through the old stack, the commands of this guide move it as written here, and the same account (same uid and keys) reads it back through firefox-sync, on the new node, with `MAX_USERS` and the admin UI counting it. The old stacks run in containers: their own compose files where they publish images, otherwise the same database server, names and schema. Keep the old server until every device syncs with the new one.

## Start fresh first

The Sync server keeps a copy of what your browsers already have, encrypted with keys derived from your account password. When Firefox finds an empty server for an account whose keys did not change, it uploads everything it has on its next sync. Other devices merge their own data in when they sync after it. So for every server that only does Sync (you sign in with Mozilla's accounts, or your accounts stay where they are), the simplest and safest way is to start fresh:

1. Set up firefox-sync ([README.md](README.md#server-setup)). Set `MAX_USERS` to at least the number of accounts that will use it.
1. Start with the device that has the most data, usually your main desktop:
    - if the address of the Sync server changes: disconnect Sync and choose to keep the data on the device (Firefox asks), set the new address ([Firefox setup](README.md#firefox-setup): `identity.sync.tokenserver.uri` on desktop, `Custom Sync server` on Android, `Custom Sync Token Server URI` on iOS), sign in again and sync
    - if you keep the same address (your reverse proxy now sends it to firefox-sync, see below): restart Firefox and use `Sync Now`. Firefox may use its token from the old server for up to an hour; disconnecting and signing in again switches it at once
1. Wait until that device has synced (`about:sync-log` on desktop, or the account's storage in the [admin UI](ADMIN.md)), then do the other devices one at a time.

The data kept only on the old server is lost: for example the data of a device you no longer have. If no device has everything, move the database instead: see the sections below for the setups where that works.

To keep the same address, the path must match too: firefox-sync's tokenserver is at `https://<host>/1.0/sync/1.5` and the storage at `https://<host>/1.5/<uid>`. With `SYNCSTORAGE_DOMAIN` set to the old host name, point the reverse proxy for that host to firefox-sync (`127.0.0.1:${CONTAINER_EXPORT_PORT}`, see [syncstorage-rs-example.conf](config/nginx/syncstorage-rs-example.conf)).

Rollback: stop the old stack (`docker compose stop`, not `down -v`) instead of removing it. Until all devices have synced with firefox-sync, going back is pointing the reverse proxy, or the Firefox setting, back to it and starting it.

Tested: not as a migration. It is what Firefox does with any new server: [`tests/test_fxa_browser.py`](tests/test_fxa_browser.py) syncs a real Firefox to an empty one.

## How to choose

| You run | Sync data | Accounts | Section |
|---|---|---|---|
| an older release of firefox-sync | upgrade in place | - | [Older firefox-sync releases](#older-firefox-sync-releases) |
| Mozilla's syncstorage-rs compose files | start fresh, or move the database | Mozilla's | [syncstorage-rs](#mozillas-syncstorage-rs-compose-files) |
| dan-r/syncstorage-rs-docker, MASH | start fresh, or move the database | Mozilla's | [dan-r](#dan-rsyncstorage-rs-docker-and-mash) |
| jeena/fxsync-docker | start fresh, or move the database | Mozilla's | [jeena](#jeenafxsync-docker) |
| NixOS `services.firefox-syncserver` | start fresh, or move the database | Mozilla's | [NixOS](#nixos-servicesfirefox-syncserver) |
| YunoHost `syncserver-rs` | start fresh, or move the database | Mozilla's | [YunoHost](#yunohost-syncserver-rs_ynh) |
| the Python syncserver (any image) | start fresh only | Mozilla's | [Python syncserver](#the-python-syncserver) |
| jackyzy823/fxa-selfhosting | start fresh only | must move | [fxa-selfhosting](#jackyzy823fxa-selfhosting) |

## Moving the database

This only works between syncstorage-rs servers (the Rust one) on the same kind of database, and only with the same accounts service. Then the accounts keep their Sync ids and their data, and Firefox goes on syncing without uploading everything again.

- **Same accounts service.** The tokenserver knows an account as `<fxa uid>@<FXA_EMAIL_DOMAIN>` in its `users` table, with the `generation`, `keys_changed_at` and `client_state` of the account's keys. With Mozilla's accounts that is `api.accounts.firefox.com` everywhere. A different `FXA_EMAIL_DOMAIN` makes every account a new one: then start fresh. Check the old `users` table (`SELECT DISTINCT email FROM users`): a configuration that sets no email domain gets syncstorage-rs' default, `api-accounts.stage.mozaws.net` (Mozilla's test servers), for example Mozilla's `docker-compose.mysql.yaml` and `docker-compose.postgres.yaml` as they are. Loaded with `FXA_EMAIL_DOMAIN=api.accounts.firefox.com`, such accounts are not found: the tokenserver makes new, empty ones, and `MAX_USERS`, counting the old ones too, refuses them.
- **Same kind of database.**
    - MariaDB or MySQL to firefox-sync's MariaDB (the default): supported. Dumps of MySQL 8 use the `utf8mb4_0900_ai_ci` collation, which MariaDB knows from 11.4.5 on (the stack runs `mariadb:lts`, newer than that). Tested from MySQL 8.0, MariaDB 10.6, 10.11 and 11.4 into `mariadb:lts` (12.3 at the time).
    - To firefox-sync on MySQL (`SYNC_DB=mysql`): only dumps from MySQL, or from MariaDB before 11. MariaDB 11 and newer write `uca1400` collations that MySQL rejects. Tested from MySQL 8.0 into MySQL 8.4; dumps of MariaDB into MySQL were not tested.
    - PostgreSQL to firefox-sync's PostgreSQL: supported. Tested from PostgreSQL 15, 17 and 18 into 18.
    - MySQL or MariaDB to PostgreSQL, or back: not a plain dump, not supported. Start fresh.
- **Whole databases**, including `__diesel_schema_migrations`: it tells syncstorage-rs which migrations already ran. firefox-sync runs the newest syncstorage-rs, so it applies the migrations the old server did not have yet. Going back to an older version afterwards is not possible.
- **Into empty databases, before firefox-sync's first start.** At the start, syncstorage-rs adds the node for `SYNCSTORAGE_DOMAIN` if it is missing, then the init container moves every account to that node and takes the old nodes out ([db_init.sql](syncstorage-rs-init/db_init.sql), [PostgreSQL](syncstorage-rs-init-postgres/db_init.sql)). So the old node URL does not need to be changed by hand.
- **`MAX_USERS` at least the number of accounts.** Accounts that are already in the database always get in, but with fewer seats than accounts, new ones are refused.
- `SYNC_MASTER_SECRET` and `METRICS_HASH_SECRET` don't need to be the old ones: Firefox gets a new token when the old one is refused. (The tests use new ones: the accounts sign in again and find their data. That Firefox asks for a new token by itself was not tested.)

### Loading into firefox-sync

1. Set up firefox-sync with `./prepare_environment.sh` (MariaDB or PostgreSQL, as the old server), but don't run `docker compose up -d` yet. New volumes are empty.
1. Stop the old server, except its database, so that nothing changes during the dump. Make the dumps (see each section): `tokenserver.sql` and `syncstorage.sql` for MariaDB/MySQL, `syncserver.sql` (or three files) for PostgreSQL.
1. Start only the database containers and load the dumps:
    ```bash
    # MariaDB (docker-compose.yml)
    docker compose up -d --wait tokenserver_db syncstorage_db
    docker compose exec -T tokenserver_db sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' < tokenserver.sql
    docker compose exec -T syncstorage_db sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' < syncstorage.sql

    # MySQL (SYNC_DB=mysql, docker-compose.sync-mysql.yml): the same, with the MySQL client
    docker compose up -d --wait tokenserver_db syncstorage_db
    docker compose exec -T tokenserver_db sh -c 'mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' < tokenserver.sql
    docker compose exec -T syncstorage_db sh -c 'mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' < syncstorage.sql

    # PostgreSQL (COMPOSE_FILE=docker-compose.postgres.yml)
    docker compose up -d --wait postgres_db
    docker compose exec -T postgres_db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < syncserver.sql
    ```
    With Quadlets (MariaDB only, not tested): `systemctl --user start firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service`, then the same with `podman exec -i firefox-sync-tokenserver-db sh -c '...' < tokenserver.sql` and `firefox-sync-syncstorage-db`, then start `firefox-sync-syncstorage.service`.
    With [your own database server](DATABASES.md), load them with `mariadb`/`psql` as in [Moving an existing install](DATABASES.md#moving-an-existing-install) (not tested).
1. `docker compose up -d`.
1. Point your reverse proxy, or Firefox, to firefox-sync, as in [Start fresh](#start-fresh-first). Firefox does not need to sign out: on its next token it is sent to the new node and finds its data there.

### Checking the result

- `docker compose logs tokenserver_db_init` shows `Current users: N`, the number of accounts of the old server.
- The [admin UI](ADMIN.md) (`COMPOSE_PROFILES=admin`) lists the accounts on its first page, with what each stores.
- In the tokenserver database every current account points to the new node:
    ```bash
    docker compose exec tokenserver_db sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL"'
    # MySQL (SYNC_DB=mysql)
    docker compose exec tokenserver_db sh -c 'mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL"'
    # PostgreSQL
    docker compose exec postgres_db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL"'
    ```
- On desktop, `about:sync-log` shows syncs without errors, and a new profile signed in to the same account gets the bookmarks without any other device uploading them first.

Rollback: as in [Start fresh](#start-fresh-first). What was synced to firefox-sync in the meantime is not on the old server, but the devices still have it and upload it again.

Tested: the steps above (Docker compose, not Quadlets nor your own database server) in every scenario of the sections below; `tests/migrate.sh` runs the commands of this section and of "Checking the result" as written, with the admin UI on. Not tested with a real Firefox: the client is upstream's test client, signing in like Firefox does after a sign-in.

## Older firefox-sync releases

The same stack: upgrade in place, nothing to export. The volumes (`<directory>_tokenserver-db`, `<directory>_syncstorage-db`) keep their names as long as you run compose from the same directory.

With docker compose:

1. Back up the volumes, or dump the databases (see [Moving an existing install](DATABASES.md#moving-an-existing-install)).
1. Get the new files (`git pull` in the clone). Keep your `.env`: don't run `./prepare_environment.sh` again, it would generate new passwords that the databases don't have.
1. Add the lines of [.env-example](.env-example) that your `.env` lacks, with their default values, and change none of yours:
    - releases from before December 2024 have no `MARIADB_TOKENSERVER_SERVER`, `_SERVER_PORT`, `_DATABASE` (and the same for `SYNCSTORAGE`), `REPOSITORY`, `SYNCSTORAGE_IMAGE*`, `FXA_EMAIL_DOMAIN` and `FXA_OAUTH_SERVER_URL`: copy them from `.env-example`
    - the first release (July 2024) had one `MARIADB_USER` and `MARIADB_PASSWORD` for both databases, and no `MAX_USERS`: set `MARIADB_TOKENSERVER_USER` and `MARIADB_SYNCSTORAGE_USER` to that user, `MARIADB_TOKENSERVER_PASSWORD` and `MARIADB_SYNCSTORAGE_PASSWORD` to that password, and `MAX_USERS` to at least the number of accounts
1. `docker compose pull && docker compose up -d`. `MAX_USERS=N` works as before (set at every start); `MAX_USERS=initial:N` lets the admin UI manage it ([ADMIN.md](ADMIN.md#max-users)).

With Quadlets (since November 2025): the passwords are written into the units by `prepare_environment.sh`. Run it again with the same answers (keep a copy of the old `.env`), then, before starting the Sync server, give the database users the new passwords: `systemctl --user start firefox-sync-tokenserver-db.service`, `podman exec firefox-sync-tokenserver-db mariadb -u<MARIADB_TOKENSERVER_USER> -p'<old password>' -e "SET PASSWORD = PASSWORD('<new MARIADB_TOKENSERVER_PASSWORD>')"`, the same for `firefox-sync-syncstorage-db`, then `systemctl --user start firefox-sync-syncstorage.service`.

Firefox: nothing to change. Rollback: the old files and images (pin `SYNCSTORAGE_IMAGE_TAG` and `SYNCSTORAGE_INIT_IMAGE_TAG` to the old tags) with the backup of the volumes: the migrations of the newer syncstorage-rs cannot be undone.

Tested: docker compose, `tests/migrate.sh firefox-sync-2024-12` (4705bda, images 0.18.2) and `firefox-sync-2024-07` (the first release, 7f52fa0, image 0.17.1): the old release's files and `.env`, an account syncs, then the new files over them, the missing lines of `.env-example` added as above, `docker compose pull && docker compose up -d`: same volumes, same accounts on the same node with their data, `MAX_USERS` and the admin UI count them. Not tested: the Quadlets path, the backup and the rollback.

## Mozilla's syncstorage-rs compose files

[mozilla-services/syncstorage-rs](https://github.com/mozilla-services/syncstorage-rs) ships [docker/docker-compose.one-shot.mysql.yaml](https://github.com/mozilla-services/syncstorage-rs/blob/master/docker/docker-compose.one-shot.mysql.yaml) and [docker-compose.one-shot.postgres.yaml](https://github.com/mozilla-services/syncstorage-rs/blob/master/docker/docker-compose.one-shot.postgres.yaml) (images `ghcr.io/mozilla-services/syncstorage-rs/syncserver-mysql` and `syncserver-postgres`). [docker-compose.mysql.yaml](https://github.com/mozilla-services/syncstorage-rs/blob/master/docker/docker-compose.mysql.yaml) and [docker-compose.postgres.yaml](https://github.com/mozilla-services/syncstorage-rs/blob/master/docker/docker-compose.postgres.yaml) are its end-to-end test setup, which some people run too.

| File | Database | Databases, user |
|---|---|---|
| `docker-compose.one-shot.mysql.yaml` | MySQL 8.0, containers `syncserver-tokenserver-db` and `syncserver-sync-db` | `tokenserver`, `syncstorage`, user `sync` / `sync` |
| `docker-compose.one-shot.postgres.yaml` | PostgreSQL 18, container `syncserver-postgres` | one database `syncserver`, user `sync` / `sync` (the same layout as firefox-sync) |
| `docker-compose.mysql.yaml` | MySQL 8.0, services `tokenserver-db` and `sync-db` | `tokenserver`, `syncstorage`, user `test` / `test` |
| `docker-compose.postgres.yaml` | PostgreSQL 18, services `tokenserver-db` and `sync-db` | `tokenserver`, `syncstorage`, user `test` / `test` |

Recommended: start fresh. The database path is supported. Its node is `SYNC_TOKENSERVER__INIT_NODE_URL` (`http://localhost:8000` by default); firefox-sync moves the accounts to its own.

Dumps (use the users and passwords of your files; with your own changes the names may differ):

```bash
# MySQL, one-shot file
docker exec syncserver-tokenserver-db mysqldump -usync -psync --single-transaction --no-tablespaces --set-gtid-purged=OFF tokenserver > tokenserver.sql
docker exec syncserver-sync-db mysqldump -usync -psync --single-transaction --no-tablespaces --set-gtid-purged=OFF syncstorage > syncstorage.sql

# MySQL, the test setup (from the directory of your checkout)
dc="docker compose -f docker/docker-compose.mysql.yaml exec -T"
$dc tokenserver-db mysqldump -utest -ptest --single-transaction --no-tablespaces --set-gtid-purged=OFF tokenserver > tokenserver.sql
$dc sync-db mysqldump -utest -ptest --single-transaction --no-tablespaces --set-gtid-purged=OFF syncstorage > syncstorage.sql

# PostgreSQL, one-shot file: one database, like firefox-sync
docker exec syncserver-postgres pg_dump -U sync --no-owner --no-acl syncserver > syncserver.sql
```

PostgreSQL with two databases (the test setup) into firefox-sync's one: both have a `__diesel_schema_migrations` table, with different rows. Dump the tokenserver whole, the storage without that table, then its rows only, and load the three files in this order:

```bash
dc="docker compose -f docker/docker-compose.postgres.yaml exec -T"
$dc tokenserver-db pg_dump -U test --no-owner --no-acl tokenserver > syncserver.sql
$dc sync-db pg_dump -U test --no-owner --no-acl --exclude-table=__diesel_schema_migrations syncstorage > syncstorage.sql
$dc sync-db pg_dump -U test --data-only --table=__diesel_schema_migrations syncstorage > syncstorage-migrations.sql
# then, in firefox-sync, as in "Loading into firefox-sync", with each file in turn:
# docker compose exec -T postgres_db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < <file>
```

Then [Loading into firefox-sync](#loading-into-firefox-sync). Firefox: the same `.../1.0/sync/1.5` path, so with the same host name nothing changes on the devices.

Tested: with the files of syncstorage-rs master (530d0f0) and the published 0.23.3 images, `tests/migrate.sh upstream-mysql` (one-shot MySQL to firefox-sync's MariaDB), `upstream-mysql-to-mysql` (the same to `SYNC_DB=mysql`), `upstream-mysql-testsetup` (`docker-compose.mysql.yaml`), `upstream-postgres` (one-shot PostgreSQL) and `upstream-postgres-2db` (`docker-compose.postgres.yaml`, the three files). The test files got a node URL, the tokenserver and `api.accounts.firefox.com` as email domain (see [Moving the database](#moving-the-database)).

## dan-r/syncstorage-rs-docker (and MASH)

[dan-r/syncstorage-rs-docker](https://github.com/dan-r/syncstorage-rs-docker) ([docker-compose.yaml](https://github.com/dan-r/syncstorage-rs-docker/blob/main/docker-compose.yaml), [entrypoint.sh](https://github.com/dan-r/syncstorage-rs-docker/blob/main/app/entrypoint.sh), [init.sql](https://github.com/dan-r/syncstorage-rs-docker/blob/main/data/initdb.d/init.sql)): one `linuxserver/mariadb:10.6.13` container `firefox_mariadb` with data in `./data/config`, the databases `syncstorage_rs` and `tokenserver_rs`, user `sync`, and syncstorage-rs built from a pinned commit of June 2025. Its entrypoint sets node 1 to `SYNC_URL`, and `SYNC_CAPACITY` limits the accounts. The [MASH playbook](https://github.com/mother-of-all-self-hosting/mash-playbook) installs a fork of it ([ansible-role-syncstorage-rs-docker](https://github.com/mother-of-all-self-hosting/ansible-role-syncstorage-rs-docker)) with the same database names on its MySQL/MariaDB server.

Recommended: start fresh. The database path is supported (MariaDB 10.6 into MariaDB):

```bash
docker exec firefox_mariadb sh -c 'mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --no-tablespaces tokenserver_rs' > tokenserver.sql
docker exec firefox_mariadb sh -c 'mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --no-tablespaces syncstorage_rs' > syncstorage.sql
```

(With MASH, run it against the server of `syncstorage_rs_docker_database_mysql_hostname`, with `mysqldump` if that is MySQL.) Then [Loading into firefox-sync](#loading-into-firefox-sync), with `MAX_USERS` at least the accounts you had (`SYNC_CAPACITY`). Firefox: `SYNC_URL/1.0/sync/1.5`, the same path as firefox-sync.

Tested: `tests/migrate.sh dan-r`, its layout rather than its image (which builds from source): `linuxserver/mariadb:10.6.13` as `firefox_mariadb` with its `init.sql`, syncstorage-rs 0.18.3 (its pinned commit is 0.18.3 and 8 commits without migrations), the services and nodes rows of its entrypoint, then the commands above. firefox-sync then adds the newer migrations. MASH: not tested.

## jeena/fxsync-docker

[jeena/fxsync-docker](https://github.com/jeena/fxsync-docker), archived on GitHub (moved to [git.jeena.net](https://git.jeena.net/jeena/fxsync-docker)), the inspiration of this project: [docker-compose.yaml](https://github.com/jeena/fxsync-docker/blob/main/docker-compose.yaml) runs `mozilla/syncstorage-rs:0.13.6` with two `mariadb:10.11` containers, `firefox_tokenserver_db` (`tokenserver`) and `firefox_syncstorage_db` (`syncstorage`), one user `MARIADB_USER` for both, and node 1 set to `DOMAIN`.

Recommended: start fresh. The database path is supported:

```bash
docker exec firefox_tokenserver_db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction --no-tablespaces tokenserver' > tokenserver.sql
docker exec firefox_syncstorage_db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction --no-tablespaces syncstorage' > syncstorage.sql
```

Then [Loading into firefox-sync](#loading-into-firefox-sync). syncstorage-rs 0.13.6 is old: firefox-sync runs the migrations added since. Firefox: the same path.

Tested: `tests/migrate.sh jeena`, its `docker-compose.yaml` as it is (`mozilla/syncstorage-rs:0.13.6`, `mariadb:10.11`, its init container), changed only for the test: the mock as accounts server, no published port.

## NixOS services.firefox-syncserver

The NixOS module ([firefox-syncserver.nix](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/firefox-syncserver.nix)) runs syncstorage-rs with one database for the tokenserver and the storage, `firefox_syncserver` by default (`services.firefox-syncserver.database.name`), on the local `services.mysql` server (MariaDB or MySQL, `database.type = "mysql"`) or on PostgreSQL (`database.type = "postgresql"`). With `singleNode.enable` it sets node 1 to `singleNode.url` and its capacity.

Recommended: start fresh. The database path is supported. On the NixOS host, as root:

```bash
# MariaDB: one database, split into firefox-sync's two (the migrations table goes into both)
sudo mariadb-dump --single-transaction --no-tablespaces firefox_syncserver users nodes services __diesel_schema_migrations > tokenserver.sql
sudo mariadb-dump --single-transaction --no-tablespaces firefox_syncserver bso collections user_collections batch_uploads batch_upload_items __diesel_schema_migrations > syncstorage.sql
# MySQL (services.mysql.package = pkgs.mysql80 or newer): the same with mysqldump instead of mariadb-dump

# PostgreSQL: one database, like firefox-sync
sudo -u postgres pg_dump --no-owner --no-acl firefox_syncserver > syncserver.sql
```

Then [Loading into firefox-sync](#loading-into-firefox-sync), and `services.firefox-syncserver.enable = false` once all devices synced. Firefox: the same path.

Tested: the module's layout in containers, not on NixOS: one database `firefox_syncserver` for syncstorage-rs 0.23.3, `tests/migrate.sh nixos-mysql` (MariaDB 11.4, whose image has `mariadb-dump` but no `mysqldump`; the table lists are all its tables) and `nixos-postgres` (PostgreSQL 17), the commands above run as root in the database container. MySQL with `mysqldump`: not tested.

## YunoHost syncserver-rs_ynh

[YunoHost-Apps/syncserver-rs_ynh](https://github.com/YunoHost-Apps/syncserver-rs_ynh) builds syncstorage-rs on the YunoHost server. Since `0.23.3~ynh9` it uses PostgreSQL with two databases, `syncserver_rs` (storage) and `syncserver_rs_tokenserver` ([config.toml](https://github.com/YunoHost-Apps/syncserver-rs_ynh/blob/master/conf/config.toml), [install](https://github.com/YunoHost-Apps/syncserver-rs_ynh/blob/master/scripts/install)). Before that it used MariaDB, and that upgrade did not copy the data: the clients uploaded it again. MariaDB databases of the same names left from then are old.

Recommended: start fresh. The database path is supported, into firefox-sync's PostgreSQL. As root on the YunoHost server:

```bash
sudo -u postgres pg_dump --no-owner --no-acl syncserver_rs_tokenserver > syncserver.sql
sudo -u postgres pg_dump --no-owner --no-acl --exclude-table=__diesel_schema_migrations syncserver_rs > syncstorage.sql
sudo -u postgres pg_dump --data-only --table=__diesel_schema_migrations syncserver_rs > syncstorage-migrations.sql
```

Load the three files in this order, as for [the two-database PostgreSQL](#mozillas-syncstorage-rs-compose-files), then [Loading into firefox-sync](#loading-into-firefox-sync). Firefox: YunoHost's address is `https://<domain><path>/1.0/sync/1.5`; with a path, change the setting on the devices (or rewrite the path in your reverse proxy). Remove the app once all devices synced.

Tested: the app's layout in containers, not on YunoHost: `tests/migrate.sh yunohost`, syncstorage-rs 0.23.3 on PostgreSQL 15 (bookworm's) with the two databases of one owner, the commands above run as `postgres` in the database container. The path rewrite and the MariaDB databases of before `0.23.3~ynh9`: not tested.

## The Python syncserver

[mozilla-services/syncserver](https://github.com/mozilla-services/syncserver), archived by Mozilla in 2023 and replaced by syncstorage-rs, and the images built on it: [crazy-max/docker-firefox-syncserver](https://github.com/crazy-max/docker-firefox-syncserver) (archived), [snw35/ffsync](https://github.com/snw35/ffsync), `mozilla/syncserver`. It keeps the tokenserver and the storage in one SQLAlchemy database (`syncserver.sqluri`: SQLite `syncserver.db` by default, or MySQL or PostgreSQL) with its own schema (other tables and columns, its own tokenserver), which syncstorage-rs does not read.

Recommended: start fresh only. Its address is `https://<host>/token/1.0/sync/1.5`: change the setting on the devices to firefox-sync's `.../1.0/sync/1.5`, or keep the host name and have your reverse proxy send `/token/` to firefox-sync without the prefix (`location /token/ { proxy_pass http://127.0.0.1:5000/; }` in nginx).

Tested: no.

## jackyzy823/fxa-selfhosting

[jackyzy823/fxa-selfhosting](https://github.com/jackyzy823/fxa-selfhosting) runs Mozilla accounts and the Python syncserver, from [docker-compose.tmpl.yml](https://github.com/jackyzy823/fxa-selfhosting/blob/master/docker-compose.tmpl.yml) and your `config.yml` ([config.yml.sample](https://github.com/jackyzy823/fxa-selfhosting/blob/master/config.yml.sample)):

- one MySQL 8.4 container `mysqldb`, user `root` without a password, data in `<persistencepath>/mysql_data`: the accounts in `fxa`, `fxa_oauth`, `fxa_profile` and `pushbox` (created by Mozilla's `patcher.mjs`, like here), the Python syncserver in `sync`
- `fxa_version` in `config.yml` (`v1.342.2` in the sample): the release of `mozilla/fxa-mono`
- the keys are generated inside the `fxa-auth-server` container at every start when missing, in `/fxa/packages/fxa-auth-server/dist/packages/fxa-auth-server/config/`: `secret-key.json`, `public-key.json`, `vapid-keys.json`, `key.json` (and `newKey.json`, `oldKey.json` after a key rotation). There is no volume for them: a new container gets new keys
- avatars in `<persistencepath>/public`
- host names `<content>`, `<auth>`, `<oauth>`, `<profile>`, `<sync>` of `domain.name` (`www`, `api`, `oauth`, `profile`, `token` in the sample): the accounts API and OAuth on two host names (here one, `FXA_AUTH_URL`), Sync at `https://token.<domain>/token/1.0/sync/1.5`

The accounts must move: an account is the record in `fxa.accounts`, and its Sync keys are derived from its password and that record. New accounts, even with the same email and password, have new keys, and every device would have to sign up again. The Sync data cannot move (Python syncserver): start fresh for it, after the accounts moved. None of this has been tested.

1. Check the versions: firefox-sync runs the newest accounts release it tested (`FXA_VERSION=fxa-mono-latest`). It must be the same as `fxa_version` or newer: the migrations only go forward. If yours is newer, pin `FXA_VERSION` to a release at least as new (`fxa-mono-<release>`, see [FXA.md](FXA.md#upgrades)).
1. Set up firefox-sync with self-hosted accounts on MySQL (`./prepare_environment.sh`, [FXA.md](FXA.md#setup)), don't start it. Then in `.env`, keep the old public URLs: `FXA_CONTENT_URL=https://<content>.<domain>`, `FXA_AUTH_URL=https://<auth>.<domain>`, `FXA_PROFILE_URL=https://<profile>.<domain>`, `FXA_EMAIL_DOMAIN=<auth>.<domain>`. Set `FXA_OAUTH_SECRET` and `FXA_AUTH_SECRET` to `secrets.authsecret` and `FXA_PROFILE_SECRET` to `secrets.profileserver_authsecret_bearertoken` of `config.yml`. That may not be needed, but it is the safe side. If they are still the sample values, use new ones and expect to sign in again everywhere. `SYNCSTORAGE_DOMAIN` can be `https://<sync>.<domain>`.
1. On the old server, stop everything but the database, dump the accounts and copy the keys:
    ```bash
    docker compose stop && docker compose start mysqldb
    docker compose exec -T mysqldb mysqldump -uroot --single-transaction --set-gtid-purged=OFF --routines --triggers \
      --databases fxa fxa_oauth fxa_profile pushbox > fxa.sql
    mkdir old-keys
    for f in secret-key.json public-key.json vapid-keys.json key.json newKey.json oldKey.json; do
      docker compose cp fxa-auth-server:/fxa/packages/fxa-auth-server/dist/packages/fxa-auth-server/config/$f old-keys/
    done   # newKey.json and oldKey.json are often missing; without the old container, skip this
    ```
1. In firefox-sync, load the dump into the new, empty `fxa-db`, then the keys into the `fxa-keys` volume and the avatars, all before the accounts start:
    ```bash
    docker compose up -d --wait fxa-db
    docker compose exec -T fxa-db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < fxa.sql
    docker compose run --rm --no-deps -v "$PWD/old-keys:/old:ro" fxa-keys-owner sh -c '
      cp /old/secret-key.json /old/public-key.json /old/vapid-keys.json /fxa-keys/ &&
      cp /old/key.json /fxa-keys/openid-key.json &&
      { [ ! -f /old/newKey.json ] || cp /old/newKey.json /fxa-keys/openid-newKey.json; } &&
      { [ ! -f /old/oldKey.json ] || cp /old/oldKey.json /fxa-keys/openid-oldKey.json; } &&
      chown 10001:10001 /fxa-keys/*.json'
    docker compose run --rm --no-deps --user root -v /path/to/old/public:/old:ro fxa-profile-worker sh -c '
      cp -a /old/. /fxa/packages/fxa-profile-server/var/public/ && chown -R 10001:10001 /fxa/packages/fxa-profile-server/var/public'
    docker compose up -d
    ```
    The names come from [docker-compose.fxa.yml](docker-compose.fxa.yml) (`SECRET_KEY_FILE`, `PUBLIC_KEY_FILE`, `VAPID_KEYS_FILE`, `FXA_OPENID_KEYFILE`, `FXA_OPENID_NEWKEYFILE`, `FXA_OPENID_OLDKEYFILE`). `fxa-migrations` then upgrades the schema, `fxa-policy` installs the [sign-up policy](ADMIN.md#who-can-sign-up-self-hosted-accounts), and the OAuth clients are registered again for `FXA_CONTENT_URL`. Leave out `sync` (the Python syncserver) and `ffs`. Loading into MariaDB (`FXA_DB=mariadb`) is not covered: keep MySQL.
1. Reverse proxy ([fxa-example.conf](config/nginx/fxa-example.conf)): the content, auth and profile host names to the new ports, and also `<oauth>.<domain>` to `FXA_AUTH_EXPORT_PORT`, because Firefox keeps the OAuth address it read when it signed in. For Sync, either keep `https://<sync>.<domain>` with `/token/` sent to firefox-sync without the prefix (`location /token/ { proxy_pass http://127.0.0.1:5000/; }`) and the rest to firefox-sync as it is, or change the devices (next step).
1. Firefox: the accounts address (`identity.fxaccounts.autoconfig.uri`, Android `Custom Mozilla account server`, iOS `Custom Account Content Server URI`) stays the same. With the `/token/` rewrite, the devices stay signed in and upload their data to the empty Sync server. Without it, sign out on each device (keeping the data), restart Firefox and sign in again with the same email and password: Firefox reads the addresses again from the accounts server. On Android also set `Custom Sync server` to `SYNCSTORAGE_DOMAIN/1.0/sync/1.5`. Start with the device that has the most data, as in [Start fresh](#start-fresh-first).

Checking: the [admin UI](ADMIN.md) lists the old accounts with their emails, `docker compose exec fxa-db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM fxa.accounts"'` gives their number, and an existing account signed in on a new profile gets the bookmarks of its other devices: its keys did not change.

Rollback: stop firefox-sync, start the old stack and point the reverse proxy back. Accounts created and passwords changed in the meantime are not on the old server.

Tested: no.

## Other setups

Helm charts (for example [holysoles/fx-syncstorage-chart](https://github.com/holysoles/fx-syncstorage-chart), MySQL), the Home Assistant add-on [Aghabeiki/firefox-sync-addon](https://github.com/Aghabeiki/firefox-sync-addon) (MariaDB) and other packagings of syncstorage-rs work the same way: find the database type and the database names in their configuration (`SYNC_SYNCSTORAGE__DATABASE_URL` and `SYNC_TOKENSERVER__DATABASE_URL`, or `syncstorage.database_url` and `tokenserver.database_url`), then start fresh, or dump as in [Moving the database](#moving-the-database). One database for both is split as for [NixOS](#nixos-servicesfirefox-syncserver) (MySQL/MariaDB) or loaded as it is (PostgreSQL).

Tested: no.
