# Who can use your server

This page explains the two limits of firefox-sync: `SYNC_MAX_USERS`, how many accounts can use the Sync server, and `FXA_MAX_ACCOUNTS`, how many self-hosted accounts can be created. Set them when you install: see [the index](README.md#choose-your-path).

syncstorage-rs has no allowlist. Anybody who can reach your server and has a Mozilla account can point Firefox to it. firefox-sync limits how many accounts can use it instead. To choose who exactly, with an allowlist of emails and domains or closed sign-ups, self-host the accounts as well: only accounts created on your server can then sign in. See [Who can sign up](accounts.md#who-can-sign-up).

## The forms

Both settings take the same forms. The form says who sets the limit: the setting on every start, or the [admin UI](admin/accounts.md#limits).

| Value | The limit | In the admin UI |
|---|---|---|
| `5`, or `fixed:5` | 5, set again on every start, replacing any change | read-only |
| `initial:5` | 5, set only when there is no limit yet: the first start, or a new database | changes it, and the change is kept across restarts |
| `unlimited`, or `fixed:unlimited` | no limit, set on every start | read-only |
| `initial:unlimited` | no limit at first | changes it |
| `0` (any form) | no new account at all, on purpose | as its form says |

The number goes from 0 to 2147483647. Anything else, empty or not a number, stops the container that sets the limit, and with it the Sync server or the accounts service.

`prepare_environment.sh` asks for both, and writes `initial:` when you enable the admin UI.

## `SYNC_MAX_USERS`

The accounts that can use the Sync server (`1` in [.env-example](/.env-example)). With the Helm chart: `maxUsers` in your values, with the same forms (`"1"`).

- A trigger in the tokenserver database refuses new accounts once the limit is reached. The init container installs it, and the Sync server starts only after it did. With `unlimited` the trigger checks nothing.
- The limit counts accounts, not database rows. An account that changes its keys, for example after a password reset, is never locked out.
- A change made in the admin UI applies at once, without a restart.

## `FXA_MAX_ACCOUNTS`

With [self-hosted accounts](accounts.md): how many accounts the accounts service can have, whoever signs up and whatever the sign-up policy. Not set, or empty: `initial:unlimited`, so that existing setups do not change.

- Every row of `fxa.accounts` counts: confirmed or not, disabled too. Delete the accounts that are gone, or the old unconfirmed ones, to make room.
- `fxa-policy` sets the limit before the accounts service starts.
- When the server is full, the database refuses the account itself: "Sign-up refused: the server is full (FXA_MAX_ACCOUNTS)". Two sign-ups at once cannot both take the last place.
- With the [sign-up gate](reverse-proxy.md#sign-up-gate), the sign-up page says "This server is full: it takes no new accounts".
- Each refused sign-up is an event of the admin UI, `sign-up refused`.

## Switch between the forms

A change of form applies on the next start, like any other change:

- From `initial:5` to `5`: 5 is set again on the next start.
- From `5` to `initial:5`: the value in the database stays, and the admin UI can change it.

The next start is `docker compose up -d`. With Quadlets, after rendering the units again ([Change a setting](install/podman.md#change-a-setting)):

```bash
systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-admin.service
```

With the Helm chart: `helm upgrade` with the new `maxUsers`.

## Near and full

The admin UI warns twice for each limit:

- **near the limit**, from 90% of the places taken;
- **full**, when every place is taken.

Both show on the overview and in [Needs attention](admin/monitoring.md#needs-attention), and alert once when the state changes, also back under 90%. `0` never warns, since it is on purpose, and `unlimited` has nothing to warn about. Prometheus has both states as metrics: see [Prometheus](admin/monitoring.md#prometheus).
