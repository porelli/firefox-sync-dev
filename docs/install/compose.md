# Install with docker compose

This page installs the Sync server with docker compose. Read [What you need](../README.md#what-you-need) first. With Podman, see [Podman](podman.md) instead.

## Requirements

- Docker with the compose plugin 2.21 or later ([install](https://docs.docker.com/engine/install/)): `docker compose version`.
- A host name with HTTPS, proxied to the port of the Sync server: see [Reverse proxy](../reverse-proxy.md).

## Install

1. Clone the repository:

   ```bash
   git clone https://github.com/porelli/firefox-sync.git
   cd firefox-sync
   ```

1. Run the setup script:

   ```bash
   ./prepare_environment.sh
   ```

   It asks its questions, then writes `.env` and the examples of `config/nginx/` with your values. See [What the setup script asks](#what-the-setup-script-asks).

1. Set up your reverse proxy. With nginx, start from `config/nginx/syncstorage-rs.conf`, which the script wrote: see [Reverse proxy](../reverse-proxy.md).

1. Check the optional services before the first start: the admin UI, the nightly backups and, with self-hosted accounts, your own pairing server. The script asked for each and listed those you chose in `COMPOSE_PROFILES` of `.env`. Only those start: to add or remove one, see [Optional services](#optional-services).

1. Start the stack:

   ```bash
   docker compose up -d
   ```

   The databases start first, then the migrations, then the init container that sets the limit of users. The Sync server starts last, so that nobody signs in before the limit exists.

1. Check that the init container ran:

   ```bash
   docker compose logs tokenserver_db_init
   ```

   Its last line is `Current users: N`.

1. [Set up Firefox](../firefox.md).

## What the setup script asks

| Question | What it changes | More |
|---|---|---|
| the host name of the Sync server | `SYNC_PUBLIC_URL` | [Reverse proxy](../reverse-proxy.md#host-names-and-ports) |
| where the Sync server listens, `127.0.0.1:5000` | `SYNC_EXPORT_PORT` | [Reverse proxy](../reverse-proxy.md#host-names-and-ports) |
| max users | `SYNC_MAX_USERS` | [Limits](../limits.md) |
| the database backend: `mariadb`, `mysql` or `postgres` | `SYNC_DB`, and its file in `COMPOSE_FILE` | [Databases](../databases.md) |
| an existing database server instead of the containers | `SYNC_DB_CONTAINERS=0`, and a `database-setup.sql` to run there | [Your own server](../databases.md#with-docker-compose) |
| the image tag of the Sync server | `SYNC_IMAGE_TAG` (`latest`) | [Upgrading](../upgrading.md#sync-server) |
| the admin UI | `admin` in `COMPOSE_PROFILES`, `ADMIN_PASSWORD` | [Admin UI](../admin/README.md#set-up) |
| self-hosted Mozilla accounts | the accounts' section of `.env`, `config/nginx/fxa.conf` | [Self-hosted accounts](../accounts.md#set-up) |
| the nightly backups | `backup` in `COMPOSE_PROFILES` (Quadlets: the backup timer enabled) | [Backups](../backups.md#the-backup-service) |
| with self-hosted accounts, your own pairing server (not with Quadlets) | `pairing` in `COMPOSE_PROFILES`, `FXA_PAIRING_URL=wss://pairing.<accounts domain>`, its server block in `config/nginx/fxa.conf` | [Pairing](../reverse-proxy.md#pairing) |

Every setting is in [Settings](../reference/settings.md). Coming from another Sync server: read [Migrating](../migrating.md) before you run the script.

`COMPOSE_FILE` in `.env` names the compose files of your choices, so a plain `docker compose` always picks the right ones: see [The compose files](#the-compose-files).

`COMPOSE_PROFILES` gets every optional service you chose, for example `COMPOSE_PROFILES=admin,backup`. Run again on an install, the script offers what its `.env` has as the answer to each of them.

## Optional services

They are compose profiles. `COMPOSE_PROFILES` in `.env` is the whole list of the profiles that run, comma-separated, without spaces: `COMPOSE_PROFILES=admin,backup` runs the admin UI and the backups. Commented out or empty, none runs.

| Profile | What it adds | Its services |
|---|---|---|
| `admin` | the [admin UI](../admin/README.md) | `ffs-admin` |
| `backup` | the nightly [backups](../backups.md#the-backup-service) | `backup`, and `backup-fxa` with self-hosted accounts |
| `pairing` | your own pairing server for [self-hosted accounts](../reverse-proxy.md#pairing) | `fxa-pairing` |

`pairing` is a service of `compose/fxa.yml`: it needs that file in `COMPOSE_FILE`, which the script sets when you self-host the accounts. Without it compose has no such service and starts nothing for it.

To turn one on, add it to the list and run `docker compose up -d`.

To turn one off, remove it from the list, then remove its containers: `docker compose up -d` leaves a service of a profile that is off running, and so does `--remove-orphans`. For example, for the backups:

```bash
docker compose rm -sf backup        # with self-hosted accounts: backup backup-fxa
```

## The compose files

They are in [compose/](/compose). An install has `compose/sync.yml`, exactly one file of the Sync database, and with self-hosted accounts `compose/fxa.yml` and exactly one file of their database. Each database file adds its containers, volumes and backup client, and what the other services need of it. The files of one database do not build on another's.

| File | What it has |
|---|---|
| [compose/sync.yml](/compose/sync.yml) | the Sync server, its migrations, the init container, the admin UI and the backups, without a database |
| [compose/sync-mariadb.yml](/compose/sync-mariadb.yml) | Sync on MariaDB (`SYNC_DB=mariadb`): `tokenserver_db`, `syncstorage_db` |
| [compose/sync-mysql.yml](/compose/sync-mysql.yml) | Sync on MySQL (`SYNC_DB=mysql`): the same services, MySQL's images and volumes |
| [compose/sync-postgres.yml](/compose/sync-postgres.yml) | Sync on PostgreSQL (the `syncstorage-rs-postgres` images): `postgres_db`, and `sync_role_init`, the Sync server's own role |
| [compose/fxa.yml](/compose/fxa.yml) | the self-hosted accounts, without their database |
| [compose/fxa-mysql.yml](/compose/fxa-mysql.yml) | the accounts on MySQL (`FXA_DB=mysql`): `fxa-db` |
| [compose/fxa-mariadb.yml](/compose/fxa-mariadb.yml) | the accounts on MariaDB (`FXA_DB=mariadb`): `fxa-db` |
| [compose/podman.yml](/compose/podman.yml) | docker compose on the Podman socket, see [Podman](podman.md) |

For example, Sync on PostgreSQL with the accounts on MySQL:

```bash
COMPOSE_FILE=compose/sync.yml:compose/sync-postgres.yml:compose/fxa.yml:compose/fxa-mysql.yml
COMPOSE_PROJECT_NAME=firefox-sync
```

`prepare_environment.sh` writes both lines. With your own database server (`SYNC_DB_CONTAINERS=0`, `FXA_DB_CONTAINERS=0`) the files are the same: the database services then run no container. With your own MySQL server for Sync, the script writes `compose/sync-mariadb.yml`, whose backups use the MariaDB client.

Compose takes the directory of the first file as the project's directory:

- `COMPOSE_PROJECT_NAME` keeps the project, and so the names of the containers and volumes, that of the directory of the checkout. Without it compose would name the project `compose`, and find none of them. A copy of the checkout, or a second stack, needs a name of its own (`COMPOSE_PROJECT_NAME` in [Settings](../reference/settings.md#sync)).
- Relative paths in compose files, also in your own files in `COMPOSE_FILE`, are relative to `compose/`: `../config/` is the checkout's `config/`.
- With `-f` instead of `COMPOSE_FILE`, add `--env-file .env`: compose looks for `.env` in `compose/` otherwise, and stops (`required variable SYNC_MASTER_SECRET is missing a value`).

`docker-compose.yml` at the top is only for the installs from before `compose/` that never set `COMPOSE_FILE`: it runs `compose/sync.yml` and `compose/sync-mariadb.yml` ([Files that moved](../upgrading.md#files-that-moved)).

## Change a setting

1. Edit `.env`.
1. Apply it:

   ```bash
   docker compose up -d
   ```

   Compose recreates the containers whose settings changed. The migrations and the init container run again before the Sync server.

## Start at boot

Every long-running container has `restart: unless-stopped`, so Docker starts the stack again at boot. If you would rather have systemd manage it, the script also writes `config/systemd/syncstorage-rs.service` from [this example](/config/systemd/syncstorage-rs-example.service).

## Next

- [Who can use your server](../limits.md)
- [Backups](../backups.md)
- [Upgrading](../upgrading.md#sync-server)
- Something fails: [Troubleshooting](../troubleshooting.md)
