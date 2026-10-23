# Install with docker compose

This page installs the Sync server with docker compose. Read [What you need](../README.md#what-you-need) first. With Podman, see [Podman](podman.md) instead.

## Requirements

- Docker with the compose plugin ([install](https://docs.docker.com/engine/install/)).
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
| the database backend: `mariadb`, `mysql` or `postgres` | `SYNC_DB`, and `COMPOSE_FILE` for MySQL and PostgreSQL | [Databases](../databases.md) |
| an existing database server instead of the containers | `SYNC_DB_CONTAINERS=0`, and a `database-setup.sql` to run there | [Your own server](../databases.md#with-docker-compose) |
| the image tag of the Sync server | `SYNC_IMAGE_TAG` (`latest`) | [Upgrading](../upgrading.md#sync-server) |
| the admin UI | `admin` in `COMPOSE_PROFILES`, `ADMIN_PASSWORD` | [Admin UI](../admin/README.md#set-up) |
| self-hosted Mozilla accounts | the accounts' section of `.env`, `config/nginx/fxa.conf` | [Self-hosted accounts](../accounts.md#set-up) |
| the nightly backups | `backup` in `COMPOSE_PROFILES` (Quadlets: the backup timer enabled) | [Backups](../backups.md#the-backup-service) |
| with self-hosted accounts, your own pairing server (not with Quadlets) | `pairing` in `COMPOSE_PROFILES`, `FXA_PAIRING_URL=wss://pairing.<accounts domain>`, its server block in `config/nginx/fxa.conf` | [Pairing](../reverse-proxy.md#pairing) |

Every setting is in [Settings](../reference/settings.md). Coming from another Sync server: read [Migrating](../migrating.md) before you run the script.

`COMPOSE_FILE` in `.env` names the compose files of your choices, so a plain `docker compose` always picks the right ones.

`COMPOSE_PROFILES` gets every optional service you chose, for example `COMPOSE_PROFILES=admin,backup`. Run again on an install, the script offers what its `.env` has as the answer to each of them.

## Optional services

They are compose profiles. `COMPOSE_PROFILES` in `.env` is the whole list of the profiles that run, comma-separated, without spaces: `COMPOSE_PROFILES=admin,backup` runs the admin UI and the backups. Commented out or empty, none runs.

| Profile | What it adds | Its services |
|---|---|---|
| `admin` | the [admin UI](../admin/README.md) | `ffs-admin` |
| `backup` | the nightly [backups](../backups.md#the-backup-service) | `backup`, and `backup-fxa` with self-hosted accounts |
| `pairing` | your own pairing server for [self-hosted accounts](../reverse-proxy.md#pairing) | `fxa-pairing` |

`pairing` is a service of `docker-compose.fxa.yml`: it needs that file in `COMPOSE_FILE`, which the script sets when you self-host the accounts. Without it compose has no such service and starts nothing for it.

To turn one on, add it to the list and run `docker compose up -d`.

To turn one off, remove it from the list, then remove its containers: `docker compose up -d` leaves a service of a profile that is off running, and so does `--remove-orphans`. For example, for the backups:

```bash
docker compose rm -sf backup        # with self-hosted accounts: backup backup-fxa
```

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
