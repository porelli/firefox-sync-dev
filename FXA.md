# Self-hosted Mozilla accounts (experimental)

By default Firefox signs in with Mozilla accounts (`accounts.firefox.com`) and only the sync data is stored on your server. [docker-compose.fxa.yml](/docker-compose.fxa.yml) adds the accounts service as well, so that signing in, the account keys and the sync data all stay on your server.

⚠️ This is experimental. Mozilla does not support self-hosting its accounts service and changes it every couple of weeks.

## What you need

- The accounts image, about 5 GB unpacked: by default amd64 and arm64 builds of Mozilla's releases from this repository (`fxa-mono-latest`, the newest release that passed the tests on both architectures, built by [fxa.yml](/.github/workflows/fxa.yml) from Mozilla's sources without changes). Pin a release with `FXA_VERSION=fxa-mono-v1.347.1`, or use Mozilla's own image (amd64 only) with `FXA_IMAGE=docker.io/mozilla/fxa-mono` and `FXA_VERSION=v1.347.1`.
- 3-4 GB of RAM for the whole stack.
- An SMTP server: new accounts and new sign-ins are confirmed with a code sent by email.
- Four host names behind your reverse proxy, with HTTPS:

  | host name | `.env` | proxy to |
  |---|---|---|
  | `accounts.example.com` | `FXA_CONTENT_URL` | `127.0.0.1:3030` |
  | `api.example.com` | `FXA_AUTH_URL` | `127.0.0.1:9000` |
  | `profile.example.com` | `FXA_PROFILE_URL` | `127.0.0.1:1111`, and `/img/` to `127.0.0.1:1112/` |
  | `sync.example.com` | `SYNCSTORAGE_DOMAIN` | `127.0.0.1:${CONTAINER_EXPORT_PORT}`, as without FxA |

## Setup

1. Run `./prepare_environment.sh` and answer `y` to "Also self-host Mozilla accounts?": it asks for the domain of the host names and your SMTP server, generates the secrets, points the sync server to your accounts and sets `COMPOSE_FILE` so that `docker compose up -d` starts everything. It also writes an nginx example to `config/nginx/fxa.conf`. To do it by hand instead, fill in the `SELF-HOSTED MOZILLA ACCOUNTS` section of `.env`:
    - the three URLs above
    - a different random value for each `FXA_*_SECRET`, `FXA_FLOW_ID_KEY`, `FXA_SESSION_TOKEN_HANDLE_KEY`, `FXA_CONTENT_SESSION_SECRET` and `FXA_MYSQL_PASSWORD`
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
1. In Firefox, set `identity.fxaccounts.autoconfig.uri` to `https://accounts.example.com` in `about:config`, restart it and sign up. On Android, enable the debug menu (tap the Firefox logo 5 times in `About Firefox`), then in `Sync Debug` set `Custom Mozilla account server` to `https://accounts.example.com` and `Custom Sync server` to `https://sync.example.com/1.0/sync/1.5`. On iOS, enable it by tapping the version number 5 times in `Settings`, then in `Advanced Sync Settings` turn on `Use Custom FxA Content Server` with `Custom Account Content Server URI` set to `https://accounts.example.com`.

## What works and what doesn't

- Works and is tested: sign-up, email confirmation, sign-in, OAuth for Sync, syncing, a second device. Tested with Firefox 157 desktop: two profiles signed up and in through the accounts pages and synced bookmarks between them.
- Send tab to device uses Mozilla's public push service, as Firefox does with Mozilla accounts.
- Pairing a phone with a QR code uses Mozilla's channel server, unless you run your own: uncomment `COMPOSE_PROFILES=pairing` and `FXA_PAIRING_URL=wss://pairing.example.com` in `.env` and proxy that host name (websocket) to `FXA_PAIRING_EXPORT_PORT`, see the example in `config/nginx/fxa-example.conf`.
- Sign-in attempts are rate limited by the accounts service itself (Redis, upstream's `rate-limit-rules.txt`), e.g. 5 failed sign-ins per IP address and email in 15 minutes. The old separate customs server does not exist anymore.
- Not available: payments and subscriptions, recovery phone (SMS), sign in with Google or Apple, deferred account clean-up tasks and account event notifications (they need Google Cloud).

## Upgrades

Like the sync server, the accounts follow `latest` by default (`FXA_VERSION=fxa-mono-latest`): a new Mozilla release, about every two weeks, is published here only after the tests passed with it on amd64 and arm64, including a real Firefox signing up and syncing. The database migrations run before the services start, and cannot be undone, so:

1. Back up the `fxa-db` and `fxa-keys` volumes regularly (the keys sign every session and OAuth token).
1. To decide when to upgrade instead, pin a release: `FXA_VERSION=fxa-mono-v1.347.1`, then change it and run `docker compose up -d`.

Don't stay too far behind either: Firefox itself refuses to sign in to accounts servers that are too old for it (for example Firefox 154 needs a recent release because it switched to Bearer tokens).

## Tests

[`tests/e2e-fxa.sh`](/tests/e2e-fxa.sh) starts the stack with a test reverse proxy (Caddy, HTTPS with its own CA) and a mail catcher (Mailpit), then [`tests/test_fxa_flow.py`](/tests/test_fxa_flow.py) does what Firefox does: reads the client configuration, signs up, confirms the email, gets the keys and an OAuth token, gets a sync token from the tokenserver and syncs, then signs in again as a second device. Then [`tests/test_fxa_browser.py`](/tests/test_fxa_browser.py) does the same with a real Firefox (Mozilla's build, in [`tests/browser`](/tests/browser)): one profile signs up through the accounts web pages and syncs a bookmark, a second profile signs in and must receive it. No Mozilla service is involved.

## Credits

[jackyzy823/fxa-selfhosting](https://github.com/jackyzy823/fxa-selfhosting) has documented how to run Mozilla accounts outside Mozilla for years and was a precious reference.
