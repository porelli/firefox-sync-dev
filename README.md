# firefox-sync

Self-host Firefox Sync with Docker or Podman: your bookmarks, passwords, history, tabs and the rest are stored on your own server instead of Mozilla's. Optionally, the Mozilla accounts too, so that no Mozilla server is involved at all.

**🐳 Docker and 🦭 Podman supported**

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
| Guide | [SYNC.md](SYNC.md) | [SYNC.md](SYNC.md), then [FXA.md](FXA.md) |

Both are set up by `./prepare_environment.sh`, which asks the questions and writes `.env`:

```bash
git clone https://github.com/porelli/firefox-sync.git
cd firefox-sync
./prepare_environment.sh
docker compose up -d        # with Podman Quadlets: see PODMAN.md
```

Then point your reverse proxy to it and set up Firefox: [for the Sync server only](SYNC.md#firefox-setup), or [with self-hosted accounts](FXA.md#firefox-setup).

## Documentation

- [SYNC.md](SYNC.md): the Sync server: setup, who can use it (`SYNC_MAX_USERS`), Firefox on desktop, Android and iOS, backups and upgrades
- [FXA.md](FXA.md): self-hosted Mozilla accounts: setup, who can sign up, Firefox setup, upgrades
- [ADMIN.md](ADMIN.md): the optional admin UI: max users, sign-ups and accounts, storage, health, alerts (by email, or to Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix or any webhook: no SMTP server needed for them), backups, Prometheus, signing in with OpenID Connect or a trusted header
- [DATABASES.md](DATABASES.md): MariaDB, MySQL or PostgreSQL, in containers or on a database server you already run
- [PODMAN.md](PODMAN.md): rootless Podman, with Quadlets or `docker compose` on the Podman socket
- [MIGRATING.md](MIGRATING.md): coming from another self-hosted Sync server, or an older firefox-sync
- [TESTING.md](TESTING.md): the tests every image build runs, and how to run them locally

## Background

Mozilla's server side components are open source and Firefox allows to easily change the official endpoints.
[Some documentation](https://mozilla-services.readthedocs.io/en/latest/index.html) is provided to install the each component on your own server but this is neither officially supported or very well maintained. Furthermore, there are no official Docker images that can be used to avoid installing everything manually; all the instructions and artifacts provided are focused on setting up a developer environment rather than a production self hosted service. For example, `syncstorage-rs` has a [docker release on docker-hub](https://hub.docker.com/r/mozilla/syncstorage-rs/) with images for Google Spanner and PostgreSQL (`<sha>-spanner`, `<sha>-postgres`), amd64 only; version tags stop at 0.21.1; no MySQL/MariaDB image and no arm64.

This project provides:
- GitHub workflows that build images as vanilla as possible from Mozilla's code (below)
- Docker compose files and Podman Quadlets to run the components, with their databases
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
    - Base image: [PostgreSQL's](https://github.com/docker-library/postgres/blob/master/18/trixie/Dockerfile) container (`postgres:18`)
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
        - code changes: only the upstream pull requests listed in [upstream-patches.yml](/upstream-patches.yml), until they are in a release (today [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494), for MariaDB 12, see [FXA.md](FXA.md#mariadb-12)); the image lists them in its label `org.firefox-sync.upstream-patches`
    - used by default with self-hosted accounts (`FXA_VERSION=fxa-mono-latest`); Mozilla's own image works too on amd64
- [`ghcr.io/porelli/firefox-sync:fxa-channelserver-<release>` and `fxa-channelserver-latest`](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions), amd64 and arm64: the optional QR code pairing server, built the same way from [Mozilla's channelserver](https://github.com/mozilla-services/channelserver)

## Credits
- [Mozilla](https://www.mozilla.org/) for [Firefox](https://www.mozilla.org/firefox) and opensourcing all their software, including the backend
- [jeena](https://github.com/jeena) for [fxsync-docker](https://github.com/jeena/fxsync-docker) which is the inspiration for this project
- [jackyzy823](https://github.com/jackyzy823) for [fxa-selfhosting](https://github.com/jackyzy823/fxa-selfhosting), the reference on running Mozilla accounts outside Mozilla
