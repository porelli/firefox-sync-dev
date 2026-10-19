# Admin UI

A small web page to manage who can use your server, optional (`COMPOSE_PROFILES=admin`; with the Helm chart `admin.enabled`, see [Kubernetes](#kubernetes)):

- **Sync**: how many accounts use the server against max users, change the maximum (a number or no limit) without restarting anything (with `SYNC_MAX_USERS=initial:N`, see [Max users](#max-users)).
- **Sign-ups**, with [self-hosted accounts](FXA.md): anybody, only some emails and domains (allowlist), or nobody, and how many accounts can be created at most (`FXA_MAX_ACCOUNTS`, see [Max accounts](#max-accounts-self-hosted-accounts)). The emails of the allowlist say whether they signed up yet, and each one can be removed (after a confirm page).
- **Invitations**, with self-hosted accounts: an email with the link to create the account and the steps to set up Firefox, and the address added to the allowlist. **Connect a device**: the same steps on a page, with this server's values. See [Invitations](#invitations-and-connect-a-device).
- **Accounts**, with self-hosted accounts: who signed up, when they last synced and how much they store, disable and re-enable an account, sign it out everywhere.
- **Per account**: what it stores on the Sync server per collection (bookmarks, history, passwords...: items, size, last change; the data itself is encrypted by Firefox, the server cannot read it) and, with self-hosted accounts, its devices and sessions (confirmed or not, and when they were really last used), how it signs in and its emails, see [Helping account owners](#helping-account-owners).
- **Sync data of an account**: every row the tokenserver has for it (one per set of keys) with what each stores, and what looks wrong there in plain words; start its Sync data over, all of it or one collection, optionally freeing its max users slot; find an account by email, account id or tokenserver uid. See [Sync data of an account](#sync-data-of-an-account).
- **Delete an account for good**, a disabled one, with its Sync data (with Mozilla's accounts: the Sync data of an account id). See [Deleting an account](#deleting-an-account).
- **Storage**: live, expired and orphaned data (replaced keys, deleted accounts, storage with no tokenserver row), stale uploads, the largest accounts, and a purge, by hand or every day (`ADMIN_PURGE=1`). See [Storage](#storage).
- **Maintenance**, with self-hosted accounts: expired tokens and codes pruned every day, old unconfirmed accounts deleted (`ADMIN_DELETE_UNCONFIRMED_DAYS`), an alert on a burst of sign-ups (`ADMIN_SIGNUP_BURST`). See [Maintenance and retention](#maintenance-and-retention).
- **Notes**: a note per account, up to 500 characters, shown in the accounts list; with Mozilla's accounts it is the label next to the bare account id.
- **Activity**: Sync requests, Sync tokens issued, errors (and the errors by kind: Hawk authentication, invalid requests, tokens refused...) and the size of the databases over the last 24 hours, 7 or 30 days, an alert on a spike of errors and on a database growing fast (see [Errors and growth](#errors-and-growth)), and an event log: sign-ins to the admin UI, changes made in it (who, how they signed in, on which account), refused sign-ups, components going down and up, new releases and, with self-hosted accounts, new accounts and new devices. Filter it by kind and by text (an email), hide the routine admin sign-ins, page back through all of it.
- **Health**: whether each component answers (Sync server, databases, and the accounts services), the versions running and whether a newer release is out, the schema of each database (the accounts databases have no time: FxA records only the patch level, the table says "not recorded by FxA"). The limits too: the accounts against max users and max accounts, a warning ("near the limit") from 90% and another ("full") when every place is taken. Also the SMTP server, whether the notifications of the alerts get through, and what the internet sees: the public https URLs, their certificates, the sign-up gate behind your reverse proxy, see [Public checks](#public-checks).
- **Setup checks**: settings that must agree, with what goes wrong when they do not: the Sync node and `SYNC_PUBLIC_URL`, `FXA_OAUTH_SERVER_URL`, `FXA_EMAIL_DOMAIN`; the accounts on each Sync node. See [Setup checks](#setup-checks).
- **Configuration** (in the menu): what the stack runs with, read-only, by part (public URLs, Sync and its databases, the accounts, the limits, signing in, email, alerts, backups, maintenance, metrics), with where each value comes from, and the settings that disagree. Secrets are never shown, only whether they are set. See [Configuration](#configuration).
- **Needs attention**, a banner at the top of the overview: what to look at now, one line each with a link to where it is fixed, or "Everything is working". A health light on every page ("All up", "1 part to check", "2 parts down") links to the Health part of the overview. See [Needs attention](#needs-attention).
- **Backups**, optional (`COMPOSE_PROFILES=backup`, Helm: `backup.enabled`): every night a dump of each database into a volume, the last one on the overview with what is backed up, when (`BACKUP_TIME`), how many are kept (`BACKUP_KEEP`), where, how to make one now, how to turn them on and where the restore steps are, an alert when one fails or is too old. See [Backups](#backups).
- **Search the accounts** on the overview: part of an email, an account id, a tokenserver uid or a note; the list shows 50 accounts a page, newest first. See [Finding an account](#finding-an-account).
- **Inactive and unconfirmed accounts** are marked in the list: not synced for `ADMIN_STALE_DAYS` (90), or email never confirmed after 3 days. Inactive accounts are only marked, never deleted by themselves; old unconfirmed ones can be, see [Maintenance and retention](#maintenance-and-retention). With self-hosted accounts also `2-step` (two-step authentication on), `no recovery key`, `unconfirmed sign-in` (a sign-in that never entered its email code), `blocked` (by the rate limits) and `inactive device` (a device not used for `ADMIN_STALE_DAYS`, marked `inactive` on the account page).
- **Security**, with self-hosted accounts: who the accounts service is blocking after too many attempts (wrong passwords, codes), and who is getting close. Lift a block, e.g. when it is you, there or on the account page. An alert when an existing account gets blocked.
- **Sign out a device or a session** of an account, e.g. a lost laptop, without disabling the whole account.
- **Alerts** by email and/or to Slack, Discord, Microsoft Teams, ntfy, Gotify, Telegram, Matrix or any webhook (no SMTP server needed for those), a test email and a test notification, and **Prometheus metrics**, see below.
- **Confirm pages**: disabling, signing out everywhere, signing out a device or a session, turning off two-step authentication, removing a recovery key, confirming an email, resetting or deleting Sync data, deleting an account, purging the storage, deleting unconfirmed accounts, pruning the accounts database and removing an email or a domain from the allowlist first show what will happen (the account, the devices and sessions that get signed out), with an optional reason for the event log. Nothing destructive happens in one click; what stays one click is listed in [Confirm pages](#confirm-pages).
- **Local time** (`ADMIN_TZ`), **phones** and **dark mode**: on a narrow screen the side menu becomes tabs at the top and each table row becomes a card; light or dark follows the system setting. No JavaScript: plain links and forms.

With Mozilla's accounts there are no sign-ups to control and the server only knows account ids: the page shows the Sync part only.

The image (`ghcr.io/porelli/firefox-sync:admin-latest`, amd64 and arm64) is built from [admin/](/admin): a single Go program in a distroless image, no shell, running as an unprivileged user. Its only dependencies are the MariaDB/MySQL and PostgreSQL drivers, and for single sign-on [go-oidc](https://github.com/coreos/go-oidc) and [golang.org/x/oauth2](https://pkg.go.dev/golang.org/x/oauth2).

## Screenshots

A small demo server with self-hosted accounts: three people with their devices, one more invited (rebuilt with [tests/demo_seed.py](/tests/demo_seed.py), see [TESTING.md](TESTING.md#the-demo-of-the-screenshots)).

The overview: nothing needs a look, the health, Sync places, accounts, Sync data and backups at a glance, then the accounts with their last sync, what they store and how they sign in (`2-step`), and a note:

![Overview](docs/images/admin/overview.png)

Sign-ups on an allowlist (a domain and some emails), max accounts, and the invitations: who was invited and whether they signed up yet:

![Sign-ups and invitations](docs/images/admin/signups.png)

One account: its status, devices and sessions, how it signs in, its note; further down its Sync data per collection, its emails and its security history:

![Account](docs/images/admin/account.png)

The health of each part, with the versions running, the databases, the email server and the public URLs with their certificates:

![Health](docs/images/admin/health.png)

With Mozilla's accounts the server knows only account ids, the notes say whose they are:

![Overview with Mozilla's accounts](docs/images/admin/overview-sync-only.png)

Also: [Activity](docs/images/admin/activity.png) (Sync requests, tokens, errors and database sizes over time, then the event log), [Configuration](docs/images/admin/configuration.png) (what the stack runs with, by part, and whether the settings agree), [Connect a device](docs/images/admin/connect.png) (the steps for Firefox with this server's values) and [the overview on a phone](docs/images/admin/overview-phone.png) (390 pixels wide: tabs at the top, cards for the rows).

## Setup

`./prepare_environment.sh` asks "Enable the admin UI?" (default yes), generates `ADMIN_PASSWORD`, sets `COMPOSE_PROFILES=admin` and `SYNC_MAX_USERS=initial:<the number you gave>` in `.env`; with self-hosted accounts it also offers to sign in with them, see [Signing in](#signing-in). By hand:

```
COMPOSE_PROFILES=admin             # with the pairing server: admin,pairing
ADMIN_PASSWORD=<at least 12 characters, random>
ADMIN_EXPORT_PORT=127.0.0.1:8090
ADMIN_DB_PASSWORD=<random, letters and digits>   # its own database users, see below
```

then `docker compose up -d`. With Quadlets, starting `firefox-sync-syncstorage.service` also starts `firefox-sync-admin.service`.

The admin UI has two database users of its own, both with `ADMIN_DB_PASSWORD`: `ffs_admin_ui`, which alone reaches its own database `ffs_admin` (the event log, the audit trail, the notes), and `ffs_admin_sync`, which reads the Sync data and has nothing on `ffs_admin`, so that no code the Sync server's user can put in its databases ever runs with the rights on the audit trail. The Sync server's users cannot read or change it, see [The admin UI's own database](DATABASES.md#the-admin-uis-own-database) for what each user may do. The stack's database containers create them; on [your own database server](DATABASES.md) `database-setup.sql` does, and with self-hosted accounts `database-setup-fxa.sql` creates the admin UI's user of the accounts database, also named `ffs_admin` (`FXA_ADMIN_DB_PASSWORD`; the sign-up policy gives it its grants), another thing than the database `ffs_admin` of `ADMIN_DB_NAME` above, which only `ADMIN_DB_USER` reaches: nothing else to set up. An install from before `ADMIN_DB_PASSWORD` keeps its tables in the tokenserver database, and its setup check fails, until `./prepare_environment.sh --upgrade` sets one (with the Quadlets: `./prepare_environment.sh` again, as [MIGRATING.md](MIGRATING.md#older-firefox-sync-releases) says): [how they move](DATABASES.md#an-install-from-before).

The admin UI listens on `ADMIN_EXPORT_PORT`, `127.0.0.1:8090` by default: the server itself only. The simplest and safest way to reach it from your computer is an SSH tunnel, without publishing it at all:

```bash
ssh -L 8090:127.0.0.1:8090 your-server
```

and open `http://localhost:8090`. To publish it behind nginx instead, restrict it to your own addresses and keep the `Host` header (the forms check that they are posted from the same site):

```nginx
server {
  server_name admin.example.com;
  listen 443 ssl;
  # ssl_certificate ...
  allow 192.0.2.0/24;  # your network
  deny all;
  location / {
    proxy_pass http://127.0.0.1:8090;
    proxy_set_header Host $http_host;
  }
}
```

Sign-in: `ADMIN_PASSWORD` from `.env` (Kubernetes: from the Secret), or single sign-on, see [Signing in](#signing-in). The session cookie is `Secure`, `HttpOnly` and `SameSite=Strict`, every form carries a token of the session, and after 5 wrong passwords in a minute sign-ins wait a minute. Sessions last 12 hours and end when the container restarts. Over plain HTTP other than `localhost`, set `ADMIN_INSECURE_COOKIE=1` (not recommended).

### Kubernetes

With the [Helm chart](HELM.md#the-admin-ui): `admin.enabled: true` in your values, and the settings of this page under their names there (`admin.alertEmail` for `ADMIN_ALERT_EMAIL`, `admin.smtp.*` for `FXA_SMTP_*`, `admin.oidc.*` for `ADMIN_OIDC_*`, `admin.notify` for `ADMIN_NOTIFY`..., each in [values.yaml](/charts/firefox-sync/values.yaml)), then `helm upgrade`. `ADMIN_PASSWORD` and `ADMIN_DB_PASSWORD` are in the chart's Secret (or your `existingSecret`), generated unless you set `admin.password`:

```bash
kubectl get secret ffs-firefox-sync -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d
kubectl port-forward svc/ffs-firefox-sync-admin 8090:8080   # then http://localhost:8090
```

(`ffs` is the release name.) It is not published; `admin.ingress` gives it an Ingress of its own, never on the Sync server's host, behind your own sign-in. The chart tells it that it runs on Kubernetes (`ADMIN_DEPLOYMENT=kubernetes`, with the release, its namespace, the prefix of its objects and the Secret): its pages then give `kubectl` and `helm upgrade` commands and the names of the values instead of `.env` and docker compose: the password hint of the sign-in page, a backup now and turning the backups on, restarting the Sync server, the limits and alerts, the Configuration page (the values, named as the variables of `.env`) and the setup checks. There is no setup check of the old names of `.env`, which the chart does not have.

## Max users

`SYNC_MAX_USERS` in `.env` (with the Helm chart `maxUsers` in your values, the same forms) says who sets the limit:

| `SYNC_MAX_USERS` | the init container | the admin UI |
|---|---|---|
| `5` or `fixed:5` | sets 5 on every start, replacing any change | read-only |
| `initial:5` | sets 5 only when there is no limit yet (first start, new database) | changes it, and they are kept across restarts |
| `unlimited` (or `fixed:unlimited`), `initial:unlimited` | no limit, set the same way | read-only, or changes it |

The value is a number from 0 to 2147483647 or `unlimited`; `0` lets no new account in at all (on purpose: never a warning). The page takes a number, or "No limit" (which wins over the number), and shows "unlimited" then. The limit applies at once either way: a trigger of the tokenserver database checks it for every new account (with `unlimited` it checks nothing). The overview shows the accounts against it in the Using Sync tile, the Sync card and a `Max users` row of the health table: two warnings, "near the limit" from 90% and "full" when every place is taken, both amber and counted by the health light as "to check" and listed in [Needs attention](#needs-attention), with an alert when the state changes. Fine, the row shows the count and is not counted as a part. Switching is a change like any other: from `initial:5` to `5`, 5 is set again on the next start (`docker compose up -d`, or `systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-admin.service`); from `5` to `initial:5`, the value in the database stays and the page can change it. Anything else in `SYNC_MAX_USERS` (empty, not a number) stops the init container, and with it the Sync server.

## Max accounts (self-hosted accounts)

`FXA_MAX_ACCOUNTS` in `.env` caps how many accounts the accounts service can have, whoever signs up and whatever the sign-up policy: the same forms as `SYNC_MAX_USERS` (`N`, `fixed:N`, `unlimited`: set on every start by `fxa-policy`, read-only on the page; `initial:N`: set once, then on the page). Not set, or empty: `initial:unlimited`, so existing setups do not change. `prepare_environment.sh` asks for it last (default unlimited) and writes `initial:` with the admin UI. Anything else stops `fxa-policy`, and with it the accounts service.

Every row of `fxa.accounts` counts: confirmed or not, disabled too. Delete the accounts that are gone, or the old unconfirmed ones, to make room. The limit is in `ffs.settings` (`max_accounts`) and enforced by `ffs.signup_refusal`, the function behind `ffs.signup_allowed`: the trigger on `fxa.accounts` refuses the account ("Sign-up refused: the server is full (FXA_MAX_ACCOUNTS)", sign-ups waiting for each other on that row, so two at once cannot both take the last place), and the [sign-up gate](#who-can-sign-up-self-hosted-accounts) answers "This server is full: it takes no new accounts". The refused sign-up is an event (`sign-up refused`, "... (the server is full: FXA_MAX_ACCOUNTS)").

The overview shows it in the Accounts tile, under Sign-ups (with the form, open when near or full) and as the `Max accounts` row of the health table, near at 90%, full at 100%, like max users; Prometheus has `ffs_accounts`, `ffs_accounts_max`, `ffs_accounts_near_max` and `ffs_accounts_full`.

## Signing in

Three ways, each on when it is configured in `.env` (with the Helm chart `admin.password` or the Secret's `ADMIN_PASSWORD`, `admin.oidc.*`, `admin.trustedHeader.*` and `admin.allowed.*`), any combination; with none of them the admin UI does not start. Whatever the way, you get the same session, and the event log (and the alerts) record who signed in and how: `signed in: alice@example.com (oidc)`, `signed in: alice@example.com (header)` or `signed in (password)`. Refused sign-ins (a wrong password, not an admin, email not verified, a sign-in that did not start here) are logged too, as `sign-in` events: anybody can cause those, so they have their own share of the event log and the alerts, and cannot push the sign-ins and the changes out. A callback with no state cookie is not logged at all, a bad state at most every 10 minutes.

| | `.env` | |
|---|---|---|
| password | `ADMIN_PASSWORD` | at least 12 characters. Empty: no password form |
| OpenID Connect | `ADMIN_OIDC_*` | a "Sign in with ..." button, your identity provider (or the self-hosted accounts) says who you are |
| trusted header | `ADMIN_AUTH_HEADER`, `ADMIN_TRUSTED_PROXIES` | the reverse proxy in front signs you in (Authelia, Authentik, oauth2-proxy, Tailscale, Cloudflare Access...) and passes your email in a header |

With OpenID Connect or the header, only the users you list are admins, everybody else the provider knows is refused:

```
ADMIN_ALLOWED_USERS=alice@example.com,@example.org   # emails and @domains, like FXA_SIGNUP_ALLOWLIST
ADMIN_ALLOWED_GROUPS=ffs-admins                      # and/or groups of the provider
```

With neither set, the admin UI refuses to start rather than let in anybody the provider knows.

### OpenID Connect (OAuth 2.0)

The admin UI is a regular OpenID Connect client (authorization code flow with PKCE, state and nonce). Create a client ("application") at your provider with the redirect URI `https://admin.example.com/auth/callback` (the public address of the admin UI, exactly), then:

```
ADMIN_OIDC_ISSUER=https://id.example.com           # the provider's issuer, it serves /.well-known/openid-configuration
ADMIN_OIDC_CLIENT_ID=...
ADMIN_OIDC_CLIENT_SECRET=...                       # empty for a public client (PKCE only)
ADMIN_OIDC_REDIRECT_URL=https://admin.example.com/auth/callback
ADMIN_OIDC_NAME=Authentik                          # the button: "Sign in with Authentik" (default: single sign-on)
# optional
ADMIN_OIDC_SCOPES=openid email profile             # the default; add groups for providers that want it
ADMIN_OIDC_GROUPS_CLAIM=groups                     # the default, the claim with the groups for ADMIN_ALLOWED_GROUPS
```

The email comes from the ID token, or from the provider's userinfo endpoint when the ID token has none, and only counts when the provider says it is verified (`email_verified: true`). An ID token without the nonce is accepted only from a provider whose discovery lists `S256` in `code_challenge_methods_supported` (it checks the PKCE verifier, which then ties the sign-in to the browser), or from the self-hosted accounts (`ADMIN_OIDC_ISSUER` equal to `FXA_CONTENT_URL`). The admin UI connects to the provider (discovery, keys, tokens, userinfo), so the container must be able to reach the issuer's URLs. Publish the admin UI on its own host name behind your reverse proxy (see above): the browser comes back to it from the provider. With providers that accept `http://localhost` redirects, `ADMIN_OIDC_REDIRECT_URL=http://localhost:8090/auth/callback` also works through the SSH tunnel.

<details><summary>Authentik</summary>

Applications > Create with provider: OAuth2/OpenID Provider, client type Confidential, redirect URI (strict) `https://admin.example.com/auth/callback`, signing key set (RS256). Then `ADMIN_OIDC_ISSUER=https://authentik.example.com/application/o/<application slug>/` (with the final `/`, as shown under "OpenID Configuration Issuer"). The groups are in the `groups` claim of the default `profile` scope: `ADMIN_ALLOWED_GROUPS=<group name>`. Check that the `email` scope mapping in use sends `email_verified: true` for your users, or allow by group.
</details>

<details><summary>Keycloak</summary>

In your realm: Clients > Create client, OpenID Connect, Client authentication on, Standard flow only, Valid redirect URIs `https://admin.example.com/auth/callback`, and in Advanced, PKCE method S256. `ADMIN_OIDC_ISSUER=https://keycloak.example.com/realms/<realm>`, the secret is in Credentials. Groups: Client scopes > `<client>-dedicated` > Add mapper > Group Membership, token claim name `groups`, Full group path off. `email_verified` is the user's "Email verified" switch.
</details>

<details><summary>Authelia (as OpenID Connect provider)</summary>

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: ffs-admin
        client_name: Firefox Sync admin
        client_secret: '$pbkdf2-sha512$...'   # authelia crypto hash generate pbkdf2 --random
        public: false
        authorization_policy: two_factor
        require_pkce: true
        pkce_challenge_method: S256
        redirect_uris: [https://admin.example.com/auth/callback]
        scopes: [openid, email, profile, groups]
        token_endpoint_auth_method: client_secret_basic
```

`ADMIN_OIDC_ISSUER=https://auth.example.com`, `ADMIN_OIDC_CLIENT_SECRET=` the secret before hashing, `ADMIN_OIDC_SCOPES=openid email profile groups` for `ADMIN_ALLOWED_GROUPS`.
</details>

<details><summary>Google</summary>

Google Cloud console > APIs & Services > Credentials > Create OAuth client ID, Web application, authorized redirect URI `https://admin.example.com/auth/callback`. `ADMIN_OIDC_ISSUER=https://accounts.google.com`, `ADMIN_OIDC_NAME=Google`. Google has no groups in its tokens: list the admins in `ADMIN_ALLOWED_USERS` (`@yourcompany.com` for a Google Workspace domain, never `@gmail.com`: that is anybody with a Gmail address).
</details>

<details><summary>Microsoft Entra ID</summary>

App registrations > New registration, single tenant, redirect URI platform Web `https://admin.example.com/auth/callback`; Certificates & secrets > New client secret. `ADMIN_OIDC_ISSUER=https://login.microsoftonline.com/<tenant id>/v2.0` (your tenant, not `common` or `organizations`), `ADMIN_OIDC_NAME=Microsoft`. Entra sends no `email_verified`, and the `email` of an account can be set to any address, so do not allow by email: Token configuration > Add groups claim > Security groups, then `ADMIN_ALLOWED_GROUPS=<object id of the group>` (Entra sends group ids, not names).
</details>

<details><summary>Dex, and GitHub</summary>

GitHub signs in apps with OAuth but is not an OpenID Connect provider: go through [Dex](https://dexidp.io) (below) or oauth2-proxy (see the trusted header). In Dex's config:

```yaml
staticClients:
  - id: ffs-admin
    name: Firefox Sync admin
    secret: <random>
    redirectURIs: [https://admin.example.com/auth/callback]
connectors:
  - type: github
    id: github
    name: GitHub
    config:
      clientID: <GitHub OAuth app>
      clientSecret: <...>
      redirectURI: https://dex.example.com/callback
      orgs: [{name: your-org, teams: [ffs-admins]}]
```

`ADMIN_OIDC_ISSUER=https://dex.example.com` (Dex's `issuer`), `ADMIN_OIDC_SCOPES=openid email profile groups`, `ADMIN_ALLOWED_GROUPS=your-org:ffs-admins`. Dex marks GitHub's primary email as verified.
</details>

<details><summary>The self-hosted Mozilla accounts</summary>

With [self-hosted accounts](FXA.md) the accounts service is an OpenID Connect provider too. `prepare_environment.sh` asks "Sign in to the admin UI with these accounts?" (the admins' emails) and the host name of the admin UI (`admin.<your domain>`), then sets it all up, with an nginx server for that host in `config/nginx/fxa.conf`. By hand:

```
ADMIN_FXA_CLIENT_ID=<16 random hex characters>     # e.g. openssl rand -hex 8
ADMIN_OIDC_REDIRECT_URL=https://admin.example.com/auth/callback
ADMIN_ALLOWED_USERS=alice@example.com
ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true
```

The accounts service registers the admin UI as an OAuth client at every start (`config/fxa/oauth-clients.js`): trusted (no consent screen), public (PKCE, `ADMIN_FXA_CLIENT_SECRET` stays empty: the accounts service refuses PKCE from clients with a secret), scopes `openid profile email`. With docker compose the admin UI then uses `ADMIN_OIDC_ISSUER=FXA_CONTENT_URL` and this client, named "Mozilla account", unless the `ADMIN_OIDC_*` are set; with Quadlets set `ADMIN_OIDC_ISSUER`, `ADMIN_OIDC_CLIENT_ID` and `ADMIN_OIDC_NAME` too (`prepare_environment.sh` writes them all to `.env`).

The accounts service has no `email_verified` claim (its ID tokens have no email, its userinfo endpoint `FXA_PROFILE_URL/v1/profile` returns the account's email alone), hence `ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true`. That is safe here: the stack lists the admin UI's client in the accounts service's `SERVICES_WITH_EMAIL_VERIFICATION`, so it hands out a sign-in only for a confirmed session (the email code of a new account or of a new sign-in), never for a password alone. The admin UI reaches the accounts by their public URLs (`FXA_CONTENT_URL`, `FXA_AUTH_URL`, `FXA_PROFILE_URL`), through your reverse proxy: the server must be able to reach its own public host names.
</details>

### Trusted header (forward auth)

When a reverse proxy already signs people in, the admin UI can take the user from a header the proxy sets:

```
ADMIN_AUTH_HEADER=Remote-Email           # the header with the user's email
ADMIN_AUTH_GROUPS_HEADER=Remote-Groups   # optional: comma-separated groups, for ADMIN_ALLOWED_GROUPS
ADMIN_TRUSTED_PROXIES=172.18.0.1/32      # required: the proxy's address as the admin UI sees it
```

Anybody who can send a request to the admin UI can send that header, so:

- The header counts only on connections whose own address (not `X-Forwarded-For`) is in `ADMIN_TRUSTED_PROXIES`, from anywhere else it is ignored. With a proxy on the host and the admin UI published on `127.0.0.1:8090`, the admin UI sees the gateway of the compose network (`docker network inspect <project>_default -f '{{(index .IPAM.Config 0).Gateway}}'`, the project being the directory name unless `COMPOSE_PROJECT_NAME` says otherwise). With Podman it depends on the network backend (rootlessport, pasta): check from which address the requests of your proxy arrive. Then any program on the host, and anybody with an SSH tunnel to it, connects from that address too: trust a whole host only if you trust everybody on it. A proxy running as a container on the stack's network, with a fixed address and the admin UI not published at all, narrows it down to that proxy. On Kubernetes the admin UI sees the address of the Ingress controller's pod: `admin.trustedHeader.trustedProxies` is the controller's pod addresses, and every other pod of the cluster can reach the admin UI's Service directly unless a NetworkPolicy of yours allows only the controller (the chart has none).
- **Use the header only with `ADMIN_EXPORT_PORT` on a loopback address** (the default `127.0.0.1:8090`), or with the admin UI not published and the proxy a container with a fixed address on the stack's network. Published on another address (`0.0.0.0:8090`, a LAN address), the port forwarders (Podman's rootlessport, Docker's docker-proxy, and IPv6 clients of an IPv4-only container) make every client, from anywhere, arrive from the same address as your proxy: trusting it then trusts everybody, who can send `Remote-Email: admin@...` themselves. With the proxy on another machine, use OpenID Connect instead.
- The proxy must set the header itself on every request and drop the one the client sends, and the same for the groups header: a groups header the client can send makes anybody the proxy lets in an admin. nginx's `proxy_set_header` replaces it (and leaves it out when the value is empty); check your proxy does the same. Leave `ADMIN_AUTH_GROUPS_HEADER` empty when your proxy sets no groups header (Tailscale, `cloudflared`). A header sent twice (a proxy that appends instead of replacing) is refused: no user, or no groups.
- The user must be plain ASCII (other characters could pass for the letters of an allowed address); it is compared without case.
- The session follows the header: when it names another user, or disappears, the session ends.

Authelia, with nginx (Authelia's [nginx integration](https://www.authelia.com/integration/proxies/nginx/), `Remote-Email` and `Remote-Groups`):

```nginx
server {
  server_name admin.example.com;
  listen 443 ssl;
  # ssl_certificate ...

  location /internal/authelia/authz {
    internal;
    proxy_pass http://127.0.0.1:9091/api/authz/auth-request;
    proxy_set_header X-Original-Method $request_method;
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Content-Length "";
    proxy_set_header Connection "";
    proxy_pass_request_body off;
  }

  location / {
    auth_request /internal/authelia/authz;
    auth_request_set $user_email $upstream_http_remote_email;
    auth_request_set $user_groups $upstream_http_remote_groups;
    auth_request_set $redirection_url $upstream_http_location;
    error_page 401 =302 $redirection_url;
    # replaces whatever the client sent
    proxy_set_header Remote-Email $user_email;
    proxy_set_header Remote-Groups $user_groups;
    proxy_set_header Host $http_host;
    proxy_pass http://127.0.0.1:8090;
  }
}
```

oauth2-proxy (any OAuth provider, GitHub too: `--provider=github --github-org=your-org`), started with `--reverse-proxy --set-xauthrequest`; `ADMIN_AUTH_HEADER=X-Auth-Request-Email`, `ADMIN_AUTH_GROUPS_HEADER=X-Auth-Request-Groups`:

```nginx
server {
  server_name admin.example.com;
  listen 443 ssl;
  # ssl_certificate ...

  location /oauth2/ {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Scheme $scheme;
  }
  location = /oauth2/auth {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Scheme $scheme;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
  }

  location / {
    auth_request /oauth2/auth;
    error_page 401 =403 /oauth2/sign_in;
    auth_request_set $user_email $upstream_http_x_auth_request_email;
    auth_request_set $user_groups $upstream_http_x_auth_request_groups;
    proxy_set_header X-Auth-Request-Email $user_email;
    proxy_set_header X-Auth-Request-Groups $user_groups;
    proxy_set_header Host $http_host;
    proxy_pass http://127.0.0.1:8090;
  }
}
```

Tailscale: `tailscale serve --bg http://127.0.0.1:8090` publishes the admin UI on your tailnet only (`https://<machine>.<tailnet>.ts.net`), and sets `Tailscale-User-Login` to the signed-in tailnet user, replacing any the client sends: `ADMIN_AUTH_HEADER=Tailscale-User-Login`, `ADMIN_ALLOWED_USERS=` the logins (an email, or e.g. `alice@github` for GitHub accounts). Not with Funnel, which is public and has no user. Behind nginx instead, `tailscale nginx-auth` answers its `auth_request` with the user in `Tailscale-User`: pass it on with `proxy_set_header` as in the examples above. `ADMIN_TRUSTED_PROXIES` as above: the requests come from `tailscaled` on the host.

Others work the same way, e.g. Authentik's proxy outpost (`X-authentik-email`; its groups header is separated by `|`, allow by email). Cloudflare Access: prefer OpenID Connect (Cloudflare Access can be an OpenID Connect provider, "SaaS application"). Its `Cf-Access-Authenticated-User-Email` header through `cloudflared` is only vouched for on hostnames and paths an Access application covers, and the admin UI does not check Cloudflare's signed `Cf-Access-Jwt-Assertion`: a tunnel ingress rule (another hostname, a catch-all, a bypass policy) that reaches the admin UI without Access lets anybody send the header from `cloudflared`'s address.

### Security notes

- Fail closed: OpenID Connect or the header without `ADMIN_ALLOWED_USERS` or `ADMIN_ALLOWED_GROUPS`, the header without `ADMIN_TRUSTED_PROXIES`, or no way to sign in at all, and the admin UI does not start.
- An email counts only when the provider says it is verified. `ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true` turns that off: then whoever can set an address at the provider (their own profile, another tenant) can become that admin. Use it only with providers where users cannot pick their email, such as the self-hosted accounts above.
- `@domain` in `ADMIN_ALLOWED_USERS` admits every account of that domain at the provider: right for your company's domain, wrong for a public one.
- Keep the password (`ADMIN_PASSWORD`) as a way in when the provider is down, or empty it to allow single sign-on only. Every sign-in, whatever the way, is in the event log and the alerts.

## Metrics and the event log

The Sync server (syncstorage-rs and its tokenserver) sends its statsd metrics to the admin UI over UDP (port 8125, inside the stack's network only; with the Helm chart on the admin UI's Service, which every pod of the cluster reaches unless a NetworkPolicy of yours says otherwise: the chart has none). syncstorage-rs refuses to start when its metrics host does not resolve, so it only sends them when the admin UI is running when it starts: compose and the Quadlets start the admin UI first when it is enabled, and the Sync server starts as before without it. It also looks up the address of the admin UI only then, so a new admin UI container (update, `docker compose up -d` after a change) restarts the Sync server. With the Helm chart it sends to the admin UI's Service, whose address stays when the pod is replaced; turning the admin UI on or off starts a new Sync server pod. If the activity page says no metrics arrive, restart the Sync server. syncstorage-rs only sends metrics while it serves requests (and holds them until a datagram is full), so an idle server sends nothing for hours: the metrics count as missing only when Sync data changed (the latest write of the storage database, read every round of checks) more than 10 minutes after the last metrics arrived (or after the start of the admin UI or of the Sync server, when none came since). Then the health table shows a `Sync metrics` row to check, counted by the health light; when they are fine there is no row.

Metrics are kept per minute and the event log as is, both in the admin UI's own database (`ffs_admin`, tables `ffs_metrics` and `ffs_events`, next to `ffs_account_notes` for the notes), which only its user reaches, not the Sync server's ([DATABASES.md](DATABASES.md#the-admin-uis-own-database)), for `ADMIN_RETENTION_DAYS` (30 by default). The events of kind `admin`, the audit trail, are kept for `ADMIN_AUDIT_RETENTION_DAYS` (365 by default). At most 30 entries a minute are recorded for each kind of event, except `admin`: every change is kept.

Every change made in the admin UI is recorded with who made it and how they signed in, and for an account its email and the start of its id:

```
Disabled alice@example.com (uid 3f2a1b2c) by bob@example.org (oidc): lost laptop
Max users set to 5 by admin (password)
```

`admin (password)` is whoever has `ADMIN_PASSWORD`; with single sign-on or the header it is their email. The text after the colon is the reason typed on the confirm page, if any. The Activity page filters the log by kind and by text (`/activity?kind=admin&q=alice@example.com`, any case) and shows 100 events a page, with a link to the older ones; the account page links to the events of its email.

The event log holds personal data: the emails of accounts and of refused sign-ups, the emails of the admins, the reasons typed. When an account is deleted (by its owner in the account settings, or here: that event keeps its email, on purpose, for the audit trail), the events naming it stay until their retention runs out, they are not rewritten. To remove them sooner, delete them in the admin UI's database as its user, e.g. `docker compose exec tokenserver_db sh -c 'mariadb -u"$ADMIN_DB_USER" -p"$ADMIN_DB_PASSWORD" "$ADMIN_DB_NAME"'` (`mysql` with `SYNC_DB=mysql`; PostgreSQL: `docker compose exec postgres_db psql -U ffs_admin_ui ffs_admin`), then `DELETE FROM ffs_events WHERE detail LIKE '%alice@example.com%';`.

## Errors and growth

The Activity page lists the errors of the Sync server by kind over its range (`/activity#errors`): the kind, the status Firefox got, the service, how many, the last one and the statsd metric it comes from. What syncstorage-rs (0.23) sends, as captured from its packets ([admin/testdata/statsd-packets.jsonl](/admin/testdata/statsd-packets.jsonl)):

- a counter per client error of the storage API: `syncstorage.request.error.hawk.*` (401: no or a wrong Hawk header, an expired Sync token), `syncstorage.request.validate.*`, `.process.*` and `.store.*` (400: an item that is no JSON object, one too large, a bad batch), `syncstorage.request.error.invalid_content_type` (415), and `storage.conflict` (503) and `storage.quota.at_limit` (403) when they happen. Without an endpoint or a status: the kind is in the name, the status is the one syncstorage-rs answers for it;
- for the tokenserver no error at all (the combined server only counts the storage API's): the admin UI counts the **tokens refused**, the token requests verified (`syncstorage.token_verification`) without a token issued (`syncstorage.token_creation`): a bad or old sign-in, an older generation or keys, a client state that does not fit, max users full, a database error (401, or 500), one row for all of them since syncstorage-rs does not tell them apart. It sends its metrics when 512 bytes are buffered, so a token often comes a datagram (and a minute) after its verification: the tokens issued pay off the verifications left over before them, and those of the newest minute count once something newer comes in. A request without any token is not counted;
- nothing for its 5xx, so a database that is down shows in the Health table instead, and nothing for 404 or 412, which are answers (an empty collection, a change from another device).

The Errors chart counts the same, the Sync requests chart only the requests served (not the errors). Prometheus has `ffs_sync_errors_total{service,status,kind}` since the admin UI started, `kind` the metric without `syncstorage.` (`request.error.hawk.missing_header`). Not the tokens refused: verified minus issued goes down when a token comes after its verification, which a counter must not do (`rate()` would see a reset). Subtract the two counters instead, e.g. `increase(ffs_statsd_total{name="syncstorage_token_verification"}[1h]) - ignoring(name) increase(ffs_statsd_total{name="syncstorage_token_creation"}[1h])`.

Two thresholds alert, through the event log (kind `attention`) and the alert emails, once when they start and once when they end, and show as a row of the health table and a line of [Needs attention](#needs-attention):

- **A spike of errors**: every round of checks (`HEALTH_CHECK_SECONDS`, a minute) the errors of the last 15 minutes against the requests (served, refused and failed). A spike is `ADMIN_ERROR_RATE_PERCENT` (10) percent or more, with at least `ADMIN_ERROR_RATE_MIN_ERRORS` (20) errors, so a small server does not alert on one error in two requests, and 3 times the share of the 24 hours before, so a server that always refuses some old Firefox does not alert all day. It ends under half of either. The health row `Sync error rate` says the last 15 minutes when it is fine; `ADMIN_ERROR_RATE_PERCENT=0` turns it off (no row). Prometheus: `ffs_sync_error_ratio` (0 to 1) and `ffs_sync_error_spike`.
- **A database growing fast**: every hour, after measuring the databases, the growth of each in the last 24 hours, from the sizes kept (`ffs_gauges`, `ADMIN_RETENTION_DAYS`). On MySQL (`SYNC_DB=mysql`, and the accounts databases on MySQL) the admin UI reads the sizes past the day-long cache of `information_schema` (`information_schema_stats_expiry = 0` for its session); InnoDB still updates them only when it recomputes the statistics of a table (after about 10% of its rows changed), so a small growth can show an hour or two late. MariaDB and PostgreSQL measure the size of now. It alerts above `ADMIN_DB_GROWTH_MB` (1024) a day, or above `ADMIN_DB_GROWTH_FACTOR` (5) times its usual growth: the median of the 7 days before, once there are 3 of them, and from 100 MB a day (a database that grows 5 times 1 MB is no news). Nothing is compared before a day of measures, while the admin UI was off a day ago (no measure within 2 hours), and shrinking is no growth. The health row `Database growth` shows each database's growth in the last day; `0` turns either rule off, both `0` the row. Prometheus: `ffs_database_growth_bytes{database}` and `ffs_database_growth_alert{database}`.

## Time zone

The pages and the alerts show times in UTC. Set `ADMIN_TZ` to a name of the [tz database](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones), e.g. `ADMIN_TZ=Europe/Rome`, for local time (`TZ` works too, `ADMIN_TZ` wins). Each page says the zone once at the bottom, each alert once at the end. A name the admin UI does not know is logged as a warning, and the times stay in UTC. The admin UI carries its own copy of the tz database (the image has none).

## Alerts

The admin UI alerts you when a sign-up is refused, a component goes down or comes back, a new release is out, a database schema changes, someone signs in to the admin UI (or fails to) or changes something there (sign-up policy, max users, max accounts, disabling and enabling, signing out, lifting a block, two-step authentication, recovery keys, confirming an email, notes, invitations), a backup fails or gets older than 36 hours (and works again), 90% of max users or of max accounts are taken and when all are (and under 90% again), Sync data changes without metrics from the Sync server, alerts fail, the Sync errors spike, a database grows fast (each of these once when it starts and once when it ends, see [Errors and growth](#errors-and-growth)), and with self-hosted accounts when an account or a device is added or an account gets blocked by the rate limits, and with [the security history](#security-history) on when the password, the primary email or a way to sign in or to recover an account changes (kind `security`). Alerts are collected and sent at most every 10 minutes (`ALERT_INTERVAL_SECONDS`), as one message. At most 20 alerts of each kind go in one (sign-ins and changes in the admin UI are one kind, `admin`), the rest are counted; the emails of refused sign-ups are shortened and stripped of line breaks, those that do not look like an email are recorded as "invalid email".

They go by email (`ADMIN_ALERT_EMAIL`), to the destinations of `ADMIN_NOTIFY`, or both: each gets every alert.

### Do I need an SMTP server?

- **For the alerts, no**: set `ADMIN_NOTIFY` instead of (or besides) `ADMIN_ALERT_EMAIL`. Without self-hosted accounts and with `ADMIN_NOTIFY` set, nothing complains about the missing SMTP server.
- **With self-hosted accounts, yes**: the accounts service emails a code for every new account and every sign-in on a new device, and the password resets. Without `FXA_SMTP_HOST` nobody can sign up or sign in; the setup check "Email of the accounts" says so. `ADMIN_NOTIFY` only replaces email for the admin UI's alerts.
- **Invitations and the notices to account owners** stay emails (they go to people, not to the admins): they need the SMTP server.

### By email

Set `ADMIN_ALERT_EMAIL`. The emails go through the SMTP server of `FXA_SMTP_*` in `.env`, which you fill in for alert emails even without self-hosted accounts. The password is only sent over TLS (STARTTLS, or `FXA_SMTP_SECURE=true` on port 465). `FXA_SMTP_HOST` left at its placeholder (`<REPLACE_WITH_YOUR_SMTP_SERVER>`) counts as unset.

- **Email (SMTP)** in the Health table: every hour, with `FXA_SMTP_HOST` set, the admin UI connects to the SMTP server, starts TLS and signs in, then leaves without sending anything. A wrong password or a server that does not answer turns it down: an event, and an alert, which goes out once the server works again (alerts that could not be sent wait, at most 20 of each kind, the newest; the rest are counted by kind). While it is down it tries again every 10 minutes, not every minute: some servers block an address after a few wrong passwords.
- An email that could not be sent is kept and goes out with the next one (up to 200 lines). The overview says when the last alert email went out, or why the last one failed and how many alerts are waiting; Prometheus has `ffs_alert_last_success_timestamp_seconds`. That is kept in memory: after a restart, "none sent since the start".
- **Send a test email**, under the Health table: one email to `ADMIN_ALERT_EMAIL`, or without it to the admin signed in with single sign-on (never to an address typed in a form). The page shows the SMTP server's answer when it fails. The test is in the event log.

### Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix, webhooks

`ADMIN_NOTIFY` is a list of destinations, one URL each, separated by commas, in single quotes in `.env`:

```sh
ADMIN_NOTIFY='ntfy://ntfy.sh/my-secret-topic,slack://hooks.slack.com/services/T000/B000/XXXX'
```

then `docker compose up -d` (Helm: `admin.notify`, a list of these URLs, and `helm upgrade`; or `./prepare_environment.sh` again with the Quadlets; it also asks for destinations, separated by commas or spaces, and turns a pasted `https://` webhook URL of Slack or Discord into `slack://` or `discord://`). The scheme says the kind; for the services that give you a webhook URL, it is that URL with `https://` replaced by the scheme:

| destination | URL | where to get it |
|---|---|---|
| Slack | `slack://hooks.slack.com/services/T…/B…/…` | an app with Incoming Webhooks (api.slack.com/apps), "Add New Webhook to Workspace". Mattermost's incoming webhooks take the same: `slack://mattermost.example.com/hooks/<key>` |
| Discord | `discord://discord.com/api/webhooks/<id>/<token>` | channel settings, Integrations, Webhooks, "Copy Webhook URL" |
| Microsoft Teams | `teams://<the workflow URL without https://>` | in the channel, Workflows, "Post to a channel when a webhook request is received", copy its URL (the old Office 365 connectors are retired) |
| ntfy | `ntfy://ntfy.sh/<topic>`, `ntfy://<access token>@ntfy.example.com/<topic>`, `ntfy://user:password@…` | a topic name nobody guesses on ntfy.sh, or your server's topic and an access token (`ntfy token add`) |
| Gotify | `gotify://gotify.example.com/<application token>` | Apps, "Create application", its token (also under a path: `gotify://example.com/gotify/<token>`) |
| Telegram | `telegram://<bot token>/<chat id>` | a bot of @BotFather (its token, `123456:ABC…`); the chat: your id from @userinfobot after sending the bot a message, a group's (`-100…`, the bot added to it) or `@channelname` (the bot an admin of the channel) |
| Matrix | `matrix://<access token>@matrix.example.org/<room>` | a user for the bot, its access token (Element: Settings, Help & About, Access Token), the room it joined: its id (`!abc:example.org`) or alias (`#alerts:example.org`) |
| any other | `webhook://example.com/path`, a header with `?@Name=value`, Basic auth with `user:password@` | n8n, Home Assistant (`webhook://ha.example.com/api/webhook/<id>`), Node-RED, Rocket.Chat and Mattermost incoming webhooks (they show `text`)... |

`+http` after the scheme (`ntfy+http://`, `gotify+http://`, `matrix+http://`, `webhook+http://`...) for a server on your network without HTTPS, e.g. `webhook+http://homeassistant.lan:8123/api/webhook/<id>`. A URL that holds a comma has it as `%2C`; a user or password with `/`, `?` or `#` in it has them percent-encoded (`%2F`, `%3F`, `%23`), otherwise the rest would read as the host: the admin UI refuses an `@` after the host (other than the `?@Name=` headers). With `+http` and a token (a header, Basic auth, the path of a Slack, Discord or Teams webhook) to a host outside your network (not loopback, a private address, one label, `.lan`, `.local`, `.internal`, `.home.arpa`) the admin UI warns at the start and on the Configuration page: anybody on the way can read the token.

An `ADMIN_NOTIFY` the admin UI cannot use stops it at the start, with the number of the destination and its `scheme://host` only, e.g. `ADMIN_NOTIFY, destination 2 of 2 (telegram://…): no chat id: telegram://<bot token>/<chat id>, …`.

**The URLs hold tokens**: anybody with one can post to your channel. The admin UI never shows or logs more than `scheme://host` (`slack://hooks.slack.com`, `telegram://api.telegram.org`; the topic of ntfy is left out too, on ntfy.sh it is the password): on the Configuration page, the overview, in Prometheus, its logs and the errors of the destinations (their answers are scrubbed of the URL's secret parts). `ADMIN_NOTIFY` is a secret of `.env` like the passwords.

What each gets: a title (`firefox-sync: <the alert>`, or `firefox-sync: N events`), one line per alert with its time, the counts of those left out, the time zone, and a link to the Activity page of the admin UI when its public address is known (from `ADMIN_OIDC_REDIRECT_URL`, the callback of the single sign-on). Slack and Discord get light markup (the title in bold), Teams an Adaptive Card (text without markdown, a button to the admin UI), Matrix a notice with its HTML, ntfy, Gotify and Telegram plain text (ntfy and Gotify with a higher priority when an alert needs a look: a component down, backups, thresholds, security changes, blocks, sign-up bursts). What comes from outside (the email of a refused sign-up) can neither mention anybody nor become a link or format anything: in the messages every `@`, every `://` and the dots of host names get a word joiner (U+2060, invisible), so no service turns `@channel`, `@here`, `@room`, `@someone` or `https://phish.example/x@y` into a ping or a link (copied from the message, the text carries those invisible characters); besides, `<`, `>` and `&` are escaped for Slack, markdown is escaped and mentions are off for Discord (`allowed_mentions`), the HTML escaped and `m.mentions` empty for Matrix, and Telegram and Teams get no markup at all. The webhook's `events[].text` is the text as it is (its `text` is defanged too). The messages stay within each service's limit (Discord 2000 characters, Telegram 4096, Slack 40,000, Teams' 28 KB card, ntfy 4 KB): the lines that do not fit are counted, "... and N more lines in the admin UI, Activity".

The generic webhook gets a `POST` with `Content-Type: application/json` and `User-Agent: firefox-sync-admin/<version>`:

```json
{
  "source": "firefox-sync",
  "kind": "health",
  "severity": "warning",
  "title": "firefox-sync: health: Sync server is down: connection refused",
  "text": "firefox-sync: health: Sync server is down: connection refused\n\n2026-10-17 10:00  health: Sync server is down: connection refused\n\nTimes in Europe/Rome. Details: https://admin.example.com/activity",
  "link": "https://admin.example.com/activity",
  "events": [{"time": "2026-10-17T08:00:00Z", "kind": "health", "text": "Sync server is down: connection refused"}],
  "dropped": {}
}
```

`kind`: the kind of every event (`sign-up refused`, `health`, `update`, `sign-in`, `admin`, `blocked`, `sign-up burst`, `backup`, `attention`, `security`), `several` when they differ, `test` for the test notification. `severity`: `warning` when one of them needs a look (the kinds above for ntfy's priority), `info` otherwise. `text`: all of it as plain text, at most 16,000 characters. `link`: `""` when the admin UI's public address is not known. `events`: the alerts, the time in UTC; `dropped`: those left out by the cap of 20 per kind, by kind.

Whether they arrive:

- Each attempt has 10 seconds; one that gets no answer or a 5xx is tried once more 2 seconds later, a refusal (4xx: a wrong token, a deleted webhook) is not. What could not be sent waits for the next round, like the emails (at most 20 of each kind, the newest; the rest counted), each destination on its own queue: one that fails does not keep the others or the email from going out. The destinations of a round are sent at the same time, and the next round waits for the slowest (at most about 22 seconds: two attempts and the wait between them). A destination that refuses the message as it is (400, 413, 422) would refuse it again: those alerts are dropped, logged and counted (`ffs_notify_alerts_lost_total`), not sent again every round.
- **Notifications** in the Health table: each destination with when it last got an alert; down, with the destination's answer, while the last alert to one failed (an event, an alert, and a line in Needs attention). Nothing is sent for the row itself. The overview, under Alerts, says the same per destination and how many alerts wait.
- **Send a test notification**, under the Health table: one message to every destination right away, the result of each on the page. The test is in the event log. It is kept apart from the alerts: it does not change the Notifications row or `ffs_notify_failures_total`; a failed one counts in `ffs_notify_test_failures_total`.
- Prometheus: `ffs_notify_failures_total{destination}`, `ffs_notify_last_success_timestamp_seconds{destination}`, `ffs_notify_send_failing{destination}`, `ffs_notify_alerts_lost_total{destination}`, `ffs_notify_test_failures_total{destination}`, `destination` being the `scheme://host` (a second one of the same host gets ` (2)`).

## Public checks

Every hour the admin UI looks at your server from the outside, the way Firefox does, for each `https://` URL: the Sync node the tokenserver hands out, and with self-hosted accounts `FXA_CONTENT_URL`, `FXA_AUTH_URL` and `FXA_PROFILE_URL`. For each it opens a TLS connection to read the certificate, then asks `/__heartbeat__` through your reverse proxy. The Health table shows `reachable, certificate expires in N days`, Prometheus `ffs_cert_expiry_seconds{host}`. Under 14 days left, or when the URL does not answer, the row turns to a problem, with an event and an alert. While a check fails it runs again every 5 minutes (5 times `HEALTH_CHECK_SECONDS`), so a name the server cannot reach does not hold up the other checks. A Sync node the tokenserver no longer hands out (downed or removed) leaves `ffs_cert_expiry_seconds`.

With self-hosted accounts it also checks that `POST /v1/account/create` of `FXA_AUTH_URL` reaches the [sign-up gate](#who-can-sign-up-self-hosted-accounts): it sends one with an empty body and a header carrying a random token of this start of the admin UI. The gate answers it itself (204, with the token) and passes nothing on. A reverse proxy that sends sign-ups to the accounts service directly gets the empty body to the accounts service, which refuses it: the row says the gate is bypassed. The probe never creates an account, whatever the sign-up policy.

"not reachable from the server" means the server could not connect to its own public name. Often that is split DNS or a firewall: the name resolves to another address inside your network than on the internet, or the server cannot reach its own public address (hairpin NAT). Firefox may well reach it from outside; add the name to the server's `/etc/hosts` or your local DNS if you want the check.

`http://` URLs and unset ones are not checked. `ADMIN_PUBLIC_CHECK=false` (or `0`) in `.env` turns all of them off, and then also the check of `FXA_OAUTH_SERVER_URL` when it is on the internet (Mozilla's accounts), see [Setup checks](#setup-checks).

## Setup checks

The overview lists settings that must agree with each other, each with what goes wrong when it does not:

- **Sync node**: the tokenserver hands out the Sync node in its `nodes` table, which the init container sets from `SYNC_PUBLIC_URL` when it starts. When they differ (`.env` changed, the stack not restarted), the warning names both: Firefox syncs with the one of the table.
- **Sign-in keys** (`FXA_OAUTH_SERVER_URL`): the Sync server checks every sign-in of Firefox with the keys at `FXA_OAUTH_SERVER_URL/jwks` (`/v1` added when missing). Checked every hour. With Mozilla's accounts that is Mozilla's server, on the internet: only with the public checks on.
- **Email of the accounts** (`FXA_SMTP_HOST`), with self-hosted accounts: they email a code for every new account and every sign-in on a new device, and the password resets, so without an SMTP server nobody can sign up or sign in. [`ADMIN_NOTIFY`](#alerts) replaces email for the admin UI's alerts only. Without self-hosted accounts there is no such check: the SMTP server is only needed for alert emails.
- **Account emails** (`FXA_EMAIL_DOMAIN`): the tokenserver keeps each account as `<uid>@FXA_EMAIL_DOMAIN`. After `FXA_EMAIL_DOMAIN` changed, everybody comes back as a new account, with empty storage, and counts twice against max users. The warning names the domain set and the others found, with how many accounts each.

The Sync nodes table, in the Sync section, shows the accounts on each node (those whose current keys are there), its capacity, current load, places available and backoff.

## Configuration

The Configuration page (`/config`) shows the settings the admin UI runs with, so you can check them without opening `.env`: each one with its value, the variable of `.env` it comes from (or `(default)` when it is not set), and what it does. The database servers are shown with the version the health checks read from them (your own server: only MySQL or MariaDB until the first check). Switches are read as the admin UI reads them: `ADMIN_INSECURE_COOKIE` with any value, `ADMIN_UPDATE_CHECK=false` and `FXA_SMTP_SECURE=true` exactly. The Sync databases are shown with the user the admin UI connects as: its reader `ADMIN_DB_SYNC_USER` with `ADMIN_DB_PASSWORD`, next to its own database (`ADMIN_DB_USER`, `ADMIN_DB_NAME`); an install from before `ADMIN_DB_PASSWORD` shows the Sync server's users and the event log in the tokenserver database. The thresholds of [Errors and growth](#errors-and-growth) and the [security history](#security-history) are shown as in force. For the limits and the sign-up policy it shows what is in force in the database, and where it comes from: `SYNC_MAX_USERS=initial:5` says the overview manages it (and what it is now), `SYNC_MAX_USERS=5` that the init container sets it on every start. Nothing can be changed there: edit `.env` and start the stack again (`docker compose up -d`, or restart the Quadlets; with the Helm chart your values and `helm upgrade`, the page then names the variables as in `.env`), the limits and the sign-ups on the overview.

Secrets are never on the page, only "set" or "not set": `ADMIN_PASSWORD`, `ADMIN_OIDC_CLIENT_SECRET`, `ADMIN_METRICS_TOKEN`, `FXA_SMTP_PASS` and the passwords of the databases (`ADMIN_DB_PASSWORD` included); a password inside a URL is hidden too. The admin UI does not get the other secrets of `.env` at all (`SYNC_MASTER_SECRET`, the keys of the accounts service). Every variable the admin UI reads or is given by compose and the Quadlets is listed in the program as a secret or not, and a unit test fails on a new one that is not, so a future setting cannot end up on the page by default.

On top, the settings that disagree, found without asking anything outside: the [setup checks](#setup-checks) that fail; a public URL that is not `https://` (`SYNC_PUBLIC_URL`, `FXA_CONTENT_URL`, `FXA_AUTH_URL`, `FXA_PROFILE_URL`; `http://localhost` is fine), two of them on the same host name (each needs its own, see [FXA.md](FXA.md#what-you-need)), or a pairing server that is not `wss://`; with self-hosted accounts `FXA_EMAIL_DOMAIN` other than the host of `FXA_AUTH_URL`, and `FXA_OAUTH_SERVER_URL` pointing to other accounts than these (Mozilla's); the [trusted header](#trusted-header-forward-auth) with `ADMIN_EXPORT_PORT` on an address other than loopback; `ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true` with another provider than the self-hosted accounts; `ADMIN_INSECURE_COOKIE`; `ADMIN_ALERT_EMAIL` without an SMTP server (with `ADMIN_NOTIFY` set: the alerts go there only); backups failing, too old or not recorded at all (off).

For this page the admin UI also gets, besides what it uses itself, `SYNC_DB`, `ADMIN_EXPORT_PORT` and with the accounts `FXA_DB`, `ADMIN_GATE_EXPORT_PORT`, `FXA_CLIENT_ADDRESS_DEPTH` and `FXA_ACCESS_TOKEN_LIFETIME`, none of them secret.

## Needs attention

The top of the overview lists what to look at now, one line each, with a link to where it is fixed, amber, or red when a component is down. Nothing to list: a green "Everything is working". It is built from what the overview shows anyway:

| Line | Link |
|---|---|
| a component down (the Health table), or the sign-in keys of `FXA_OAUTH_SERVER_URL` | Health, Setup |
| a newer release of a component | Health |
| a certificate of a public URL expiring in less than 14 days | Health |
| sign-ups that bypass the [sign-up gate](#public-checks) | Health |
| the SMTP server does not work, or the last alert email failed | Health, the alert status |
| 90% of max users or more taken, or all of them (max users 0 is on purpose, `unlimited` has no limit: not listed) | the max users form |
| self-hosted accounts: 90% of `FXA_MAX_ACCOUNTS` or more created, or all of them | the max accounts form |
| a backup failed, or the last good one is older than 36 hours | [Backups](#backups) |
| orphaned Sync data (see [Storage](#storage)) | the purge |
| Sync data changed more than 10 minutes after the last metrics from the Sync server while it is up: it needs a restart (see [Metrics](#metrics-and-the-event-log)). An idle server sends no metrics, so a quiet night is not silence; without a storage database to read this is never listed | Activity |
| a spike of Sync errors, or a database growing fast (see [Errors and growth](#errors-and-growth)) | Activity |
| self-hosted accounts: accounts blocked by the rate limits | Security |
| accounts that never confirmed their email; accounts with an unconfirmed sign-in | the list of those accounts (one account: its page) |
| devices not used for `ADMIN_STALE_DAYS` (90), marked `inactive` on the account page | the list of those accounts (one account: its devices) |
| the accounts database not pruned for 2 days (see [Maintenance](#maintenance-and-retention)) | Activity |

The links to a part of the list show only those accounts (`/?show=blocked`, `unconfirmed`, `unconfirmed-sign-in`, `inactive`, `inactive-devices`).

Some of them also alert, and are events of kind `attention`: max users and max accounts (at 90%, when full, and under 90% again), Sync data changed without metrics, alert emails failing, a spike of errors, a database growing fast. Each alerts once when its state changes, not every minute; also at the start of the admin UI when it is already the case. Prometheus has them as `ffs_sync_near_max_users` and `ffs_sync_full`, `ffs_accounts_near_max` and `ffs_accounts_full`, `ffs_statsd_silent`, `ffs_alert_send_failing`, `ffs_sync_error_spike` and `ffs_database_growth_alert` (1 or 0). The limits, the error rate and the growth are also rows of the health table, counted by the health light only when near or full. The other lines have their own alerts already (components, releases, certificates, blocks, backups).

## Finding an account

The search above the accounts list (a plain form, `/?q=`) finds what contains it, without case: part of an email, part of an account id, part of a note (or the label of an account of Mozilla's accounts), and with a whole number the account of that tokenserver uid (any of its rows, also replaced ones); with self-hosted accounts a whole email finds the account of any of its addresses. The list shows 50 accounts a page, newest first, with links to the newer and older ones that keep the search (`/?q=alice&page=2`). `/find?q=` goes straight to the account page of an exact email, account id or tokenserver uid.

## Prometheus

With `ADMIN_METRICS_TOKEN` set, `http://ffs-admin:8080/metrics` (on the stack's network, or `ADMIN_EXPORT_PORT`) serves Prometheus metrics to whoever sends `Authorization: Bearer <token>`:

| metric | |
|---|---|
| `ffs_up{component}` | 1 if the component answers its health check |
| `ffs_sync_accounts`, `ffs_sync_max_users` | accounts using Sync, the limit (no `ffs_sync_max_users` with `SYNC_MAX_USERS=unlimited`) |
| `ffs_sync_stored_items`, `ffs_sync_stored_bytes` | what all accounts store |
| `ffs_accounts`, `ffs_accounts_max` | accounts of the self-hosted accounts service, `FXA_MAX_ACCOUNTS` (none when unlimited) |
| `ffs_database_bytes{database}` | size of each database, measured every hour |
| `ffs_statsd_total{name}`, `ffs_statsd_ms_total{name}` | the statsd metrics of the Sync server since the admin UI started |
| `ffs_cert_expiry_seconds{host}` | seconds until the certificate of a public URL expires, see [Public checks](#public-checks) |
| `ffs_alert_last_success_timestamp_seconds` | when the last alert email went out (Unix time; 0: none since the start), with `ADMIN_ALERT_EMAIL` |
| `ffs_alert_send_failing` | 1 when the last alert email could not be sent, with `ADMIN_ALERT_EMAIL` |
| `ffs_notify_failures_total{destination}`, `ffs_notify_last_success_timestamp_seconds{destination}`, `ffs_notify_send_failing{destination}` | the alerts to each destination of `ADMIN_NOTIFY` that could not be sent (after the retry), when the last one went out (0: none since the start), 1 while the last one failed, see [Alerts](#alerts) |
| `ffs_notify_alerts_lost_total{destination}`, `ffs_notify_test_failures_total{destination}` | the alerts a destination refused as they were (400, 413, 422: dropped, not sent again), the test notifications that failed |
| `ffs_sync_near_max_users`, `ffs_sync_full` | 1 when 90% of max users or more are taken, 1 when all are |
| `ffs_accounts_near_max`, `ffs_accounts_full` | the same for `FXA_MAX_ACCOUNTS` |
| `ffs_statsd_silent` | 1 when the Sync server is up and Sync data changed more than 10 minutes after its last metrics |
| `ffs_sync_errors_total{service,status,kind}` | the errors of the Sync server by kind since the admin UI started, see [Errors and growth](#errors-and-growth) |
| `ffs_sync_error_ratio`, `ffs_sync_error_spike` | the share of the Sync requests that failed in the last 15 minutes, 1 during a spike (with `ADMIN_ERROR_RATE_PERCENT`) |
| `ffs_database_growth_bytes{database}`, `ffs_database_growth_alert{database}` | the growth of each database in the last 24 hours, 1 when it grows fast (once a day is measured) |
| `ffs_security_events_total{event}` | the events of the [security history](#security-history) since the admin UI started, by Mozilla's name (`account.login`, `account.login.failure`, `account.password_changed`...), with `FXA_ACCOUNT_EVENTS=true` |
| `ffs_backup_age_seconds{scope}`, `ffs_backup_last_ok{scope}` | seconds since the last good backup (`sync`, `accounts`), and 1 when the last run worked, see [Backups](#backups) |

```yaml
scrape_configs:
  - job_name: firefox-sync
    authorization:
      credentials: <ADMIN_METRICS_TOKEN>
    static_configs:
      - targets: ["ffs-admin:8080"]
```

## Versions and new releases

Every 12 hours the admin UI asks GitHub for the newest releases of syncstorage-rs and of Mozilla accounts, and shows when the running version is older. The images of this repository follow the upstream releases within a week (they are built and tested every Monday). `ADMIN_UPDATE_CHECK=false` turns it off. With `ADMIN_PUBLIC_CHECK=false` too, the admin UI never connects to the internet, other than to your own public URLs (and your SMTP server and single sign-on provider, when set).

Next to the versions, the overview shows the schema of each database: the newest migration syncstorage-rs ran on the tokenserver and storage databases (with when it ran), and the `schema-patch-level` of each accounts database (`fxa`, `fxa_oauth`, `fxa_profile`, `pushbox`; FxA records no time for it, the Applied column says "not recorded by FxA"). A change is recorded as an event (kind `update`) and alerted, once: an upgrade that migrated, or a database restored from an older backup. The levels seen last are kept in the admin UI's database (`ffs_schema_levels`), so an upgrade of the whole stack, the admin UI with it, is noticed too.

## Who can sign up (self-hosted accounts)

`FXA_SIGNUPS` in `.env`, or the page:

| `FXA_SIGNUPS` | who can create an account |
|---|---|
| `open` (default) | anybody who can reach your accounts pages |
| `allowlist` | only the emails (`alice@example.com`) and domains (`@example.com`) of `FXA_SIGNUP_ALLOWLIST`, comma-separated |
| `closed` | nobody |

Existing accounts are never affected: disable them in the accounts list instead.

Under the policy, the emails of the allowlist are listed with when they were added and whether they signed up yet (`signed up on <date>`, matched without case as the policy does), each with a Remove link to a confirm page (`/accounts/allowlist/remove?entry=...`, its form posts to `/accounts/allowlist/remove`); the domains are listed apart, the same way. Removing an entry stops new sign-ups with it, an account already created stays. Saving the policy only removes entries the page showed: an invitation sent from another tab or by another admin after you loaded the page stays on the allowlist.

How it works:

- The accounts database refuses the account itself: `fxa-policy`, which runs before the accounts service on every start, installs a trigger on the accounts table (and the `ffs` database it reads the policy from). Nothing reaching the accounts service, whatever the path, can create an account the policy does not allow.
- So that people see why, the admin UI also answers sign-up requests itself: point `POST /v1/account/create` of your accounts API host name to `ADMIN_GATE_EXPORT_PORT` (`127.0.0.1:8091`). `config/nginx/fxa-example.conf` does it, `prepare_environment.sh` removes it when you don't enable the admin UI. Refused sign-ups then get "The request was blocked for security reasons" on the sign-up page, instead of "Unexpected error". Everything else goes to the accounts service directly.
- `.env` and the page both change the policy: the values in `.env` are applied when you change them there (on the next `docker compose up -d`), otherwise what you set on the page stays. `SYNC_MAX_USERS` works differently, see [Max users](#max-users).

## Invitations and Connect a device

**Invite**, under Sign-ups, takes an email:

- with the policy `allowlist`, it adds the email to the allowlist (`invited <date>, not signed up yet` until they do);
- with `open` it leaves the allowlist alone; with `closed` too, and the page warns that they cannot sign up until you open sign-ups (the email says so);
- it sends them a plain text email through the stack's SMTP server (`FXA_SMTP_*`, sender `FXA_SMTP_SENDER`): the link to create their account (`FXA_CONTENT_URL/?email=<their email>`, which opens the sign-up page with that email), then the steps to point Firefox on a computer, Android and iOS to this server, and to pair a phone from a computer. No HTML, no images, no tracking: the links are the plain URLs of your server. Without an SMTP server the entry is still added and the page says the email was not sent.

At most 20 invitations an hour go out, whoever sends them, so that a stolen session cannot make your SMTP server a spammer. Each one is in the event log.

**Connect a device** (in the menu) shows the same steps, built from `FXA_CONTENT_URL`, the Sync node and `FXA_PAIRING_URL`, exactly as in [FXA.md](FXA.md#firefox-setup): on a computer `identity.fxaccounts.autoconfig.uri` in `about:config`; on Android the debug menu (tap the Firefox logo 5 times in About Firefox), then `Custom Mozilla account server` and `Custom Sync server` (`<node>/1.0/sync/1.5`); on iOS the version number 5 times, then `Custom Account Content Server URI`; a phone can also pair with the QR code of a computer already signed in, through your pairing server or Mozilla's. With Mozilla's accounts the page shows the steps of [SYNC.md](SYNC.md#firefox-setup) instead: `identity.sync.tokenserver.uri`, and the custom Sync server of the phones.

## Disabling an account

Disable (on the accounts list or the account page, then on the confirm page) signs the account out of every device, refuses new sign-ins and revokes its OAuth tokens (in the accounts database and in Redis), so the sync server refuses the account's access tokens from then on. Firefox can still sync with what it already has for up to about an hour: the sync server remembers a verified access token for 5 minutes, and a Sync token it handed out stays valid for up to 1 hour. Enable gives the account back, with its data, after a new sign-in.

Signing out goes through Mozilla's own procedure (`revokeAccountTokens_1`): sessions, key fetch, account reset, password change and password reset tokens, unconfirmed sign-ins, unblock codes and devices, then the OAuth tokens and codes. `fxa-policy` checks at every start that the Mozilla procedures it calls exist (`revokeAccountTokens_1`, `deleteTotpToken_4`, `deleteRecoveryKey_2`, `verifyEmail_9`, `deleteAccount_24`, `prune_10`). If one is missing (a newer accounts release renamed it, or the policy user of your own server has no `EXECUTE` on `fxa.*`), it logs a warning with its name and the accounts keep working, but what needs it (disabling an account and signing out everywhere, turning off two-step authentication, removing a recovery key, confirming an email, deleting accounts, pruning) answers with an error: update the admin UI image, or grant `EXECUTE` (see [DATABASES.md](DATABASES.md)).

`FXA_ACCESS_TOKEN_LIFETIME` (`60 minutes` by default, any duration like `2 hours`) is how long the access tokens of Firefox live. Revoking makes the lifetime irrelevant for disabled accounts; a short one is a backstop in case revoking fails (the page tells you), at the cost of Firefox asking for a new token every hour, nothing a small server notices. Mozilla's default is `365 minutes`. Keep the lifetime as is if you turn on JWT access tokens (`JWT_ACCESS_TOKENS_ENABLED_CLIENT_IDS`, off by default): those living 6 hours or less are checked by their signature only and cannot be revoked.

Mozilla's own admin panel (not part of this stack) disables accounts the same way, without revoking the tokens.

## Signing out everywhere, a device or a session

Sign out everywhere, on the account page, does what disabling does to the devices, sessions and tokens, but leaves the account active: its owner can sign in again right away. Use it after a lost laptop or a leaked password (with a new password). Like after disabling, Firefox can sync for up to about an hour with the Sync token it has, and the sync server remembers a checked access token for 5 minutes.

Sign out next to a device or a session removes that device and the session or OAuth refresh token it signed in with, so it cannot get new access tokens. The access tokens it already has keep working until they expire (`FXA_ACCESS_TOKEN_LIFETIME`, 60 minutes by default), and the sync server may accept them for up to an hour more. To lock every device out at once, sign out everywhere.

The admin UI connects to the accounts database as `ffs_admin` (`FXA_ADMIN_DB_PASSWORD`; its user there, not its own database `ffs_admin` of `ADMIN_DB_NAME`), which can read a few columns of the accounts and nothing else of FxA: it never sees the token ids (a session token id signs in as its account), and it cannot change FxA's tables. Sessions, devices, emails, how accounts sign in, their security history and the schema levels are listed through views (`ffs.sessions`, `ffs.devices`, `ffs.emails`, `ffs.account_security`, `ffs.security_events`, `ffs.schema_levels`), and disabling, enabling, signing out, turning off two-step authentication, removing a recovery key, confirming an email, deleting accounts and pruning run as procedures that `fxa-policy` installs (`ffs.disable_account`, `ffs.enable_account`, `ffs.sign_out_all`, `ffs.sign_out_device`, `ffs.sign_out_session`, `ffs.remove_totp`, `ffs.remove_recovery_key`, `ffs.confirm_email`, `ffs.delete_account`, `ffs.delete_unconfirmed`, `ffs.prune`), with the privileges of the policy user.

The devices and sessions say when they were last used: the accounts service writes most uses to its Redis only (`fxa-auth-session<uid>`), the admin UI reads it there once per account page and shows the later of the two. The stack has it record every use (`LASTACCESSTIME_UPDATES_SAMPLE_RATE=1`, Mozilla samples 30% of the accounts). That cache holds the session token ids: the admin UI turns each into its hash right away and keeps nothing else. A session that never entered the code sent by email (or the second step) is marked `unconfirmed sign-in`, in the list too: it cannot sync, and a sign-in you do not expect there means someone has the password.

## Helping account owners

The account page of a self-hosted account shows how it signs in, without any secret (the views never read the authenticator's key, the backup codes, the recovery key's data or the phone number):

- two-step authentication (an authenticator app), with the backup authentication codes left and whether a recovery phone is set,
- whether it has an account recovery key, and its passkeys,
- when the password was last set and the keys last changed,
- all its emails, primary and secondary, and whether they are confirmed (a secondary email is in the accounts database once confirmed).

**They forget their password**: they use Forgot password at `FXA_CONTENT_URL/reset_password` themselves. With a recovery key nothing is lost. Without one, the reset gives the account new keys and the Sync data on the server cannot be read anymore: they first open Firefox on a device that still has the data, so it uploads it again after the reset. The account page says so.

**They lost their authenticator app** (and their backup codes): Turn off… next to two-step authentication. It removes the authenticator, the backup codes and the recovery phone in one transaction (Mozilla's `deleteTotpToken_4`), and they sign in with the password and a code sent by email again. **Make sure who is asking first**: from then on the password and the mailbox are enough. The confirm page also signs out everywhere, on by default: if someone else got in, they are out too.

**Remove a recovery key**, e.g. one that leaked: Remove… next to it (Mozilla's `deleteRecoveryKey_2`), with the same choice to sign out everywhere.

After either one the owner gets a plain email from the stack's SMTP server (`FXA_SMTP_SENDER`), "An administrator turned off two-step authentication on your account", with a link to the account settings to set it up again; the admins get the alert of the change. Without `FXA_SMTP_HOST` nothing is sent, and the page says so.

**Their confirmation email never arrived**: Confirm the email…, on the account page of an unconfirmed account. It skips the proof that whoever signed up owns the address: do it only when you know who they are. Their current sign-in stays unconfirmed; signing in again sends a new code to the address. Confirming pending sign-ins themselves is not offered.

**They are blocked** after too many wrong passwords or codes: the accounts list marks them `blocked`, the account page says until when, with a Lift button (as on the Security page). Every minute (`HEALTH_CHECK_SECONDS`) the admin UI checks the blocks, and records (and alerts) a new one of an existing account once per account and action, on its email (alone or with an IP address) or its uid. Blocks of emails that have no account and of IP addresses alone are left to the Security page: anybody can cause those. Thousands of those do not hide the block of an account: the admin UI reads the names of all blocks (up to 100,000, past that every page says so), and only the details of those of accounts. The Security page lists the blocks of accounts first, then at most 1,000 others, and says how many it leaves out.

Each of these changes is in the event log with who made it, the account's email and the reason given. The procedures run as the policy user, `ffs_admin` only has `EXECUTE` on them; the profile server's cache of the account is dropped afterwards (in the accounts' Redis), so the account settings show the change at once.

## Security history

With self-hosted accounts and `FXA_ACCOUNT_EVENTS=true` (off by default: it keeps the IP address of every sign-in, see [FXA.md](FXA.md#security-history) for what it changes and what it keeps), the account page lists its security history, the newest 50 entries, as its owner sees them in Recent activity of the account settings: the event (signed in, wrong password, password changed or reset, two-step authentication turned on or off, recovery key created or removed, backup codes, emails, passkeys, signed out; Mozilla's name for the others), when, the IP address and whether the sign-in of the event was confirmed (`not confirmed`: its code or second step was never entered, which for a sign-in you do not expect means someone has the password). Off, the page says how to turn it on, and still lists what was recorded before.

Every round of checks (`HEALTH_CHECK_SECONDS`) the admin UI reads the new events of every account, oldest first, by pages of 10,000 and up to 100,000 a round: a burst (thousands of wrong passwords, a catch-up after the accounts database was down) only delays the next ones to the following rounds, none is skipped. These, by the owner in the account settings (or whoever has their session), are events of kind `security` in the event log and alerts (`alice@example.com (uid 3f2a1b2c): password changed, from 203.0.113.5`), with the caps of every kind (30 a minute in the log, 20 an email); the alert emails then carry IP addresses too:

| alert | Mozilla's event |
|---|---|
| password changed | `account.password_changed` |
| password reset (forgotten password) | `account.reset` |
| password set (an account without one) | `account.password_added` |
| primary email changed | `account.primary_secondary_swapped` |
| two-step authentication turned on, turned off, authenticator app replaced | `account.two_factor_added`, `account.two_factor_removed`, `account.two_factor_replace_success` |
| backup codes created, replaced | `account.recovery_codes_created`, `account.recovery_codes_replaced` |
| recovery key created, removed | `account.recovery_key_added`, `account.recovery_key_removed` |
| passkey added, removed | `account.passkey.registration_success`, `account.passkey.removed` |
| recovery phone added, replaced, removed | `account.recovery_phone_setup_complete`, `account.recovery_phone_replace_complete`, `account.recovery_phone_removed` (no SMS here: never, unless you add it) |

Not alerted: `account.password_reset_success` ("new password saved"), which Mozilla (v1.347) records next to `account.password_changed` on every password change, and the backup codes saved while turning on two-step authentication (`account.recovery_codes_set`), which come with its alert.

The reading has a cost: Mozilla's table has no index on the time of the events, so each round scans all of `fxa.securityEvents` (on your server with `EXTERNAL_DB`), as the daily pruning does. Kept for 30 days on a server of a few people that is a few thousand rows, nothing; with thousands of accounts or a long `ADMIN_RETENTION_DAYS`, keep an eye on it (the stack does not change Mozilla's tables). What the admin UI itself turns off or removes is in the audit trail already (kind `admin`): Mozilla's procedures it calls record no security event. Prometheus counts every event by its name (`ffs_security_events_total`), since the start of the admin UI. Where the reading is, and the alerted events it may read again, are kept in the admin UI's database (`ffs_meta`) after every page: after a restart, an upgrade or a host that was off, it reads on from where it stopped (at most `ADMIN_RETENTION_DAYS` back, by the same pages), so a password changed, 2-step authentication turned off or a recovery key added in the meantime is alerted once, late, and not twice. Without `ADMIN_DB_PASSWORD` (an install from before it, no database of its own) and at the first start of a release with it, events from before the start of the admin UI are not alerted.

`ffs_admin` reads the history through `ffs.security_events`: the name, time, IP address and confirmation of each event, not the rest of it (its JSON can hold the recovery phone's number). The daily [pruning](#maintenance-and-retention) deletes events older than `ADMIN_RETENTION_DAYS`; deleting an account deletes its history.

## Sync data of an account

The account page lists every row the tokenserver has for the account: syncstorage-rs adds one, with a new uid and new (empty) storage, each time the account's keys change (a password reset without the recovery key, for example). For each: its uid (the user id in the storage), client state (a hash of the keys), keys changed at (as Firefox sends it), node, when it was created and replaced, and what its storage holds. The current one, where Firefox syncs, is marked. With self-hosted accounts the page also shows when the accounts service last changed the keys and set the password. The generation is not shown: with OAuth sign-ins it is always 0.

What looks wrong is said in one line each:

| Flag | What it means |
|---|---|
| Several current rows | more than one row is not replaced: the tokenserver uses the newest, what the others store is never read |
| Keys went back in time | a row has an older `keys_changed_at` than the one before it: a device with old keys, or the accounts database restored from a backup |
| Keys changed without a date | new keys (client state) with the same `keys_changed_at`: the accounts service did not record the change, devices may disagree on the keys |
| Unknown node | the current row points to a node the tokenserver does not have: Sync tokens fail |
| Node retired | the current row is on a downed node: the next sign-in moves the account to empty storage |
| Data left on old keys | the current storage is empty while a replaced row still holds data: encrypted with the old keys, Firefox cannot read it; a device that still has the data uploads it again |

**Find an account**: see [Finding an account](#finding-an-account); a tokenserver uid (a number, as in the storage database or the Sync server's logs) finds the account of any of its rows.

**Reset the Sync data** (account page, then the confirm page) deletes what the storage holds for the current row, and keeps the account and its tokenserver row: each Firefox finds the server empty on its next sync and uploads what it has again. Data that is only on the server is lost. On MariaDB it deletes from `bso`, `user_collections`, `batch_uploads` and `batch_upload_items`, on PostgreSQL from `bsos` then `user_collections` (which takes the batches with it), 1000 items at a time so that the Sync server keeps answering. **Reset…** next to a collection deletes that collection only; Firefox does not notice it by itself, it sends again what changes on a device, or everything after Sync is reset there (disconnect, then sign in again). The checkbox "also free the max users slot" deletes the account's tokenserver rows too, and the storage of each: the account no longer counts towards max users, and its next Sync token goes through the limit again (refused when the server is full). Every reset is in the event log and the alerts.

## Deleting an account

Deleting is for a disabled account only: disable it first, then **Delete the account for good…** on its page, and type its email on the confirm page. `ffs.delete_account` refuses an account that is not disabled, whatever sends the request. It deletes, in one transaction, its recovery phone, its OAuth codes, refresh and access tokens, activity and consents (`fxa_oauth`), its profile and avatars (`fxa_profile`) and its push messages (`pushbox`), then runs Mozilla's own deletion (`deleteAccount_24`, reason `fxa_admin_requested_account_delete`: sessions, keys, devices, emails, two-step authentication, recovery key and codes, security events), then removes its exact email from the allowlist, so that with sign-ups on an allowlist it cannot sign up again unless invited. The admin UI then deletes what Redis keeps of it (its access tokens, the cache of its sessions and refresh tokens, its profile), and on the Sync side every tokenserver row of `<uid>@<FXA_EMAIL_DOMAIN>` with the storage of each, which frees its max users slot. Firefox can keep writing for up to an hour with the Sync token it has: a second pass deletes that storage again 65 minutes later (a restart of the admin UI forgets it, the purge then finds that storage, which has no tokenserver row). Its note is removed too. If something fails once the account is gone from the accounts database (Redis, the Sync data, the note), the page says what, and the event log still records the deletion with the error: delete the Sync data again from the account's page, which stays as long as tokenserver rows are left.

The event says who was deleted, with the email, by whom and why. The avatar image, if the owner uploaded one, stays in the `fxa-profile-images` volume (the files are named by a random id, not by the account).

With Mozilla's accounts (or for an account id whose self-hosted account is gone) the same page deletes the Sync data and the tokenserver rows of the account id: type the id to confirm. The account itself is Mozilla's: it can sync here again, as a new account.

## Storage

The Storage section of the overview splits what the storage database holds:

- **live**: what Firefox reads back;
- **expired**: items past their time to live, which the Sync server no longer returns;
- **orphaned**: storage nobody reads any more: the rows of replaced keys a day after they were replaced (a device still on the old keys may need them once more), unless it is the current row of its email; with self-hosted accounts the rows of `FXA_EMAIL_DOMAIN` whose account is gone from the accounts database (deleted by its owner in the account settings), and the storage of each of them; storage user ids with no tokenserver row at all;
- **stale batches**: uploads in several parts never committed, past their 2 hours.

Rows of another email domain whose account is not in the accounts database (an earlier `FXA_EMAIL_DOMAIN`, or Mozilla's accounts before the self-hosted ones) are listed apart and never purged: delete them from their account page if they are gone. The section also lists the 10 largest accounts and, on MariaDB, the space the tables keep after deletions: `OPTIMIZE TABLE bso;` gives it back to the disk, it rebuilds the table, best run when few people sync.

**Purge now…** (then the confirm page, which lists the orphans) deletes the orphans, their tokenserver rows and storage, then the expired items (`DELETE FROM bso WHERE ttl < now LIMIT 1000`, again until none are left; `bsos` and `batches` past `expiry` on PostgreSQL) and the stale batches, 1000 rows at a time, so the Sync server keeps answering. Live data stays. Deleted accounts no longer count towards max users once purged. The purge goes on in the background past 20 seconds; the event log has what it removed. With `ADMIN_PURGE=1` it runs every day by itself, and leaves for a purge by hand what looks like a database that came back empty or from an older backup, not people leaving: the deleted accounts when they are more than half of the accounts using Sync or no account is left (so also the only account of a one-account server), and the storage without a tokenserver row when it is more than half of the storage user ids or the tokenserver has no row at all. The event says what it left.

## Maintenance and retention

What runs by itself, on the Activity page (Maintenance: last run and what it did) and in the event log (kind `maintenance`), once a day, kept across restarts (`ffs_jobs` in the admin UI's database). A job that failed runs again an hour later:

- **Pruning the accounts database**, with self-hosted accounts: Mozilla's `prune_10` with Mozilla's defaults (unblock and sign-in codes after 30 days, reset and password change tokens and sessions without a device after 4 weeks; the session of a Firefox has its device and is never pruned), the same session rule once more for those `prune_10` stops at, expired OAuth codes (15 minutes), and the security events of the account settings after `ADMIN_RETENTION_DAYS`, which Mozilla's procedure never prunes. `ffs.prune` takes the database's clock, whatever time it is given, and keeps the security events of the last day at least. "Prune the accounts database now…" on the Activity page runs it at once, after a confirm page that says what goes (`GET /maintenance/prune`; its form posts there). The overview says when it last ran, next to the schema levels.
- **The purge of the Sync storage**, with `ADMIN_PURGE=1`, see [Storage](#storage).
- **Deleting old unconfirmed accounts**, with `ADMIN_DELETE_UNCONFIRMED_DAYS=N` (at least 1): accounts created more than N days ago that never confirmed an email, with Mozilla's deletion (reason `fxa_unverified_account_delete`) and their OAuth tokens, at most 10000 a run. The admin UI deletes them one at a time through `ffs.delete_unconfirmed`, which refuses an account that confirmed its email or was created less than a day ago, whatever the admin UI asks; the event names the accounts deleted (as many emails as fit, then how many more), also when it stops partway. By hand: "Delete the old ones…" next to the count of unconfirmed accounts on the overview (30 days by default, `?days=N` in the address of the confirm page), which lists them first.

Every minute the admin UI also counts the accounts created in the last hour: more than `ADMIN_SIGNUP_BURST` (10 by default, 0: never) is an event and an alert (kind `sign-up burst`), at most once an hour. Someone is creating accounts in bulk; close sign-ups or switch to an allowlist if they are not yours.

What is kept for how long:

| What | Where | Kept |
|---|---|---|
| metrics, events | `ffs_metrics`, `ffs_events` | `ADMIN_RETENTION_DAYS` (30) |
| events of kind `admin` (who did what) | `ffs_events` | `ADMIN_AUDIT_RETENTION_DAYS` (365) |
| security events of the account settings | `fxa.securityEvents` | `ADMIN_RETENTION_DAYS` |
| codes, reset tokens, sessions without a device | accounts database | 30 days, 4 weeks (Mozilla's defaults) |
| unconfirmed accounts | accounts database | until deleted, or `ADMIN_DELETE_UNCONFIRMED_DAYS` |
| inactive accounts (not synced for `ADMIN_STALE_DAYS`) | everywhere | until deleted: only marked |
| replaced keys, deleted accounts, expired items | storage database | until purged, or a day with `ADMIN_PURGE=1` |
| the runs of the backups | `ffs_backups` | `ADMIN_AUDIT_RETENTION_DAYS` (365) |
| the backups themselves | `backups` volume | the newest `BACKUP_KEEP` (7) runs |

## Backups

What a restore needs, from most to least important:

| What | Where | |
|---|---|---|
| `.env` | the stack's directory (Kubernetes: the chart's Secret, or your `existingSecret`, and your values) | every password and secret (`SYNC_MASTER_SECRET`, the accounts' keys...). **Critical**: without it nothing restored works as before |
| the `fxa-keys` volume | self-hosted accounts | the keys the accounts service signs with. **Critical**: new keys sign every Firefox out |
| the accounts databases | `fxa`, `fxa_oauth`, `fxa_profile`, `pushbox`, `ffs` | the accounts, their devices, the sign-up policy. **Critical**: lost, everybody creates a new account |
| the tokenserver database | `tokenserver` (or the PostgreSQL database) | which account syncs where, max users. **Important**: without it every account starts over with empty storage, and Firefox uploads again |
| the admin UI's database | `ffs_admin` | the event log and the audit trail, the notes, the backup runs. Lost, the admin UI starts with an empty log |
| the storage database | `syncstorage` (or the PostgreSQL database) | the Sync data, encrypted by Firefox. **Rebuildable**: each Firefox uploads what it has |

`.env` and `fxa-keys` change rarely: copy them off the host once, and again after a change. The databases change every minute: that is what the backup service is for.

### The backup service

Optional: add `backup` to `COMPOSE_PROFILES` in `.env` (`COMPOSE_PROFILES=admin,backup`), then `docker compose up -d`. With Quadlets the units are installed already, off: `systemctl --user enable --now firefox-sync-backup.timer`. With the Helm chart: `backup.enabled: true`, see [Kubernetes](#the-backups-on-kubernetes).

Every night at `BACKUP_TIME` (`03:00`, UTC) it dumps each database, with `mariadb-dump --single-transaction --routines --triggers` (MariaDB), `pg_dump --no-owner --no-privileges` (PostgreSQL: the roles the dump would name exist on a new server only after the init container, which gives the grants again at every start; `ffs_admin` also with `--clean --if-exists`, restored over its tables), and for the accounts `mysqldump` (or `mariadb-dump` with `FXA_DB=mariadb`) with the events too and without the trigger of the sign-up policy (`fxa-policy` installs it again at every start, before the accounts service: a copy restored elsewhere does not put it on the real `fxa.accounts`), into `<scope>/<UTC time>/<database>.sql.gz` of the `backups` volume (`<project>_backups`, e.g. `firefox-sync_backups`; `firefox-sync-backups` with Quadlets), `sync/` and `accounts/`. A dump of MariaDB or MySQL that fails because a table changed while it ran (error 1412, e.g. the admin UI moving its tables at an upgrade) is done again once, 10 s later (`BACKUP_RETRY_PAUSE`). Each file passes `gzip -t` or the run fails; the files are readable by root only (0600). The newest `BACKUP_KEEP` runs (7) stay, older ones go; a failed run leaves nothing and keeps the older copies. It runs in the images of the databases, already on the host (`mariadb:lts`, `postgres:18`, `mysql:8`, or the accounts' `FXA_MARIADB_IMAGE`), as the stack's users: the tokenserver and storage users (with PostgreSQL the Sync server's role `SYNC_POSTGRES_APP_USER`, the owner of its tables), the admin UI's user for its own database (`ffs_admin.sql.gz`), and `FXA_MYSQL_USER` for the accounts. With compose, a backup container that starts after `BACKUP_TIME` and did not run that day runs at once (the first start); with Quadlets the timer catches up after a night the host was off.

The Backups card of the overview says all of this with the values of this server: the admin UI gets `BACKUP_TIME` and `BACKUP_KEEP` (and with Quadlets `ADMIN_DEPLOYMENT=quadlets`, for their commands), and describes the volume, which it cannot read, without listing it.

One now: `docker compose exec backup sh /ffs-backup/backup.sh now` (and `backup-fxa` for the accounts); with Quadlets `systemctl --user start firefox-sync-backup.service`, which runs that of the accounts first; with the Helm chart `kubectl create job --from=cronjob/ffs-firefox-sync-backup backup-now-$(date +%s)`. One run at a time: a run started while another is going on (the nightly one, say) waits for it, at most an hour (`BACKUP_LOCK_WAIT`, in seconds), then fails, recorded like any failed run. The lock is `.lock-<scope>` in the volume; the lock of a run that was killed is taken over by the next run (after a day when that run was in another container).

Each run is a row of `ffs_backups` in the admin UI's database (when it started and finished, whether it worked, its size, where, the error), written as the admin UI's user (without `ADMIN_DB_PASSWORD`: in the tokenserver database, as the tokenserver user). The accounts' run is recorded by the Sync backup service (its image has no client for PostgreSQL): within a minute with compose, right after it with Quadlets. The admin UI reads that table, it never sees the volume:

- the Health section of the overview: "Last backup of the Sync databases: 2026-10-13 03:00, 1.2 MB, ok", or failed with the error and the last good one;
- [Needs attention](#needs-attention), an event of kind `backup` and an alert when a run fails or the last good one is older than 36 hours, once, and when they work again;
- Prometheus: `ffs_backup_age_seconds{scope}` and `ffs_backup_last_ok{scope}`.

Without the admin UI, `docker compose ps` says it too: the `backup` and `backup-fxa` containers turn `unhealthy` when their loop stops, when their last run failed, or when the last good one is more than 25 hours old (`backup.sh health`, every minute, from what each run leaves in the volume: `.loop-<scope>`, `.result-<scope>`); a run going on counts as healthy. With Quadlets the backups are one-shot units of the timer, with no healthcheck: `systemctl --user status firefox-sync-backup.service` says how the last one ended.

The rows are kept for `ADMIN_AUDIT_RETENTION_DAYS`.

### The backups on Kubernetes

With the [Helm chart](HELM.md#backups), `backup.enabled: true`: the CronJob `<release>-firefox-sync-backup` runs the same `backup.sh` in the database's image, the Sync scope only (no accounts in the chart), into the PersistentVolumeClaim `<release>-firefox-sync-backups` (kept on `helm uninstall`). `backup.schedule` (cron, UTC, `"0 3 * * *"`) instead of `BACKUP_TIME`: a daily one is also the time the Backups card says, any other makes that text approximate, and one rarer than every 36 hours makes the alert of a too old backup fire between runs. `backup.keep` is `BACKUP_KEEP`; a run is stopped after `backup.activeDeadlineSeconds` (23 hours), one at a time. Without the admin UI: `kubectl get cronjob ffs-firefox-sync-backup -o jsonpath='{.status.lastSuccessfulTime}'` (the last run that worked), `kubectl get jobs` and `kubectl logs job/<name>`. It also runs with your own database server (`database.bundled: false`), as the users of its SQL. Copying the PVC off the cluster and restoring: [HELM.md](HELM.md#copy-them-off-the-cluster).

### Copy them off the host

The volume is on the same disk as the databases: a dead disk takes both. Copy it elsewhere, e.g. every morning from cron:

```bash
# docker compose (the volume is named after the directory of the stack)
docker run --rm -v firefox-sync_backups:/backups:ro -v "$PWD":/out busybox tar -C /backups -czf /out/ffs-backups.tar.gz .
# Podman (Quadlets)
podman volume export firefox-sync-backups > ffs-backups.tar
# and once, after each change: .env and the accounts' keys
docker run --rm -v firefox-sync_fxa-keys:/keys:ro -v "$PWD":/out busybox tar -C /keys -czf /out/fxa-keys.tar.gz .
```

then `scp` or `rsync` them to another machine. On Kubernetes, the PVC with a pod that mounts it: [HELM.md](HELM.md#copy-them-off-the-cluster). The dumps hold what the databases hold (emails, the event log, the accounts' password checks): keep the copies as private as `.env`, encrypted if they leave your own machines.

### Your own database servers

The backup service of compose and the Quadlets is for the database containers of the stack (the Helm chart's CronJob also runs on your own server, [above](#the-backups-on-kubernetes)): on [your own server](DATABASES.md) use its own backups (the accounts' user of the stack cannot read `ffs` there). To have the admin UI watch them, have your backup job record each run in the admin UI's database, as its user (`ffs_admin_ui`; before `ADMIN_DB_PASSWORD`: the tokenserver database, as the tokenserver user). Back up that database too, it holds the event log. The admin UI creates the table when it starts:

```sql
-- MariaDB and MySQL
CREATE TABLE IF NOT EXISTS ffs_backups (id BIGINT AUTO_INCREMENT PRIMARY KEY, scope VARCHAR(32) NOT NULL, started BIGINT NOT NULL,
  finished BIGINT NOT NULL, ok SMALLINT NOT NULL, bytes BIGINT NOT NULL, error VARCHAR(512) NOT NULL DEFAULT '', location VARCHAR(255) NOT NULL DEFAULT '',
  KEY ffs_backups_started (started));
-- PostgreSQL: the same columns, with id BIGSERIAL PRIMARY KEY and without the KEY line
```

`scope` is `sync` or `accounts`, the times are milliseconds since 1970, `ok` is 1 or 0 (with the reason in `error`), `bytes` the size. At the end of your job, e.g.:

```bash
mariadb -h db.example.com -u ffs_admin_ui -p"$ADMIN_DB_PASSWORD" ffs_admin -e \
  "INSERT INTO ffs_backups (scope, started, finished, ok, bytes, location) VALUES ('sync', ${START}000, $(date +%s)000, 1, ${BYTES}, 'backup-host:/srv/ffs')"
```

### Restoring

On Kubernetes: [HELM.md](HELM.md#restoring), the same steps with `kubectl`, in Jobs of the backup CronJob's spec.

On the same host or a new one, with the `.env` of the stack (and the `fxa-keys` volume put back, with `tar -x` into it):

1. Stop the stack, `docker compose down` (not `-v`). To start from empty databases, remove their volumes (a new host has none yet): `docker volume rm firefox-sync_tokenserver-db firefox-sync_syncstorage-db`; with `SYNC_DB=mysql` `docker volume rm firefox-sync_tokenserver-db-mysql firefox-sync_syncstorage-db-mysql`; with PostgreSQL `docker volume rm firefox-sync_postgres-db`; with self-hosted accounts also `docker volume rm firefox-sync_fxa-db` (`docker volume rm firefox-sync_fxa-db-mariadb` with `FXA_DB=mariadb`). PostgreSQL's dump loads only into an empty database: there, always remove `postgres-db`. The dumps of MariaDB and MySQL drop and create each table again, into the old databases too. On a new host, put the copy of the backups volume back: `docker run --rm -v firefox-sync_backups:/backups -v "$PWD":/in busybox tar -C /backups -xzf /in/ffs-backups.tar.gz` (compose then warns that it did not create that volume: it uses it all the same). Then start the databases alone and wait until they answer: `docker compose up -d --wait tokenserver_db syncstorage_db`; with PostgreSQL `docker compose up -d --wait postgres_db`; with self-hosted accounts add `fxa-db` (its service has that name with `FXA_DB=mariadb` too).
2. Pick a run: `docker compose run --rm --no-deps --entrypoint ls backup /backups/sync` (and `/backups/accounts` with self-hosted accounts). Each command below checks its file with `gunzip -t` first: without it, a wrong run (or one already pruned by `BACKUP_KEEP`) gives the client an empty input, which it takes as a success.
3. The accounts, as the user that made the dumps (`FXA_MYSQL_USER`, root in the stack): the views and procedures of `ffs` carry it as their `DEFINER`, which only that user (or one with `SET_ANY_DEFINER`, on MySQL before 8.2 `SET_USER_ID`, on MariaDB `SET USER`) can restore. `ffs` last, its views read the others; at the next start `fxa-policy` installs the trigger of the sign-up policy again, and the admin UI's user and its grants, before the accounts service starts. With `FXA_DB=mariadb`, `mariadb` instead of `mysql`:

    ```bash
    docker compose run --rm --no-deps --entrypoint sh backup-fxa -c '
      run=/backups/accounts/20261013T030000Z
      for db in fxa fxa_oauth fxa_profile pushbox ffs; do
        mysql -h "$FXA_DB_HOST" -u"$FXA_DB_USER" -p"$FXA_DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $db" &&
        gunzip -t $run/$db.sql.gz && gunzip -c $run/$db.sql.gz | mysql -h "$FXA_DB_HOST" -u"$FXA_DB_USER" -p"$FXA_DB_PASSWORD" $db || exit 1
      done'
    ```

4. The tokenserver, as the tokenserver user (it is the `DEFINER` of the max users trigger and procedure). With `SYNC_DB=mysql`, `mysql` instead of `mariadb`:

    ```bash
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      f=/backups/sync/20261013T030000Z/$TOKENSERVER_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        mariadb -h "$TOKENSERVER_DB_HOST" -u"$TOKENSERVER_DB_USER" -p"$TOKENSERVER_DB_PASSWORD" "$TOKENSERVER_DB_NAME"'
    # PostgreSQL (tokenserver and storage, one database): into the empty database, as the
    # Sync server's role SYNC_POSTGRES_APP_USER (TOKENSERVER_DB_USER of the backups, SYNC_POSTGRES_USER
    # without it), which this creates first. Not as the superuser: what the dump holds is
    # that role's, its functions would run with the superuser's rights. The dump names no
    # role (pg_dump --no-owner --no-privileges), the init container gives the grants at the
    # next start
    docker compose run --rm sync_role_init
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      f=/backups/sync/20261013T030000Z/$TOKENSERVER_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        PGPASSWORD="$TOKENSERVER_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$TOKENSERVER_DB_USER" -d "$TOKENSERVER_DB_NAME" -v ON_ERROR_STOP=1'
    ```

5. The admin UI's database, as its user `ADMIN_DB_USER` (the stack's database containers create it, empty, at their start; the dump drops and creates its tables again, which its grants allow, `DROP` and `LOCK TABLES` included):

    ```bash
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      f=/backups/sync/20261013T030000Z/$ADMIN_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        mariadb -h "$TOKENSERVER_DB_HOST" -u"$ADMIN_DB_USER" -p"$ADMIN_DB_PASSWORD" "$ADMIN_DB_NAME"'
    # PostgreSQL: the init container creates it and the roles, after step 4 (it runs the
    # migrations first, on the database restored there), then exits:
    docker compose run --rm tokenserver_db_init
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      f=/backups/sync/20261013T030000Z/$ADMIN_DB_NAME.sql.gz
      gunzip -t "$f" && gunzip -c "$f" |
        PGPASSWORD="$ADMIN_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$ADMIN_DB_USER" -d "$ADMIN_DB_NAME" -v ON_ERROR_STOP=1'
    ```

    A dump of the tokenserver from before `ADMIN_DB_PASSWORD` brings the admin UI's old tables back there: they are not copied again (the setup check names them), drop them as the tokenserver user.
6. The storage: prefer to leave it empty. A copy of last night is older than what the browsers have: Firefox gets items back that were changed or deleted since. With the storage empty (a new `syncstorage-db` volume, or [Reset the Sync data](#sync-data-of-an-account) of each account after the restore) each Firefox finds the server empty and uploads what it has. Restore it only when no device has the data any more, as in step 4 with `$STORAGE_DB_NAME`, `$STORAGE_DB_HOST`, `$STORAGE_DB_USER` and `$STORAGE_DB_PASSWORD`. With PostgreSQL the storage is in the one dump of step 4, it comes back with the tokenserver: reset the Sync data of each account afterwards to have it empty.
7. `docker compose up -d`. The migrations bring an older schema up to date; the overview records the change of the schema levels (an event of kind `update`).

With Quadlets, stop every unit but the databases, including the one-shot units that ran at start (they stay "active" and would not run again):

```bash
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service \
  firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service
# with the accounts
systemctl --user stop firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
  firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service firefox-sync-fxa-auth.service \
  firefox-sync-fxa-policy.service firefox-sync-fxa-migrations.service
```

Then read each file out of the volume into the database container, as its own user:

```bash
set -o pipefail   # a missing or broken dump fails its line, instead of an empty restore
run=20261013T030000Z
dump() { podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts gunzip -c "/backups/$1"; }
for db in fxa fxa_oauth fxa_profile pushbox ffs; do   # MariaDB accounts: mariadb and $MARIADB_ROOT_PASSWORD
  podman exec firefox-sync-fxa-db sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e 'CREATE DATABASE IF NOT EXISTS $db'"
  dump accounts/$run/$db.sql.gz | podman exec -i firefox-sync-fxa-db sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $db"
done
dump sync/$run/tokenserver.sql.gz | podman exec -i firefox-sync-tokenserver-db sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
dump sync/$run/ffs_admin.sql.gz | podman exec -i firefox-sync-tokenserver-db sh -c 'mariadb -u"$ADMIN_DB_USER" -p"$ADMIN_DB_PASSWORD" "$ADMIN_DB_NAME"'
# only when no device has the data any more (step 6 above)
dump sync/$run/syncstorage.sql.gz | podman exec -i firefox-sync-syncstorage-db sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
```

With `SYNC_DB=mysql` the Sync databases take `mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"`. The files are named after the databases of `.env` (`SYNC_TOKENSERVER_DB_NAME`, `SYNC_STORAGE_DB_NAME`).

Start them again as at install: the Sync server and the accounts' units pull in the one-shot ones. `firefox-sync-fxa-policy.service` must run again: the dump of `fxa` has no trigger of the sign-up policy, and without it only the admin UI's gate holds closed or allowlist sign-ups.

```bash
systemctl --user start firefox-sync-syncstorage.service
# with the accounts
systemctl --user start firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
  firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service
```

### A restore test

Now and then, check that a dump restores, into a scratch database next to the real ones, without stopping anything (this is what `tests/e2e-fxa.sh` does):

```bash
docker compose run --rm --no-deps --entrypoint sh backup-fxa -c '
  run=$(ls -1d /backups/accounts/* | tail -1); db="mysql -h $FXA_DB_HOST -u$FXA_DB_USER -p$FXA_DB_PASSWORD"
  $db -e "CREATE DATABASE ffs_restore_test" && gunzip -c $run/fxa.sql.gz | $db ffs_restore_test &&
  $db -e "SELECT COUNT(*) AS restored FROM ffs_restore_test.accounts; SELECT COUNT(*) AS now FROM fxa.accounts"
  $db -e "DROP DATABASE ffs_restore_test"'
```

The two counts match (or the restored one is a bit lower: accounts created since the night). The tokenserver user cannot create databases: for the Sync databases `gzip -t` is checked at every run; the full test is a restore on another machine, with a copy of `.env` (what `tests/e2e.sh` does, see [Tests](#tests)).

## Confirm pages

Everything that deletes or cannot be undone goes through a page that says what happens (a GET, nothing changes), whose form does it (a POST with the session's token, the route scripts and the tests use directly). The other forms are one click, because nothing is lost and the result message says what changed:

- saving the sign-up policy, closing sign-ups too: it is undone by saving again, existing accounts keep working, and the policy's text and radio buttons are a deliberate edit, not a stray click. Entries taken out of the allowlist textarea there are removed with it, as typed;
- max users and max accounts: lowering them refuses new accounts only, nobody already in is touched;
- invitations, a test email, a test notification (it sends a message, nothing changes), enabling an account, lifting a rate-limit block, notes, signing out of the admin UI.

## Notes

Each account has a note, up to 500 characters on one line: who it is, why it was disabled. Edit it on the account page; the accounts list shows it under the email, or next to the account id with Mozilla's accounts, where it is the only way to tell whose an account is. The reason given when disabling an account is added to its note. Notes are kept in the admin UI's database (`ffs_account_notes`), with who changed them last, and every change is in the event log. Like the event log they are personal data: deleting an account for good removes its note (from its page, by the purge, or with the old unconfirmed accounts).

## Rate limits and the client IP address

The accounts service limits sign-in attempts per client IP address, which it takes from `X-Forwarded-For` at a fixed position from the end: `FXA_CLIENT_ADDRESS_DEPTH`, 2 by default for one reverse proxy in front of the stack. Mozilla's default (3, for their load balancers) let any client pick its IP address by sending its own `X-Forwarded-For`, and get around the limits. With another proxy in front of yours (a CDN, a load balancer), add 1 for each.

## Tests

[`tests/e2e-fxa.sh`](/tests/e2e-fxa.sh) runs [`tests/test_fxa_admin.py`](/tests/test_fxa_admin.py) against the full stack: the SMTP health row and a test email in the mail catcher, the public URLs through the HTTPS proxy with their certificates and the sign-up gate (the probe creates no account with open sign-ups), the schema levels, an invitation (the email with this server's values, invited then signed up, removed) and in open and closed mode, the Connect a device page, the Configuration page (the accounts' values, no secret); refused sign-ups through the gate and directly to the accounts service, the allowlist, closing and reopening sign-ups, the accounts list, disabling an account, max users, max accounts (full: the gate says so, the database refuses it directly, the line, the health row, the event and Prometheus; room again; no limit), what an account stores, the metrics and the event log, health and database sizes, the badges, lifting a rate-limit block and the attempts close to one, signing out a session, a device of a session and a device of a refresh token, the alert emails (in the mail catcher) and the same alerts to a webhook (`ADMIN_NOTIFY`, a small receiver in the test stack, [`tests/notify_sink.py`](/tests/notify_sink.py)) with the setup check of the accounts' SMTP server, Prometheus, the password and form checks, and the `X-Forwarded-For` spoofing; the confirm pages, signing out everywhere (a new sign-in works at once), that disabling also ends a password reset started before, the audit trail naming the account and the admin, and that `ffs_admin` cannot delete FxA's tokens itself; two-step authentication turned on through the accounts API (badge, backup codes) and off from the admin UI (sign-in without the authenticator, the owner's notice in the mail catcher), the schema levels of the accounts "not recorded by FxA", removing from the allowlist and pruning through their confirm pages, a recovery key removed, secondary emails listed, an email confirmed from the admin UI then a Sync token, the security history (with `FXA_ACCOUNT_EVENTS=true`, which `tests/e2e-fxa.sh` sets: a sign-in, a password change (one alert, no "password reset"), two-step authentication turned on, its authenticator app replaced and turned off, new backup codes, a recovery key created and removed and a forgotten password reset on the account page with the IP address, their events and alerts of kind `security`, Prometheus, and a second sign-in from the same address still asking the code; then the accounts service and the admin UI restarted with it off: nothing more recorded, the account page says how to turn it on), unconfirmed sign-ins and the last use from Redis, a member blocked by the rate limits (one alert, none for an unknown email, lifted from the account page), notes and the disable reason; a Sync client after its data was reset (a working token on empty storage, a new row once its slot is freed), deleting an account (refused while it is enabled, by the procedure itself, and with a wrong email typed; then gone from the accounts service, the list, max users, the tokenserver, the storage and the allowlist), an account its owner deleted showing as an orphan and purged, pruning (an old unblock code and an old session without a device go, an old session with a device stays) and deleting old unconfirmed accounts (a fresh one stays), Needs attention with a blocked member and an inactive device (its badge on the account page), the lists of a badge alone, the search by part of an email and by account id, the accounts list newest first.

`tests/e2e-fxa.sh` also checks `FXA_MAX_ACCOUNTS` like `SYNC_MAX_USERS` (written by `prepare_environment.sh`, refused when not valid, kept from the page with `initial:`, replaced by a plain number, `ffs.signup_refusal` with 0 and unlimited), runs the backups of the accounts and of Sync (five dumps passing `gzip -t`, both runs in `ffs_backups` and in Prometheus), restores the dump of `fxa` into a scratch database with every account and procedure, then drops it, and checks that `ffs_admin` reads the views but no secret column (`sharedSecret`, `codeHash`, `recoveryData`, `phoneNumber`, `emailCode`), with the accounts on MySQL, MariaDB and your own server.

A real Firefox follows the link of an invitation (the sign-up page with the email), checks the error shown for a refused sign-up, that the admin UI lists its two devices and its bookmarks, fits a 360 pixel wide screen (the overview, Activity, Security and Configuration), and disables the account through the confirm page with the CSP enforced ([`tests/test_fxa_browser.py`](/tests/test_fxa_browser.py)).

[`tests/e2e.sh`](/tests/e2e.sh) and [`tests/podman.sh`](/tests/podman.sh) check max users with `SYNC_MAX_USERS=N` (set again on every start, read-only page), `SYNC_MAX_USERS=initial:N` (set on the page, kept across restarts), `unlimited` (the trigger lets everybody in, also from the page's "No limit") and `0` (nobody new), that the UI and the gate start with compose and Quadlets and reach every component (Prometheus `ffs_up`), the container healthcheck, signing in over `http://localhost` with the default cookie, that the Sync server sends its metrics (and is restarted with a new admin UI container), the pruning of old metrics and events (the audit trail kept longer), the event filters and pages, a label on an account of Mozilla's accounts, the tokenserver rows after a key change and the search by tokenserver uid, resetting the Sync data (one collection, all of it, freeing the slot) and syncing again, the storage report and a purge of expired items and replaced keys that leaves the live data, deleting the Sync data of an account id, the schema levels, the setup checks (an account of another email domain is a warning), the accounts per node, the Connect a device page, the Configuration page (the values of the stack, where max users comes from, no secret), no SMTP row without `FXA_SMTP_HOST` (and nothing about it in Needs attention: the alerts go to `ADMIN_NOTIFY`) and no public checks with `ADMIN_PUBLIC_CHECK=false`, the alerts without email to a webhook and a Slack-style destination of the test stack (the JSON of [the schema](#alerts), the token in its header, the Notifications row, the test notification, Prometheus, no token on any page), a Sync server going down and back up, that the logs have no background errors, and with `COMPOSE_PROFILES=backup` and `BACKUP_KEEP=1` two backup runs (recorded, one copy kept, the dumps passing `gzip -t`, 0600), a failed run (recorded, its event and alert, then "works again"), the backup line on the overview and `ffs_backup_age_seconds`, the line of a full max users (its health row, gauges and event), the errors by kind (a request without Hawk, an item that is no JSON object and a refused token on the Activity page and in `ffs_sync_errors_total`) and the rows of the error rate and the growth, the search by tokenserver uid; with `EXTERNAL_DB=1` the INSERT of your own backups. Both start as an install from before `ADMIN_DB_PASSWORD` (the admin UI's tables in the tokenserver database; `e2e.sh` with `UPGRADE_FROM` runs that release itself, its compose files, admin UI and init image), add an audit event, a note and a backup run there, then upgrade (`podman.sh` with `prepare_environment.sh --upgrade`): the tables move into `ffs_admin` once (also after a restart), the old ones are dropped, and the Sync server's users cannot read, add to or delete from the event log (`e2e.sh`: with MariaDB, MySQL, PostgreSQL and your own servers; in the stack's PostgreSQL container the Sync server's own role, no superuser, owns the Sync tables and cannot connect to `ffs_admin`). The admin UI's reader `ffs_admin_sync` cannot change the tokenserver's tables but through the init container's procedures and cannot read the event log, `ffs_admin_ui` cannot read the Sync databases, and a procedure (MariaDB, MySQL) or function (PostgreSQL) the Sync server's user puts in place of the init container's, with `SQL SECURITY INVOKER`, cannot delete the audit trail or open `ffs_admin` when the admin UI runs it; the init container puts its own back. A new install has the admin UI's users from the first start of the database containers (MySQL: through `mysqld --initialize`). The backups dump `ffs_admin` with the audit trail, the dump restores as `ffs_admin_ui` over its tables, and with PostgreSQL the dump of the Sync database names no role and restores into an empty database with `ON_ERROR_STOP`. At the end they restore a backup the way [Restoring](#restoring) says, as on a new host: two accounts store their data, the backups volume is copied off the host, the stack goes down, the volumes of the databases and of the backups are removed, the copy is put back, and each dump is loaded into the empty databases as its user; then every table has the same rows, the triggers and procedures are back, and after `docker compose up -d` the two accounts get their uids and read back what they stored (MariaDB, MySQL 8 and PostgreSQL).

`tests/e2e.sh` also signs in through [Dex](https://dexidp.io) with OpenID Connect and with a trusted header ([`tests/test_admin_auth.py`](/tests/test_admin_auth.py)): an allowed user or group gets in, anybody else, a replayed callback, a tampered state or code are refused, a header that changes or disappears ends the session, forms need the session token, and the event log says who signed in and how.

[`tests/helm.sh`](/tests/helm.sh) `e2e` turns the admin UI on and off with `helm upgrade` (the Sync server Ready both ways, its metrics only while the admin UI is there), signs in with the Secret's `ADMIN_PASSWORD` through a port-forward, checks that the overview shows the Sync server, the account of the client flow and the `kubectl` commands (no docker compose), runs a backup with the overview's `kubectl create job` command and finds it on the Backups card ("every night at 03:00 UTC"), restores its dumps as [Restoring](#restoring) says into empty database servers like the chart's, checks `/metrics` with `admin.metricsToken`, and that `admin.metricsToken` emptied in the values is emptied in the Secret.

`tests/podman.sh` checks the backup timer (installed, off) and a backup by hand with the Quadlets, with the accounts too, a restore of the Sync databases as Restoring says for the Quadlets (the units stopped, rows deleted, the dumps read out of the volume into the database containers: every table as it was, the units started again), and that the admin UI quadlets get `BACKUP_TIME`, `BACKUP_KEEP`, `ADMIN_DEPLOYMENT=quadlets` and `FXA_MAX_ACCOUNTS` (fxa-policy too).

The program itself has unit tests (`cd admin && go test ./...`): the age and failure of the backups and their alerts, each line of Needs attention, the thresholds and the limits alerting once per state, the errors by kind of real captured statsd packets, the error-rate spike (minimum volume, baseline, its end) and the growth per day (history needed, the MB and factor rules, gaps), the limits' values, rows and forms, the security history (the account page on and off, the events alerted once, a burst read page by page without skipping the alerts after it, which of Mozilla's events alert, the counters), each destination of `ADMIN_NOTIFY` against a local server (the request, its escaping and length limits, one retry on a 5xx or no answer, none on a 4xx, the timeout, the URLs and their errors, no token in the errors, the logs, the pages or Prometheus, the caps per kind and the queue of each destination, the test notification), that every POST form of the pages is either behind a confirm page or one of the one-click forms above, the paging and the search; that the Configuration page shows no secret with a value of its own in every variable of the admin UI, and that every variable the code reads or compose and the Quadlets pass is classified as a secret or not (a secret-looking name classified as shown, or a secret of `.env` the admin UI does not need, fails).
