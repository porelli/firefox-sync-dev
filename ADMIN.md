# Admin UI

A small web page to manage who can use your server, optional (`COMPOSE_PROFILES=admin`):

- **Sync**: how many accounts use the server, change the maximum without restarting anything (with `MAX_USERS=initial:N`, see [Max users](#max-users)).
- **Sign-ups**, with [self-hosted accounts](FXA.md): anybody, only some emails and domains (allowlist), or nobody.
- **Accounts**, with self-hosted accounts: who signed up, when they last synced and how much they store, disable and re-enable an account.
- **Per account**: what it stores on the Sync server per collection (bookmarks, history, passwords...: items, size, last change; the data itself is encrypted by Firefox, the server cannot read it) and, with self-hosted accounts, its devices and sessions.
- **Activity**: Sync requests, Sync tokens issued, errors and the size of the databases over the last 24 hours, 7 or 30 days, and an event log: sign-ins to the admin UI, changes made in it, refused sign-ups, components going down and up, new releases and, with self-hosted accounts, new accounts and new devices.
- **Health**: whether each component answers (Sync server, databases, and the accounts services), the versions running and whether a newer release is out.
- **Inactive and unconfirmed accounts** are marked in the list: not synced for `ADMIN_STALE_DAYS` (90), or email never confirmed after 3 days.
- **Security**, with self-hosted accounts: who the accounts service is blocking after too many attempts (wrong passwords, codes), and who is getting close. Lift a block, e.g. when it is you.
- **Sign out a device or a session** of an account, e.g. a lost laptop, without disabling the whole account.
- **Email alerts** and **Prometheus metrics**, see below.

With Mozilla's accounts there are no sign-ups to control and the server only knows account ids: the page shows the Sync part only.

The image (`ghcr.io/porelli/firefox-sync:admin-latest`, amd64 and arm64) is built from [admin/](/admin): a single Go program in a distroless image, no shell, running as an unprivileged user. Its only dependencies are the MariaDB/MySQL and PostgreSQL drivers, and for single sign-on [go-oidc](https://github.com/coreos/go-oidc) and [golang.org/x/oauth2](https://pkg.go.dev/golang.org/x/oauth2).

## Setup

`./prepare_environment.sh` asks "Enable the admin UI?" (default yes), generates `ADMIN_PASSWORD`, sets `COMPOSE_PROFILES=admin` and `MAX_USERS=initial:<the number you gave>` in `.env`; with self-hosted accounts it also offers to sign in with them, see [Signing in](#signing-in). By hand:

```
COMPOSE_PROFILES=admin             # with the pairing server: admin,pairing
ADMIN_PASSWORD=<at least 12 characters, random>
ADMIN_EXPORT_PORT=127.0.0.1:8090
```

then `docker compose up -d`. With Quadlets, starting `firefox-sync-syncstorage.service` also starts `firefox-sync-admin.service`.

On [your own database server](DATABASES.md) the admin UI connects as the Sync users (`MARIADB_*` or `POSTGRES_*`) and, with self-hosted accounts, as `ffs_admin`, which `database-setup-fxa.sql` creates there (the sign-up policy gives it its grants): nothing else to set up.

## Max users

`MAX_USERS` in `.env` says who sets the limit:

| `MAX_USERS` | the init container | the admin UI |
|---|---|---|
| `5` or `fixed:5` | sets 5 on every start, replacing any change | read-only |
| `initial:5` | sets 5 only when there is no limit yet (first start, new database) | changes it, and they are kept across restarts |

The limit applies at once either way: a trigger of the tokenserver database checks it for every new account. Switching is a change like any other: from `initial:5` to `5`, 5 is set again on the next start (`docker compose up -d`, or `systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-admin.service`); from `5` to `initial:5`, the value in the database stays and the page can change it. Anything else in `MAX_USERS` (empty, not a number) stops the init container, and with it the Sync server.

The page listens on `127.0.0.1:8090` only. The simplest and safest way to reach it from your computer is an SSH tunnel, without publishing it at all:

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

Sign-in: `ADMIN_PASSWORD` from `.env`, or single sign-on, see [Signing in](#signing-in). The session cookie is `Secure`, `HttpOnly` and `SameSite=Strict`, every form carries a token of the session, and after 5 wrong passwords in a minute sign-ins wait a minute. Sessions last 12 hours and end when the container restarts. Over plain HTTP other than `localhost`, set `ADMIN_INSECURE_COOKIE=1` (not recommended).

## Signing in

Three ways, each on when it is configured in `.env`, any combination; with none of them the admin UI does not start. Whatever the way, you get the same session, and the event log (and the alerts) record who signed in and how: `signed in: alice@example.com (oidc)`, `(header)` or `(password)`. Refused sign-ins (a wrong password, not an admin, email not verified, a sign-in that did not start here) are logged too, as `sign-in` events: anybody can cause those, so they have their own share of the event log and the alerts, and cannot push the sign-ins and the changes out. A callback with no state cookie is not logged at all, a bad state at most every 10 minutes.

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

- The header counts only on connections whose own address (not `X-Forwarded-For`) is in `ADMIN_TRUSTED_PROXIES`, from anywhere else it is ignored. With a proxy on the host and the admin UI published on `127.0.0.1:8090`, the admin UI sees the gateway of the compose network (`docker network inspect <project>_default -f '{{(index .IPAM.Config 0).Gateway}}'`, the project being the directory name unless `COMPOSE_PROJECT_NAME` says otherwise). With Podman it depends on the network backend (rootlessport, pasta): check from which address the requests of your proxy arrive. Then any program on the host, and anybody with an SSH tunnel to it, connects from that address too: trust a whole host only if you trust everybody on it. A proxy running as a container on the stack's network, with a fixed address and the admin UI not published at all, narrows it down to that proxy.
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

The Sync server (syncstorage-rs and its tokenserver) sends its statsd metrics to the admin UI over UDP (port 8125, inside the stack's network only). syncstorage-rs refuses to start when its metrics host does not resolve, so it only sends them when the admin UI is running when it starts: compose and the Quadlets start the admin UI first when it is enabled, and the Sync server starts as before without it. It also looks up the address of the admin UI only then, so a new admin UI container (update, `docker compose up -d` after a change) restarts the Sync server. If the activity page says no metrics arrive, restart the Sync server.

Metrics are kept per minute and the event log as is, both in the tokenserver database (tables `ffs_metrics` and `ffs_events`), for `ADMIN_RETENTION_DAYS` (30 by default). The event log contains the emails of refused sign-ups, at most 30 entries a minute for each kind of event.

## Email alerts

Set `ADMIN_ALERT_EMAIL` to get an email when a sign-up is refused, a component goes down or comes back, a new release is out, someone signs in to the admin UI (or fails to), and with self-hosted accounts when an account or a device is added. Alerts are collected and sent at most every 10 minutes. They go through the SMTP server of `FXA_SMTP_*` in `.env`, which you fill in for alerts even without self-hosted accounts. The password is only sent over TLS (STARTTLS, or `FXA_SMTP_SECURE=true` on port 465). At most 20 alerts of each kind go in one email, the rest are counted; the emails of refused sign-ups are shortened and stripped of line breaks, those that do not look like an email are recorded as "invalid email".

## Prometheus

With `ADMIN_METRICS_TOKEN` set, `http://ffs-admin:8080/metrics` (on the stack's network, or `ADMIN_EXPORT_PORT`) serves Prometheus metrics to whoever sends `Authorization: Bearer <token>`:

| metric | |
|---|---|
| `ffs_up{component}` | 1 if the component answers its health check |
| `ffs_sync_accounts`, `ffs_sync_max_users` | accounts using Sync, the limit |
| `ffs_sync_stored_items`, `ffs_sync_stored_bytes` | what all accounts store |
| `ffs_accounts` | accounts of the self-hosted accounts service |
| `ffs_database_bytes{database}` | size of each database, measured every hour |
| `ffs_statsd_total{name}`, `ffs_statsd_ms_total{name}` | the statsd metrics of the Sync server since the admin UI started |

```yaml
scrape_configs:
  - job_name: firefox-sync
    authorization:
      credentials: <ADMIN_METRICS_TOKEN>
    static_configs:
      - targets: ["ffs-admin:8080"]
```

## Versions and new releases

Every 12 hours the admin UI asks GitHub for the newest releases of syncstorage-rs and of Mozilla accounts, and shows when the running version is older. The images of this repository follow the upstream releases within a week (they are built and tested every Monday). `ADMIN_UPDATE_CHECK=false` turns it off: the admin UI then never connects to the internet.

## Who can sign up (self-hosted accounts)

`FXA_SIGNUPS` in `.env`, or the page:

| `FXA_SIGNUPS` | who can create an account |
|---|---|
| `open` (default) | anybody who can reach your accounts pages |
| `allowlist` | only the emails (`alice@example.com`) and domains (`@example.com`) of `FXA_SIGNUP_ALLOWLIST`, comma-separated |
| `closed` | nobody |

Existing accounts are never affected: disable them in the accounts list instead.

How it works:

- The accounts database refuses the account itself: `fxa-policy`, which runs before the accounts service on every start, installs a trigger on the accounts table (and the `ffs` database it reads the policy from). Nothing reaching the accounts service, whatever the path, can create an account the policy does not allow.
- So that people see why, the admin UI also answers sign-up requests itself: point `POST /v1/account/create` of your accounts API host name to `ADMIN_GATE_EXPORT_PORT` (`127.0.0.1:8091`). `config/nginx/fxa-example.conf` does it, `prepare_environment.sh` removes it when you don't enable the admin UI. Refused sign-ups then get "The request was blocked for security reasons" on the sign-up page, instead of "Unexpected error". Everything else goes to the accounts service directly.
- `.env` and the page both change the policy: the values in `.env` are applied when you change them there (on the next `docker compose up -d`), otherwise what you set on the page stays. `MAX_USERS` works differently, see [Max users](#max-users).

## Disabling an account

Disable signs the account out of every device, refuses new sign-ins and revokes its OAuth tokens (in the accounts database and in Redis), so the sync server refuses the account's access tokens from then on. Firefox can still sync with what it already has for up to about an hour: the sync server remembers a verified access token for 5 minutes, and a Sync token it handed out stays valid for up to 1 hour. Enable gives the account back, with its data, after a new sign-in.

`FXA_ACCESS_TOKEN_LIFETIME` (`60 minutes` by default, any duration like `2 hours`) is how long the access tokens of Firefox live. Revoking makes the lifetime irrelevant for disabled accounts; a short one is a backstop in case revoking fails (the page tells you), at the cost of Firefox asking for a new token every hour, nothing a small server notices. Mozilla's default is `365 minutes`. Keep the lifetime as is if you turn on JWT access tokens (`JWT_ACCESS_TOKENS_ENABLED_CLIENT_IDS`, off by default): those living 6 hours or less are checked by their signature only and cannot be revoked.

Mozilla's own admin panel (not part of this stack) disables accounts the same way, without revoking the tokens.

## Signing out a device or a session

Sign out on the account page removes the device and the session or OAuth refresh token it signed in with, so it cannot get new access tokens. The access tokens it already has keep working until they expire (`FXA_ACCESS_TOKEN_LIFETIME`, 60 minutes by default), and like after disabling, the sync server may accept them for up to an hour more. To lock a device out at once, disable the account (and enable it again).

The admin UI connects to the accounts database as `ffs_admin`, which can read the accounts and disable them, but never sees the token ids (a session token id signs in as its account): sessions and devices are listed and signed out through views and procedures that `fxa-policy` installs.

## Rate limits and the client IP address

The accounts service limits sign-in attempts per client IP address, which it takes from `X-Forwarded-For` at a fixed position from the end: `FXA_CLIENT_ADDRESS_DEPTH`, 2 by default for one reverse proxy in front of the stack. Mozilla's default (3, for their load balancers) let any client pick its IP address by sending its own `X-Forwarded-For`, and get around the limits. With another proxy in front of yours (a CDN, a load balancer), add 1 for each.

## Tests

[`tests/e2e-fxa.sh`](/tests/e2e-fxa.sh) runs [`tests/test_fxa_admin.py`](/tests/test_fxa_admin.py) against the full stack: refused sign-ups through the gate and directly to the accounts service, the allowlist, closing and reopening sign-ups, the accounts list, disabling an account, max users, what an account stores, the metrics and the event log, health and database sizes, the badges, lifting a rate-limit block and the attempts close to one, signing out a session, a device of a session and a device of a refresh token, the alert emails (in the mail catcher), Prometheus, the password and form checks, and the `X-Forwarded-For` spoofing. A real Firefox checks the error shown for a refused sign-up, and that the admin UI lists its two devices and its bookmarks ([`tests/test_fxa_browser.py`](/tests/test_fxa_browser.py)). [`tests/e2e.sh`](/tests/e2e.sh) and [`tests/podman.sh`](/tests/podman.sh) check max users with `MAX_USERS=N` (set again on every start, read-only page) and `MAX_USERS=initial:N` (set on the page, kept across restarts), that the UI and the gate start with compose and Quadlets and reach every component (Prometheus `ffs_up`), the container healthcheck, signing in over `http://localhost` with the default cookie, that the Sync server sends its metrics (and is restarted with a new admin UI container), the pruning of old metrics and events, a Sync server going down and back up, and that the logs have no background errors. The program itself has unit tests (`cd admin && go test ./...`).
