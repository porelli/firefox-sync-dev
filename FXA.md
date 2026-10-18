# Self-hosted Mozilla accounts

By default Firefox signs in with Mozilla accounts (`accounts.firefox.com`) and only the sync data is stored on your server. [docker-compose.fxa.yml](/docker-compose.fxa.yml) adds the accounts service as well, so that signing in, the account keys and the sync data all stay on your server.

⚠️ Mozilla does not support self-hosting its accounts service and changes it every couple of weeks. Each release is published here only after the tests passed with it; pin `FXA_VERSION` to choose when to take a new one, see [Upgrades](#upgrades).

## What you need

- The accounts image, about 5 GB unpacked: by default amd64 and arm64 builds of Mozilla's releases from this repository (`fxa-mono-latest`, the newest release that passed the tests on both architectures, built by [fxa.yml](/.github/workflows/fxa.yml) from Mozilla's sources, with only the upstream pull requests of [upstream-patches.yml](/upstream-patches.yml) applied, see [MariaDB 12](#mariadb-12)). Pin a release with `FXA_VERSION=fxa-mono-v1.347.1`, or use Mozilla's own image (amd64 only) with `FXA_IMAGE=docker.io/mozilla/fxa-mono` and `FXA_VERSION=v1.347.1`.
- 3-4 GB of RAM for the whole stack.
- An SMTP server: new accounts and new sign-ins are confirmed with a code sent by email.
- A database: by default the `fxa-db` container, MySQL 8.4. It can be MariaDB instead, see [MySQL or MariaDB](#mysql-or-mariadb). Or your own MySQL 8.0/8.4 or MariaDB 11.4 or later server (MariaDB 12 with our accounts images, not MySQL 9): `prepare_environment.sh` asks, see [DATABASES.md](DATABASES.md).
- Four host names behind your reverse proxy, with HTTPS:

  | host name | `.env` | proxy to |
  |---|---|---|
  | `accounts.example.com` | `FXA_CONTENT_URL` | `127.0.0.1:3030` |
  | `api.example.com` | `FXA_AUTH_URL` | `127.0.0.1:9000`, and with the [admin UI](ADMIN.md) `POST /v1/account/create` to `127.0.0.1:8091` |
  | `profile.example.com` | `FXA_PROFILE_URL` | `127.0.0.1:1111`, and `/img/` to `127.0.0.1:1112/` |
  | `sync.example.com` | `SYNC_PUBLIC_URL` | `127.0.0.1:${SYNC_EXPORT_PORT}`, as without FxA |
  | `admin.example.com` (optional) | `ADMIN_OIDC_REDIRECT_URL` | `127.0.0.1:8090`, to sign in to the [admin UI](ADMIN.md#signing-in) with these accounts, from your own addresses only |

## Setup

1. Run `./prepare_environment.sh` and answer `y` to "Also self-host Mozilla accounts?": it asks for the domain of the host names, your SMTP server and the [database](#mysql-or-mariadb), generates the secrets, points the sync server to your accounts and sets `COMPOSE_FILE` so that `docker compose up -d` starts everything. It also writes an nginx example to `config/nginx/fxa.conf`. Last, with the admin UI, it asks whether to sign in to the admin UI with these accounts: give the admins' emails (and the host name of the admin UI) to register the admin UI as an OAuth client of the accounts service, see [ADMIN.md](ADMIN.md#signing-in). To do it by hand instead, fill in the `SELF-HOSTED MOZILLA ACCOUNTS` section of `.env`:
    - the three URLs above
    - a different random value for each `FXA_*_SECRET`, `FXA_FLOW_ID_KEY`, `FXA_SESSION_TOKEN_HANDLE_KEY`, `FXA_CONTENT_SESSION_SECRET`, `FXA_MYSQL_PASSWORD` and `FXA_ADMIN_DB_PASSWORD`
    - who can sign up: `FXA_SIGNUPS` and `FXA_SIGNUP_ALLOWLIST`, see [below](#who-can-sign-up)
    - your SMTP server
1. Point the sync server to your accounts service instead of Mozilla's:
    ```
    FXA_OAUTH_SERVER_URL=http://fxa-auth:9000/v1
    FXA_EMAIL_DOMAIN=api.example.com
    ```
    `FXA_EMAIL_DOMAIN` must be the host name of `FXA_AUTH_URL`.
1. Start everything:
    ```bash
    docker compose -f docker-compose.yml -f docker-compose.fxa.yml up -d
    ```
    The first start takes a few minutes: the databases are created, then the keys are generated (kept in the `fxa-keys` volume, do not lose it or every session becomes invalid).
    With Podman, choose Quadlets in `prepare_environment.sh`: the accounts get their own units (`firefox-sync-fxa-*`), start them with `systemctl --user start firefox-sync-fxa-content.service firefox-sync-fxa-profile.service firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service`.
1. [Set up Firefox](#firefox-setup).

## Firefox setup

Do this on every device, starting with the one that has the most data. Firefox is pointed to your accounts server, which tells it where your Sync server is.

**Before you start**:
- Mozilla's accounts do not work with your server: each person needs an account created on your server (sign up from Firefox, or from an [invitation](ADMIN.md#invitations-and-connect-a-device) of the admin UI).
- If Firefox is already signed in, to a Mozilla account or to a Sync server of yours, sign out first (`Settings` > `Sync` > `Sign out`, and keep the data on the device when Firefox asks). Firefox reads the addresses only when it signs in.

The examples below use `https://accounts.example.com` (your `FXA_CONTENT_URL`) and `https://sync.example.com` (your `SYNC_PUBLIC_URL`). The admin UI's [Connect a device](ADMIN.md#invitations-and-connect-a-device) page shows the same steps with your values, and its invitations send them by email.

### Desktop

1. open `about:config` in a tab, accept the warning and search for `identity.fxaccounts.autoconfig.uri`
1. set it to `https://accounts.example.com`
1. restart Firefox
1. sign in from the account icon of the toolbar (or `Settings` > `Sync`): the sign-in page must be on `accounts.example.com`. New accounts are created there too, with a code sent by email
1. turn on Sync

To check it works, open `about:sync-log`: the newest logs show no errors. To go back to Mozilla's accounts, sign out, reset `identity.fxaccounts.autoconfig.uri` in `about:config` and restart Firefox.

### Android

1. go to App Menu `⋮` > `Settings` > `About Firefox` and tap the logo 5 times. You should see a `debug menu enabled` notification
1. go back to the main settings menu: `Sync Debug` is at the top. Tap it
1. set `Custom Mozilla account server` to `https://accounts.example.com`
1. set `Custom Sync server` to `https://sync.example.com/1.0/sync/1.5`
1. restart Firefox when it asks, then sign in and turn on Sync

### iOS

1. go to App Menu `≡` > `Settings` and tap 5 times the version number towards the bottom
1. go back to the top of the main settings menu and tap `Advanced Sync Settings`
1. turn on `Use Custom FxA Content Server` and set `Custom Account Content Server URI` to `https://accounts.example.com`
1. sign in and turn on Sync

### A phone, from a computer already signed in

1. set up Firefox on the phone as above first
1. on the computer open `Settings` > `Sync` > `Connect another device`: it shows a QR code
1. scan it with Firefox on the phone. The two pair through Mozilla's pairing server, or yours with `FXA_PAIRING_URL` (see [What works and what doesn't](#what-works-and-what-doesnt))

## MySQL or MariaDB

Mozilla runs and supports its accounts on MySQL only, so `fxa-db` is MySQL 8.4 by default. If you would rather run only MariaDB, the stack can use MariaDB for the accounts: MariaDB 12 (`mariadb:12.3`) for new installs set up by `prepare_environment.sh`, with our accounts images. Every release is tested on it here with the same tests as on MySQL (sign-up, sync, the sign-up policy and the admin UI, a real Firefox), on MariaDB 12 and on 11.8, and the sign-up policy needs no change. `mariadb:lts` is tested too, as an early warning for the next major version.

- `prepare_environment.sh` asks, with `mysql` as the default. It does not follow the Sync server's choice: Sync uses MariaDB by default, so that would move most new installs off what Mozilla supports.
- By hand: `FXA_DB=mariadb` in `.env`, and with docker compose `docker-compose.fxa-mariadb.yml` at the end of `COMPOSE_FILE`, e.g. `COMPOSE_FILE=docker-compose.yml:docker-compose.fxa.yml:docker-compose.fxa-mariadb.yml`. The Quadlets get `config/quadlet/fxa/mariadb/` in place of the MySQL unit.
- The image is `FXA_MARIADB_IMAGE` in `.env` (`fxa-db` and the backups of the accounts). `prepare_environment.sh` writes `mariadb:12.3` for new installs: MariaDB's long-term 12.x series, the one the accounts are tested on (it gets its fixes, not a new major), not `mariadb:lts`, which moves to the next major when MariaDB releases it and would upgrade the data with it (Podman's auto-update and `MARIADB_AUTO_UPGRADE` would do it unattended), with no way back. Without the setting it is `mariadb:11.8`, what the installs from before it run: an update of the files never moves their data to another major version by itself. `./prepare_environment.sh --upgrade`, or running `prepare_environment.sh` again on the install, writes `FXA_MARIADB_IMAGE=mariadb:11.8` for them; so does a new setup that finds the MariaDB volume of an earlier install (`fxa-db-mariadb`). A newer major is a choice: on a new install set `FXA_MARIADB_IMAGE=mariadb:12.3` by hand, to move an existing one see [Moving to a newer MariaDB](#moving-to-a-newer-mariadb).
- MariaDB 12 needs our accounts images, see [below](#mariadb-12); with Mozilla's own image use `FXA_MARIADB_IMAGE=mariadb:11.8`.
- Choose it before the first start. MariaDB gets its own volume (`fxa-db-mariadb`, Quadlets: `firefox-sync-fxa-db-mariadb`) because it cannot open MySQL's data files. Switching an existing install leaves the MySQL data in `fxa-db` and starts with empty accounts. Moving the data needs a dump and a reload, and that is not tested here.
- Mozilla could release a migration that works on MySQL only. Releases are published once they pass on MySQL, and a MariaDB failure does not hold them back. With MariaDB, pin `FXA_VERSION` and upgrade after a release passed the `test-mariadb` jobs of [fxa.yml](/.github/workflows/fxa.yml).

### MariaDB 12

MariaDB 12 names unnamed foreign keys `1`, `2`, ... MySQL and MariaDB 11 name them `<table>_ibfk_N`. Mozilla's migrations drop foreign keys by those names, so on a new database on MariaDB 12 they stop at the first one: `ER_CANT_DROP_FIELD_OR_KEY: Can't DROP FOREIGN KEY deviceCommands_ibfk_1` (`fxa`, patch 096-097), then the same in `fxa_oauth` (`clientDevelopers_ibfk_1`). No server setting changes that. The fix is proposed upstream in [mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494): it names those foreign keys `<table>_ibfk_N` where the migrations create them, which changes nothing on MySQL and MariaDB 11.

Until a release includes it, the accounts images built here have it: [fxa.yml](/.github/workflows/fxa.yml) applies the pull requests listed in [upstream-patches.yml](/upstream-patches.yml), each as of the commit that was reviewed, to Mozilla's sources before building, and tests the images on MariaDB 12 and 11.8. The images list what was applied in the label `org.firefox-sync.upstream-patches`:

```bash
docker image inspect -f '{{index .Config.Labels "org.firefox-sync.upstream-patches"}}' ghcr.io/porelli/firefox-sync:fxa-mono-latest
# mozilla/fxa#21494@517651a..aa0b178
```

Mozilla's own images (`docker.io/mozilla/fxa-mono`) and ours built before don't have it (no label): with them, `FXA_MARIADB_IMAGE=mariadb:11.8`. `prepare_environment.sh` (also with `--upgrade`) warns when the accounts would run on MariaDB 12 or later, or on your own MariaDB server, with an image that does not have it; it reads the label of the local image (what starts), and of the registry's (`docker buildx imagetools` or `skopeo`) when there is none, or to tell you to pull when the local one is older. The admin UI does not check it: it cannot inspect images.

### Moving to a newer MariaDB

From MariaDB 11.8 (`FXA_MARIADB_IMAGE=mariadb:11.8`, or not set) to 12, or later from 12 to the next major once [fxa.yml](/.github/workflows/fxa.yml)'s `test-mariadb` jobs pass on it (the `mariadb:lts` one tests the newest). With our accounts images for 12: following `fxa-mono-latest`, the pull of step 3 brings one with the patch if yours is older; with a pinned `FXA_VERSION`, pin a release whose image has the label above.

1. A backup of the accounts: `docker compose exec backup-fxa sh /ffs-backup/backup.sh now` (the [backup service](ADMIN.md#backups)), or of the `fxa-db-mariadb` volume with the stack stopped. It is the only way back: the older MariaDB cannot open the data once the newer one started on it.
1. `FXA_MARIADB_IMAGE=mariadb:12.3` in `.env` (the series you move to, the one `test-mariadb` passes on; not `mariadb:lts`, see above).
1. `docker compose pull && docker compose up -d`. At its first start the new MariaDB upgrades the data itself (`MARIADB_AUTO_UPGRADE`, set in the stack: `mariadb-upgrade`, after a backup of its system tables; `docker compose logs fxa-db` says `Finished mariadb-upgrade`); then the migrations and the services start as after any upgrade.
1. Check as in [Upgrades](#upgrades), step 4: the admin UI's overview also shows the new version next to "Accounts database". If anything fails: stop the stack, restore the backup into an empty `fxa-db-mariadb` volume with the older `FXA_MARIADB_IMAGE` ([ADMIN.md](ADMIN.md#restoring)).

Tested locally (not in CI: it takes an install, a backup and two starts of the accounts), from 11.8 to 12: `FXA_DB=mariadb FXA_MARIADB_FROM=mariadb:11.8 FXA_MARIADB_IMAGE=mariadb:12.3 tests/fxa-upgrade.sh`, an install on 11.8 with an account, a device and Sync data, moved with these steps (see [Tests](#tests)). Not tested: the Quadlet steps below.

With Quadlets: the backup (`systemctl --user start firefox-sync-backup.service`), then `Image=docker.io/library/mariadb:12.3` in `~/.config/containers/systemd/firefox-sync-fxa-db.container` and `firefox-sync-backup-fxa.container` (and `FXA_MARIADB_IMAGE=mariadb:12.3` in `.env`, for the next `prepare_environment.sh`), `systemctl --user daemon-reload`, `podman pull docker.io/library/mariadb:12.3` and `systemctl --user restart firefox-sync-fxa-db.service`.

## Who can sign up

Anybody who can reach your accounts pages can create an account, and with it use your sync server (up to `SYNC_MAX_USERS`). To allow only some emails or domains, or nobody, set `FXA_SIGNUPS` and `FXA_SIGNUP_ALLOWLIST` in `.env` (`prepare_environment.sh` asks for the allowlist), or use the [admin UI](ADMIN.md), which can also disable accounts. The accounts database enforces it, see [ADMIN.md](ADMIN.md#who-can-sign-up-self-hosted-accounts).

`FXA_MAX_ACCOUNTS` caps how many accounts can be created at all, whoever signs up: a number (`0`: nobody new) or `unlimited` (the default, `initial:unlimited`). Like `SYNC_MAX_USERS`, `N` or `fixed:N` is set on every start, `initial:N` once and then in the admin UI; `prepare_environment.sh` asks for it last. Every row of `fxa.accounts` counts (confirmed or not, disabled too); when full, the sign-up page says the server is full and the database refuses the account itself, see [ADMIN.md](ADMIN.md#max-accounts-self-hosted-accounts).

## Security history

Off by default. With `FXA_ACCOUNT_EVENTS=true` in `.env` (`prepare_environment.sh` asks, default no; then `docker compose up -d`) the accounts service keeps a security history of every account in `fxa.securityEvents`: each sign-in and wrong password, password change and reset, two-step authentication turned on or off, recovery key created or removed, backup codes, secondary emails, passkeys and sign-outs, with its time, **the IP address it came from** and the browser's user agent. The owner sees it in Recent activity of the account settings, the [admin UI](ADMIN.md#security-history) on the account page, with an event and an alert when the password, the primary email or a way to sign in or to recover the account changes ([the list](ADMIN.md#security-history)).

What the setting changes, read in Mozilla's code (fxa-mono v1.347.x, the same in every v1.347 release): it is `ACCOUNT_EVENTS_ENABLED` of the auth server (on in Mozilla's defaults). Off, the auth server replaces its `AccountEventsManager` with one that does nothing (`bin/key_server.js`): no security event is written, and Recent activity stays empty. On, every event is written to the accounts database (the other part of it, email events in Google's Firestore, stays off with `FIRESTORE_ENABLED=false`). The auth server also reads the history at sign-in: after a confirmed sign-in from an IP address, Mozilla lets later sign-ins from the same address skip the code sent by email for 7 days (`IP_PROFILING_RECENCY`), the sign-ins of Firefox for Sync too, so a password alone would be enough from a shared network. The stack sets that window to 0 (`IP_PROFILING_RECENCY=0` in `docker-compose.fxa.yml` and the Quadlets): the sign-in code is asked exactly as with the history off. The other skips do not use the setting: the one for a known browser (`SIGNIN_CONFIRMATION_DEVICE_FINGERPRINTING_ENABLED`) is off in Mozilla's defaults, the one for accounts created less than 48 hours ago applies either way.

Privacy, plainly:

- The IP address is stored as is, next to a keyed hash of it (`IP_HMAC_KEY`, which therefore hides nothing). IP addresses are personal data in many countries: say so to the people who use your server.
- Mozilla never prunes the history: its procedures delete it only with the account. The admin UI's daily pruning removes events older than `ADMIN_RETENTION_DAYS` (30), see [ADMIN.md](ADMIN.md#maintenance-and-retention). Without the admin UI nothing does: run `DELETE FROM fxa.securityEvents WHERE createdAt < (UNIX_TIMESTAMP() - 30 * 86400) * 1000;` regularly yourself.
- Turning it off again stops new entries; those recorded stay until they are pruned or the account is deleted.
- The IP addresses are in other places too: the events of kind `security` of the admin UI's event log (`ffs_events` in the admin UI's own database `ffs_admin`, `ADMIN_DB_NAME`, not the accounts' user of that name; `ADMIN_RETENTION_DAYS`) and its alert emails (in the admins' mailboxes), and the accounts backups (`COMPOSE_PROFILES=backup`: `fxa.securityEvents` is in every dump, the newest `BACKUP_KEEP` runs). Deleting the rows of `fxa.securityEvents` leaves those; `DELETE FROM ffs_events WHERE kind = 'security';` in that database, as `ADMIN_DB_USER` (`ffs_admin_ui`, [how](ADMIN.md#metrics-and-the-event-log)), removes the first.
- The admin UI reads the name, time, IP address and whether the sign-in was confirmed, not the rest (the JSON of an event can hold the recovery phone's number).

## What works and what doesn't

- Works and is tested: sign-up, email confirmation, sign-in, OAuth for Sync, syncing, a second device. Tested with Firefox 157 desktop: two profiles signed up and in through the accounts pages and synced bookmarks between them.
- Send tab to device uses Mozilla's public push service, as Firefox does with Mozilla accounts.
- Pairing a phone with a QR code uses Mozilla's channel server, unless you run your own: uncomment `COMPOSE_PROFILES=pairing` and `FXA_PAIRING_URL=wss://pairing.example.com` in `.env` and proxy that host name (websocket) to `FXA_PAIRING_EXPORT_PORT`, see the example in `config/nginx/fxa-example.conf`.
- Sign-in attempts are rate limited by the accounts service itself (Redis, upstream's `rate-limit-rules.txt`), e.g. 5 failed sign-ins per IP address and email in 15 minutes. The old separate customs server does not exist anymore. The client IP address comes from `X-Forwarded-For`: with another proxy in front of yours, raise `FXA_CLIENT_ADDRESS_DEPTH`, see [ADMIN.md](ADMIN.md#rate-limits-and-the-client-ip-address).
- Not available: payments and subscriptions, recovery phone (SMS), sign in with Google or Apple, deferred account clean-up tasks and account event notifications to other services (they need Google Cloud; the [security history](#security-history) does not).

## Upgrades

Like the sync server, the accounts follow `latest` by default (`FXA_VERSION=fxa-mono-latest`): a new Mozilla release, about every two weeks, is published here only after the tests passed with it on amd64 and arm64, including a real Firefox signing up and syncing, and an install of the previous release upgraded to it ([below](#tests)). The database migrations (`fxa-migrations`) run before the services start and cannot be undone: once a release migrated the databases, going back means restoring a backup. Sessions, devices, OAuth tokens and Sync data are kept: Firefox stays signed in. So:

1. Back up the `fxa-db` (`fxa-db-mariadb` with MariaDB) and `fxa-keys` volumes regularly (the keys sign every session and OAuth token). With [your own database server](DATABASES.md), back up its `fxa`, `fxa_oauth`, `fxa_profile`, `pushbox` and `ffs` databases instead. With the [backup service](ADMIN.md#backups), take one right before: `docker compose exec backup-fxa sh /ffs-backup/backup.sh now`.
1. To decide when to upgrade instead, pin a release: `FXA_VERSION=fxa-mono-v1.347.1`, and to upgrade change it in `.env`.
1. Then, pinned or not, pull and start:
    ```bash
    docker compose pull
    docker compose up -d
    ```
    `docker compose up -d` alone does not upgrade `fxa-mono-latest`: it keeps the image it has. `up -d` runs `fxa-migrations` again with the new image, then `fxa-policy` (it installs the sign-up policy and the admin UI's procedures again over the migrated databases), and only then replaces the accounts services.
1. Check: `docker compose ps -a fxa-migrations fxa-policy` says `Exited (0)` for both, `docker compose ps` shows the other services `(healthy)` (the accounts services can take a few minutes, `(health: starting)` until then), and the [admin UI](ADMIN.md)'s overview shows the new release next to "Accounts API", all parts up, and the new schema levels of the accounts databases (with an event of kind `update` for each one that migrated). If `fxa-migrations` failed, `docker compose up -d` stops there with an error and `docker compose logs fxa-migrations` says why; restore the backup to go back to the older release.

To move from Mozilla's image to the builds of this repository (or back), change `FXA_IMAGE`, `FXA_VERSION` and `FXA_ARCH` together, e.g. from `FXA_IMAGE=docker.io/mozilla/fxa-mono`, `FXA_VERSION=v1.345.2`, `FXA_ARCH=amd64` to `FXA_IMAGE=ghcr.io/porelli/firefox-sync`, `FXA_VERSION=fxa-mono-latest`, `FXA_ARCH=arm64`, then the same steps: it is the same software, the databases and keys stay.

With Quadlets, the image is written in the unit files when `prepare_environment.sh` installs them, and the one-shot units of the migrations and of the sign-up policy ran at the first start and stay active: a new image alone does not migrate. To upgrade:

1. A backup: `systemctl --user start firefox-sync-backup.service` (the accounts first).
1. The new image: with `fxa-mono-latest`, `podman pull ghcr.io/porelli/firefox-sync:fxa-mono-latest` (`--arch` as `FXA_ARCH`); pinned, change the release in the `Image=` lines and pull it:
    ```bash
    sed -i 's|:fxa-mono-v1.347.1$|:fxa-mono-v1.347.3|' ~/.config/containers/systemd/firefox-sync-fxa-*.container
    systemctl --user daemon-reload
    podman pull ghcr.io/porelli/firefox-sync:fxa-mono-v1.347.3
    ```
    (and `FXA_VERSION` in `.env`, for the next `prepare_environment.sh`).
1. Run the migrations again. Restarting their unit restarts, in order, the units that require it: the sign-up policy, then the auth server, the accounts pages, the profile server and the admin UI. The profile worker and its static server do not require it:
    ```bash
    systemctl --user restart firefox-sync-fxa-migrations.service firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service
    journalctl --user -u firefox-sync-fxa-migrations.service -n 20
    ```
    It returns once the migrations ran; the other units restart after, as at the first start (minutes).

`podman auto-update` (and its timer) replaces the running accounts services when `fxa-mono-latest` moves, without running the migrations: the new release then runs on the old schema until they run. With self-hosted accounts, pin `FXA_VERSION` and upgrade with the steps above, or run the restart of step 3 right after each `podman auto-update`.

Don't stay too far behind either: Firefox itself refuses to sign in to accounts servers that are too old for it (for example Firefox 154 needs a recent release because it switched to Bearer tokens).

## Tests

[`tests/e2e-fxa.sh`](/tests/e2e-fxa.sh) starts the stack with a test reverse proxy (Caddy, HTTPS with its own CA) and a mail catcher (Mailpit), then [`tests/test_fxa_flow.py`](/tests/test_fxa_flow.py) does what Firefox does: reads the client configuration, signs up, confirms the email, gets the keys and an OAuth token, gets a sync token from the tokenserver and syncs, then signs in again as a second device. [`tests/test_fxa_admin.py`](/tests/test_fxa_admin.py) checks the sign-up policy and the [admin UI](ADMIN.md). Then [`tests/test_fxa_browser.py`](/tests/test_fxa_browser.py) does the same with a real Firefox (Mozilla's build, in [`tests/browser`](/tests/browser)): one profile signs up through the accounts web pages and syncs a bookmark, a second profile signs in and must receive it. No Mozilla service is involved. With `FXA_DB=mariadb` the same runs with the accounts on MariaDB (`FXA_MARIADB_IMAGE`, default `mariadb:12.3`; fxa.yml runs it on `mariadb:12.3`, `mariadb:11.8` and `mariadb:lts`). All the tests: [TESTING.md](TESTING.md).

[`tests/fxa-upgrade.sh`](/tests/fxa-upgrade.sh) upgrades an install in place, with the steps of [Upgrades](#upgrades): it starts the stack on an older release (`FXA_FROM`), where [`tests/test_fxa_upgrade.py`](/tests/test_fxa_upgrade.py) signs up, registers a device, gets a refresh token and syncs; then a backup, the new `FXA_VERSION`, `docker compose pull` and `docker compose up -d`. With `FXA_SAME_TAG=1` the older release is installed under the new tag, as an install following `fxa-mono-latest` has it, and `docker compose up -d` without the pull must keep it. After it the migrations ran with the new image up to the levels of its `target-patch.json`, the sign-up policy and the admin UI's procedures were installed again, the old session, device and refresh token still work, the Sync data reads back on the same tokenserver user, a new sign-in and a new sign-up work, and the admin UI is all up, shows the new release and recorded each migrated schema as an event. [fxa.yml](/.github/workflows/fxa.yml) runs it from the published `fxa-mono-latest` to every new release before publishing it (amd64; not for a rebuild of a release older than the published one). It upgrades to `FXA_IMAGE:FXA_VERSION` (default: `IMAGE_REPOSITORY`, `fxa-mono-latest`) and reads the release the admin UI must show from that image, and refuses a target older than `FXA_FROM`. Our builds are in the registry of the repository whose fxa.yml built them; the examples use the development builds. Locally, e.g. from Mozilla's own image (amd64, emulated on arm64) with older schemas, from one of our older builds on MariaDB, and from an older `fxa-mono-latest`:

```bash
FXA_FROM=docker.io/mozilla/fxa-mono:v1.345.2 FXA_IMAGE=ghcr.io/porelli/firefox-sync-dev FXA_VERSION=fxa-mono-v1.347.3 tests/fxa-upgrade.sh
FXA_FROM=ghcr.io/porelli/firefox-sync-dev:fxa-mono-v1.347.1 FXA_IMAGE=ghcr.io/porelli/firefox-sync-dev FXA_DB=mariadb tests/fxa-upgrade.sh
FXA_FROM=ghcr.io/porelli/firefox-sync-dev:fxa-mono-v1.347.1 FXA_IMAGE=ghcr.io/porelli/firefox-sync-dev FXA_SAME_TAG=1 tests/fxa-upgrade.sh
# an install on MariaDB 11.8 moved to 12 with the steps of "Moving to a newer MariaDB" (the new image with mozilla/fxa#21494)
FXA_FROM=ghcr.io/porelli/firefox-sync-dev:fxa-mono-v1.347.3 FXA_IMAGE=ghcr.io/porelli/firefox-sync-dev FXA_DB=mariadb FXA_MARIADB_FROM=mariadb:11.8 FXA_MARIADB_IMAGE=mariadb:12.3 tests/fxa-upgrade.sh
```

## Credits

[jackyzy823/fxa-selfhosting](https://github.com/jackyzy823/fxa-selfhosting) has documented how to run Mozilla accounts outside Mozilla for years and was a precious reference.
