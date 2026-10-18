# The Sync server

[syncstorage-rs](https://github.com/mozilla-services/syncstorage-rs), Mozilla's Sync server, with its tokenserver and databases. Firefox keeps signing in with a Mozilla account (`accounts.firefox.com`) and stores its Sync data here instead of on Mozilla's servers. The data is encrypted by Firefox with the account's keys before it leaves the device: the server never sees it in clear. To self-host the accounts too, set this up first, then see [FXA.md](FXA.md).

## What you need

- Docker with the compose plugin, Podman ([PODMAN.md](PODMAN.md)), or Kubernetes 1.27+ with Helm ([HELM.md](HELM.md))
- A host name with HTTPS behind a reverse proxy, e.g. `firefox-sync.example.com`, proxied to `127.0.0.1:${SYNC_EXPORT_PORT}` (`5000` by default); on Kubernetes an Ingress, or your proxy in front of the Sync server's Service
- A database: by default the containers of the stack (the chart's pods on Kubernetes), MariaDB. It can be MySQL 8.4 or PostgreSQL instead, or a server you already run, see [DATABASES.md](DATABASES.md)

## Setup

### Docker Compose

1. clone this repository
1. run `./prepare_environment.sh` to prepare your `.env` file and the config examples with your values
    - you can choose between MariaDB (default, [docker-compose.yml](/docker-compose.yml)), MySQL 8.4 (`mysql`: the same file with [docker-compose.sync-mysql.yml](/docker-compose.sync-mysql.yml), what upstream syncstorage-rs is developed and tested on, see [DATABASES.md](DATABASES.md#mariadb-or-mysql-containers)) and PostgreSQL ([docker-compose.sync-postgres.yml](/docker-compose.sync-postgres.yml)) as database backend. For MySQL and PostgreSQL, the script sets `COMPOSE_FILE` in `.env` so that `docker compose` picks the right files automatically
    - you can pin the syncstorage image to a specific tag (default: `latest`)
    - you can also self-host Mozilla accounts (see [FXA.md](FXA.md)): the script asks for the host names and your SMTP server and sets everything up. Their database is MySQL 8.4 by default, or MariaDB 12 ([MySQL or MariaDB](FXA.md#mysql-or-mariadb))
    - you can use a MariaDB, MySQL or PostgreSQL server you already run instead of the database containers: the script writes the SQL for the databases and users, see [DATABASES.md](DATABASES.md)
    - coming from another self-hosted Sync server (Mozilla's compose files, other images, NixOS, YunoHost, the Python syncserver, fxa-selfhosting): see [MIGRATING.md](MIGRATING.md)
1. set up your reverse proxy
    1. if you use nginx, check [syncstorage-rs-example.conf](/config/nginx/syncstorage-rs-example.conf) (and [fxa-example.conf](/config/nginx/fxa-example.conf) with self-hosted accounts)
1. start docker compose:
    ```bash
    docker compose up -d
    ```
    - with Podman, use the Quadlets below or `docker compose` with the Podman socket, see [PODMAN.md](PODMAN.md#method-2-using-docker-compose-with-the-podman-socket). `podman-compose` is not supported because it cannot run the one-shot migration and init containers before the service ([why](PODMAN.md#why-not-podman-compose))
1. OPTIONAL: install the systemd service
    - **Docker**: see [firefox-sync.service](/config/systemd/syncstorage-rs-example.service)
    - **Podman**: see [PODMAN.md](PODMAN.md#method-1-using-quadlets) for the Quadlets (recommended)
    - all containers restart automatically
1. OPTIONAL: the [admin UI](ADMIN.md), enabled by `prepare_environment.sh` by default: max users without a restart, storage per account, health, alerts (by email, or to Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix or a webhook without any SMTP server, see [Alerts](ADMIN.md#alerts))
1. [set up Firefox](#firefox-setup)

### Podman with Quadlets (recommended for Podman)

For native systemd integration with Podman, see the [Podman guide](PODMAN.md#method-1-using-quadlets). Quadlets are provided for MariaDB and MySQL, with or without self-hosted accounts.

```bash
./prepare_environment.sh  # choose option 1 (Quadlets, the default) when prompted
systemctl --user start firefox-sync-syncstorage.service
```

### Kubernetes

The Helm chart runs the same images, with the settings as values instead of `.env` (no `prepare_environment.sh`): see [HELM.md](HELM.md).

```bash
helm install ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 \
  -f my-values.yaml --wait --timeout 10m
```

`my-values.yaml` has `syncDomain` (the `SYNC_PUBLIC_URL`), `maxUsers` (`SYNC_MAX_USERS`) and the Ingress; the admin UI (`admin.enabled`) and the backups (`backup.enabled`) are off by default. Then [set up Firefox](#firefox-setup).

## Who can use your server

syncstorage-rs has no allowlist: anybody who can reach your server and has a Mozilla account can point Firefox to it. firefox-sync limits how many accounts can use it instead, with a trigger in the tokenserver database that refuses new accounts once `SYNC_MAX_USERS` is reached:

- `SYNC_MAX_USERS=5` (or `fixed:5`) sets the limit on every start
- `SYNC_MAX_USERS=initial:5` sets it on the first start only, then the [admin UI](ADMIN.md#max-users) manages it, without a restart (`prepare_environment.sh` writes `initial:` when you enable the admin UI)
- `SYNC_MAX_USERS=unlimited` (or `initial:unlimited`) means no limit, `0` no new account at all. Anything else stops the stack from starting
- the limit counts accounts, not database rows: an account changing its keys (e.g. after a password reset) is never locked out
- with the Helm chart, the same forms in `maxUsers` of your values

To choose who exactly can use it (an allowlist of emails and domains, or closed sign-ups), self-host the accounts as well (docker compose or the Quadlets: not in the Helm chart yet): only accounts created on your server can then sign in, see [FXA.md](FXA.md#who-can-sign-up).

## Firefox setup

Do this on every device, starting with the one that has the most data.

**Before you start**: if Firefox is already signed in, sign out first (`Settings` > `Sync` > `Sign out`, and keep the data on the device when Firefox asks). Firefox reads the Sync server address only when it signs in.

The examples below use `https://firefox-sync.example.com`: use your `SYNC_PUBLIC_URL` (`syncDomain` with the Helm chart). The [admin UI](ADMIN.md#invitations-and-connect-a-device)'s Connect a device page shows the same steps with your server's values, and its invitations send them by email.

### Desktop

1. open `about:config` in a tab, accept the warning and search for `identity.sync.tokenserver.uri`
1. change it from the default to `https://firefox-sync.example.com/1.0/sync/1.5`
1. sign in to Firefox with your Mozilla account and turn on Sync

To check it works, open `about:sync-log`: the newest logs show no errors. To go back to Mozilla's servers, sign out, reset `identity.sync.tokenserver.uri` in `about:config` and sign in again.

### Android

1. go to App Menu `⋮` > `Settings` > `About Firefox` and tap the logo 5 times. You should see a `debug menu enabled` notification
1. go back to the main settings menu: `Sync Debug` is at the top, just under the `Synchronize and save your data` box. Tap it
1. tap `Custom Sync server` and set it to `https://firefox-sync.example.com/1.0/sync/1.5`
1. sign in to Firefox and start syncing

### iOS

1. go to App Menu `≡` > `Settings` and tap 5 times the version number (e.g. `Firefox 127.1 (42781)`) towards the bottom
1. go back to the top of the main settings menu: `Advanced Sync Settings` is just under `Sync and Save Data`. Tap it
1. turn on `Use Custom Sync Token Server` and set `Custom Sync Token Server URI` to `https://firefox-sync.example.com/1.0/sync/1.5` (the `Custom FxA Content Server` options are only for [self-hosted accounts](FXA.md#firefox-setup))
1. sign in to Firefox and start syncing

## Backups

The Sync data is encrypted by Firefox, but it is the only copy of what is not on any device anymore. Add `backup` to `COMPOSE_PROFILES` in `.env` (Quadlets: `systemctl --user enable --now firefox-sync-backup.timer`; Helm: `backup.enabled`, [HELM.md](HELM.md#backups)) for nightly dumps of the databases into a volume, watched by the admin UI, and copy them off the host together with `.env`: see [ADMIN.md](ADMIN.md#backups), which also says how to restore them.

## Upgrades

The images follow `latest` by default (`SYNC_IMAGE_TAG` and `SYNC_INIT_IMAGE_TAG` in `.env`): a new syncstorage-rs release is published here only after the [tests](TESTING.md) passed with it. Upgrade with:

```bash
docker compose pull
docker compose up -d
```

The database migrations run before syncstorage starts. To decide when to upgrade instead, pin a tag in `.env`. With the Helm chart: `helm upgrade`, and the tags in your values, see [HELM.md](HELM.md#upgrades). Upgrading from an older firefox-sync release: see [MIGRATING.md](MIGRATING.md#older-firefox-sync-releases).
