# firefox-sync

Self-host Firefox Sync with Docker, Podman or Kubernetes: your bookmarks, passwords, history, tabs and the rest are stored on your own server instead of Mozilla's. Optionally, the Mozilla accounts too, so that no Mozilla server is involved at all.

**🐳 Docker, 🦭 Podman and ☸️ Kubernetes (Helm) supported**

## Disclaimer

- ⚠️ The project is under development
- ⚠️ Expect bugs, breaking changes and headache
- ⚠️ **This is not endorsed or supported by Mozilla in any way or form**
- ⚠️ **Do not solely rely on this project to store your bookmarks, passwords and/or other important items**

## Choose your setup

| | Sync server only | Sync server and accounts |
|---|---|---|
| Signing in | your Mozilla account, at `accounts.firefox.com` | accounts created on your server |
| Stored on your server | the Sync data (encrypted by Firefox) | the Sync data, the accounts and their keys |
| Who can use it | anybody with a Mozilla account who points Firefox to it, up to `SYNC_MAX_USERS` | who you allow to sign up: everybody, an allowlist of emails and domains, or nobody |
| Needs | a host name with HTTPS | four host names with HTTPS, 3-4 GB of RAM, an SMTP server (the accounts email their codes) |
| Runs on | docker compose, Podman Quadlets, Kubernetes ([Helm chart](HELM.md)) | docker compose, Podman Quadlets (not in the Helm chart yet) |
| Guide | [SYNC.md](SYNC.md) | [SYNC.md](SYNC.md), then [FXA.md](FXA.md) |

Both are set up by `./prepare_environment.sh`, which asks the questions and writes `.env`:

```bash
git clone https://github.com/porelli/firefox-sync.git
cd firefox-sync
./prepare_environment.sh
docker compose up -d        # with Podman Quadlets: see PODMAN.md
```

Then point your reverse proxy to it and set up Firefox: [for the Sync server only](SYNC.md#firefox-setup), or [with self-hosted accounts](FXA.md#firefox-setup).

On Kubernetes, the Sync server only, with the Helm chart and a `my-values.yaml` of your host name and max users ([HELM.md](HELM.md)):

```bash
helm install ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 \
  -f my-values.yaml --wait --timeout 10m
```

## Documentation

- [SYNC.md](SYNC.md): the Sync server: setup, who can use it (`SYNC_MAX_USERS`), Firefox on desktop, Android and iOS, backups and upgrades
- [FXA.md](FXA.md): self-hosted Mozilla accounts: setup, who can sign up, Firefox setup, upgrades
- [ADMIN.md](ADMIN.md): the optional admin UI: max users, sign-ups and accounts, storage, health, alerts (by email, or to Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix or any webhook: no SMTP server needed for them), backups, Prometheus, signing in with OpenID Connect or a trusted header
- [DATABASES.md](DATABASES.md): MariaDB, MySQL or PostgreSQL, in containers (or the chart's pods) or on a database server you already run
- [PODMAN.md](PODMAN.md): rootless Podman, with Quadlets or `docker compose` on the Podman socket
- [HELM.md](HELM.md): Kubernetes with the Helm chart: install, the Secret, Ingress, the admin UI, backups and restoring, upgrades
- [MIGRATING.md](MIGRATING.md): coming from another self-hosted Sync server, an older firefox-sync, or from docker compose to Kubernetes
- [TESTING.md](TESTING.md): the tests every image build (and the Helm chart) runs, and how to run them locally

## Background

Mozilla's server side components are open source and Firefox allows to easily change the official endpoints.
[Some documentation](https://mozilla-services.readthedocs.io/en/latest/index.html) is provided to install each component on your own server, but it is not officially supported and focuses on a developer environment rather than a production self-hosted service. Mozilla does publish `syncstorage-rs` images with each [release](https://github.com/mozilla-services/syncstorage-rs/releases), on GitHub's registry: [`syncserver-mysql`](https://github.com/mozilla-services/syncstorage-rs/pkgs/container/syncstorage-rs%2Fsyncserver-mysql) and [`syncserver-postgres`](https://github.com/mozilla-services/syncstorage-rs/pkgs/container/syncstorage-rs%2Fsyncserver-postgres) (`0.23.3`, `latest`). They are amd64 only, and built and tested for what Mozilla runs: its CI uses MySQL 8.0, at end of life since April 2026, and PostgreSQL 18, and never MariaDB. The images here add arm64, MariaDB and MySQL 8.4, the database setup and the user limit, and are tested with every database they support (see [TESTING.md](TESTING.md)).

This project provides:
- GitHub workflows that build images as vanilla as possible from Mozilla's code (below)
- Docker compose files, Podman Quadlets and a Helm chart to run the components, with their databases
- examples for the rest of the infrastructure (nginx, systemd)
- instructions to set up Firefox to use your server
- optionally, [Mozilla accounts (fxa)](https://github.com/mozilla/fxa) as well, see [FXA.md](FXA.md)
- an optional [admin UI](ADMIN.md)

## Images

All the images are updated weekly to the latest tag available from Mozilla's official repositories, and published only after the [tests](TESTING.md) passed

### Sync server images
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
    - GitHub [workflow](/.github/workflows/syncstorage-rs.yml) and [logs](https://github.com/porelli/firefox-sync/actions/workflows/syncstorage-rs.yml)
    - Base image: [Mozilla's](https://github.com/mozilla-services/syncstorage-rs/blob/master/Dockerfile) container
    - Base image differences: image built with `SYNCSTORAGE_DATABASE_BACKEND=mysql` and `TOKENSERVER_DATABASE_BACKEND=mysql` to use the MySQL-compatible interface instead of Google Spanner
    - source code: https://github.com/mozilla-services/syncstorage-rs
        - code changes: only the upstream pull requests listed in [upstream-patches.yml](/upstream-patches.yml), until they are in a release; the image lists them in its label `org.firefox-sync.upstream-patches`
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-init-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
    - GitHub [workflow](/.github/workflows/syncstorage-rs.yml) and [logs](https://github.com/porelli/firefox-sync/actions/workflows/syncstorage-rs.yml)
    - Base image: [MariaDB's](https://github.com/MariaDB/mariadb-docker/blob/master/Dockerfile.template) container
    - Purpose: Post-migration database initialization and handling of SYNC_MAX_USERS
    - Base image differences: [added](/db/mysql/init/Dockerfile) [`db_init.sh`](/db/mysql/init/db_init.sh) and [`db_init.sql`](/db/mysql/init/db_init.sql) scripts
    - source code: https://github.com/MariaDB/server
        - code changes: none
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-postgres-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
    - same as `syncstorage-rs-mysql` but built with `SYNCSTORAGE_DATABASE_BACKEND=postgres` and `TOKENSERVER_DATABASE_BACKEND=postgres` to use PostgreSQL
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-postgres-init-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
    - Base image: [PostgreSQL's](https://hub.docker.com/_/postgres) container (`postgres:latest`, for its `psql`)
    - Purpose: Post-migration database initialization and handling of SYNC_MAX_USERS
    - Base image differences: [added](/db/postgres/init/Dockerfile) [`db_init.sh`](/db/postgres/init/db_init.sh) and [`db_init.sql`](/db/postgres/init/db_init.sql) scripts
    - source code: https://github.com/postgres/postgres
        - code changes: none

- [ghcr.io/porelli/firefox-sync:admin-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions), amd64 and arm64
    - GitHub [workflow](/.github/workflows/admin.yml)
    - Purpose: the optional [admin UI](ADMIN.md), and the sign-up policy of the self-hosted accounts
    - source code: [admin/](/admin), a Go program in a distroless image

### Mozilla accounts images
- [`ghcr.io/porelli/firefox-sync:fxa-mono-<release>` and `fxa-mono-latest`](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions), amd64 and arm64
    - GitHub [workflow](/.github/workflows/fxa.yml): Mozilla only publishes [`mozilla/fxa-mono`](https://hub.docker.com/r/mozilla/fxa-mono) for amd64, this builds the same releases for amd64 and arm64 and tests them on both before publishing
    - Base image: [Mozilla's](https://github.com/mozilla/fxa/blob/main/_dev/docker/mono/Dockerfile) container
    - source code: https://github.com/mozilla/fxa
        - code changes: only the upstream pull requests listed in [upstream-patches.yml](/upstream-patches.yml), until they are in a release (today [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494), for MariaDB 12, see [FXA.md](FXA.md#mariadb-12), and [mozilla/fxa#21554](https://github.com/mozilla/fxa/pull/21554), for MySQL 9, see [FXA.md](FXA.md#mysql-9)); the image lists them in its label `org.firefox-sync.upstream-patches`
    - used by default with self-hosted accounts (`FXA_VERSION=fxa-mono-latest`); Mozilla's own image works too on amd64
- [`ghcr.io/porelli/firefox-sync:fxa-channelserver-<release>` and `fxa-channelserver-latest`](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions), amd64 and arm64: the optional QR code pairing server, built the same way from [Mozilla's channelserver](https://github.com/mozilla-services/channelserver)

### Helm chart
- `oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync`, from [charts/firefox-sync](/charts/firefox-sync), see [HELM.md](HELM.md)
    - GitHub [workflow](/.github/workflows/helm.yml): lint, the same settings as compose, an install on kind per database backend; published on a `chart-v<version>` tag after those passed, see [TESTING.md](TESTING.md#the-helm-chart)
    - runs the images above; not the Mozilla accounts images yet

## Credits
- [Mozilla](https://www.mozilla.org/) for [Firefox](https://www.mozilla.org/firefox) and opensourcing all their software, including the backend
- [jeena](https://github.com/jeena) for [fxsync-docker](https://github.com/jeena/fxsync-docker) which is the inspiration for this project
- [jackyzy823](https://github.com/jackyzy823) for [fxa-selfhosting](https://github.com/jackyzy823/fxa-selfhosting), the reference on running Mozilla accounts outside Mozilla
