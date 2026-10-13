# Admin UI

A small web page to manage who can use your server, optional (`COMPOSE_PROFILES=admin`):

- **Sync**: how many accounts use the server, change the maximum without restarting anything (with `MAX_USERS=initial:N`, see [Max users](#max-users)).
- **Sign-ups**, with [self-hosted accounts](FXA.md): anybody, only some emails and domains (allowlist), or nobody. The emails of the allowlist say whether they signed up yet, and each one can be removed.
- **Invitations**, with self-hosted accounts: an email with the link to create the account and the steps to set up Firefox, and the address added to the allowlist. **Connect a device**: the same steps on a page, with this server's values. See [Invitations](#invitations-and-connect-a-device).
- **Accounts**, with self-hosted accounts: who signed up, when they last synced and how much they store, disable and re-enable an account, sign it out everywhere.
- **Per account**: what it stores on the Sync server per collection (bookmarks, history, passwords...: items, size, last change; the data itself is encrypted by Firefox, the server cannot read it) and, with self-hosted accounts, its devices and sessions (confirmed or not, and when they were really last used), how it signs in and its emails, see [Helping account owners](#helping-account-owners).
- **Sync data of an account**: every row the tokenserver has for it (one per set of keys) with what each stores, and what looks wrong there in plain words; start its Sync data over, all of it or one collection, optionally freeing its max users slot; find an account by email, account id or tokenserver uid. See [Sync data of an account](#sync-data-of-an-account).
- **Delete an account for good**, a disabled one, with its Sync data (with Mozilla's accounts: the Sync data of an account id). See [Deleting an account](#deleting-an-account).
- **Storage**: live, expired and orphaned data (replaced keys, deleted accounts, storage with no tokenserver row), stale uploads, the largest accounts, and a purge, by hand or every day (`ADMIN_PURGE=1`). See [Storage](#storage).
- **Maintenance**, with self-hosted accounts: expired tokens and codes pruned every day, old unconfirmed accounts deleted (`ADMIN_DELETE_UNCONFIRMED_DAYS`), an alert on a burst of sign-ups (`ADMIN_SIGNUP_BURST`). See [Maintenance and retention](#maintenance-and-retention).
- **Notes**: a note per account, up to 500 characters, shown in the accounts list; with Mozilla's accounts it is the label next to the bare account id.
- **Activity**: Sync requests, Sync tokens issued, errors and the size of the databases over the last 24 hours, 7 or 30 days, and an event log: sign-ins to the admin UI, changes made in it (who, how they signed in, on which account), refused sign-ups, components going down and up, new releases and, with self-hosted accounts, new accounts and new devices. Filter it by kind and by text (an email), page back through all of it.
- **Health**: whether each component answers (Sync server, databases, and the accounts services), the versions running and whether a newer release is out, the schema of each database. Also the SMTP server of the alerts, and what the internet sees: the public https URLs, their certificates, the sign-up gate behind your reverse proxy, see [Public checks](#public-checks).
- **Setup checks**: settings that must agree, with what goes wrong when they do not: the Sync node and `SYNCSTORAGE_DOMAIN`, `FXA_OAUTH_SERVER_URL`, `FXA_EMAIL_DOMAIN`; the accounts on each Sync node. See [Setup checks](#setup-checks).
- **Needs attention**, at the top of the overview: what to look at now, one line each with a link to where it is fixed, or "All good". See [Needs attention](#needs-attention).
- **Backups**, optional (`COMPOSE_PROFILES=backup`): every night a dump of each database into a volume, the last one on the overview, an alert when one fails or is too old. See [Backups](#backups).
- **Search the accounts** on the overview: part of an email, an account id, a tokenserver uid or a note; the list shows 50 accounts a page, newest first. See [Finding an account](#finding-an-account).
- **Inactive and unconfirmed accounts** are marked in the list: not synced for `ADMIN_STALE_DAYS` (90), or email never confirmed after 3 days. Inactive accounts are only marked, never deleted by themselves; old unconfirmed ones can be, see [Maintenance and retention](#maintenance-and-retention). With self-hosted accounts also `2-step` (two-step authentication on), `no recovery key`, `unconfirmed sign-in` (a sign-in that never entered its email code), `blocked` (by the rate limits) and `inactive device` (a device not used for `ADMIN_STALE_DAYS`, marked `inactive` on the account page).
- **Security**, with self-hosted accounts: who the accounts service is blocking after too many attempts (wrong passwords, codes), and who is getting close. Lift a block, e.g. when it is you, there or on the account page. An alert when an existing account gets blocked.
- **Sign out a device or a session** of an account, e.g. a lost laptop, without disabling the whole account.
- **Email alerts**, a test email, and **Prometheus metrics**, see below.
- **Confirm pages**: disabling, signing out everywhere, signing out a device or a session, turning off two-step authentication, removing a recovery key, confirming an email, resetting or deleting Sync data, deleting an account, purging the storage and deleting unconfirmed accounts first show what will happen (the account, the devices and sessions that get signed out), with an optional reason for the event log. Nothing destructive happens in one click.
- **Local time** (`ADMIN_TZ`) and **phones**: the pages work on a narrow screen, wide tables scroll inside their box.

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

Sign-in: `ADMIN_PASSWORD` from `.env`, or single sign-on, see [Signing in](#signing-in). The session cookie is `Secure`, `HttpOnly` and `SameSite=Strict`, every form carries a token of the session, and after 5 wrong passwords in a minute sign-ins wait a minute. Sessions last 12 hours and end when the container restarts. Over plain HTTP other than `localhost`, set `ADMIN_INSECURE_COOKIE=1` (not recommended).

## Max users

`MAX_USERS` in `.env` says who sets the limit:

| `MAX_USERS` | the init container | the admin UI |
|---|---|---|
| `5` or `fixed:5` | sets 5 on every start, replacing any change | read-only |
| `initial:5` | sets 5 only when there is no limit yet (first start, new database) | changes it, and they are kept across restarts |

The limit applies at once either way: a trigger of the tokenserver database checks it for every new account. Switching is a change like any other: from `initial:5` to `5`, 5 is set again on the next start (`docker compose up -d`, or `systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-admin.service`); from `5` to `initial:5`, the value in the database stays and the page can change it. Anything else in `MAX_USERS` (empty, not a number) stops the init container, and with it the Sync server.

## Signing in

Three ways, each on when it is configured in `.env`, any combination; with none of them the admin UI does not start. Whatever the way, you get the same session, and the event log (and the alerts) record who signed in and how: `signed in: alice@example.com (oidc)`, `signed in: alice@example.com (header)` or `signed in (password)`. Refused sign-ins (a wrong password, not an admin, email not verified, a sign-in that did not start here) are logged too, as `sign-in` events: anybody can cause those, so they have their own share of the event log and the alerts, and cannot push the sign-ins and the changes out. A callback with no state cookie is not logged at all, a bad state at most every 10 minutes.

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

Metrics are kept per minute and the event log as is, both in the tokenserver database (tables `ffs_metrics` and `ffs_events`, next to `ffs_account_notes` for the notes), for `ADMIN_RETENTION_DAYS` (30 by default). The events of kind `admin`, the audit trail, are kept for `ADMIN_AUDIT_RETENTION_DAYS` (365 by default). At most 30 entries a minute are recorded for each kind of event, except `admin`: every change is kept.

Every change made in the admin UI is recorded with who made it and how they signed in, and for an account its email and the start of its id:

```
Disabled alice@example.com (uid 3f2a1b2c) by bob@example.org (oidc): lost laptop
Max users set to 5 by admin (password)
```

`admin (password)` is whoever has `ADMIN_PASSWORD`; with single sign-on or the header it is their email. The text after the colon is the reason typed on the confirm page, if any. The Activity page filters the log by kind and by text (`/activity?kind=admin&q=alice@example.com`, any case) and shows 100 events a page, with a link to the older ones; the account page links to the events of its email.

The event log holds personal data: the emails of accounts and of refused sign-ups, the emails of the admins, the reasons typed. When an account is deleted (by its owner in the account settings, or here: that event keeps its email, on purpose, for the audit trail), the events naming it stay until their retention runs out, they are not rewritten. To remove them sooner, delete them in the tokenserver database, e.g. `DELETE FROM ffs_events WHERE detail LIKE '%alice@example.com%';`.

## Time zone

The pages and the alert emails show times in UTC. Set `ADMIN_TZ` to a name of the [tz database](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones), e.g. `ADMIN_TZ=Europe/Rome`, for local time (`TZ` works too, `ADMIN_TZ` wins). Each page says the zone once at the bottom, each email once at the end. A name the admin UI does not know is logged as a warning, and the times stay in UTC. The admin UI carries its own copy of the tz database (the image has none).

## Email alerts

Set `ADMIN_ALERT_EMAIL` to get an email when a sign-up is refused, a component goes down or comes back, a new release is out, a database schema changes, someone signs in to the admin UI (or fails to) or changes something there (sign-up policy, max users, disabling and enabling, signing out, lifting a block, two-step authentication, recovery keys, confirming an email, notes, invitations), a backup fails or gets older than 36 hours (and works again), 90% of max users are taken, the Sync server sends no metrics for 30 minutes, alert emails fail (each of these three once when it starts and once when it ends), and with self-hosted accounts when an account or a device is added or an account gets blocked by the rate limits. Alerts are collected and sent at most every 10 minutes. They go through the SMTP server of `FXA_SMTP_*` in `.env`, which you fill in for alerts even without self-hosted accounts. The password is only sent over TLS (STARTTLS, or `FXA_SMTP_SECURE=true` on port 465). At most 20 alerts of each kind go in one email (sign-ins and changes in the admin UI are one kind, `admin`), the rest are counted; the emails of refused sign-ups are shortened and stripped of line breaks, those that do not look like an email are recorded as "invalid email".

Whether the alerts arrive:

- **Email (SMTP)** in the Health table: every hour, with `FXA_SMTP_HOST` set, the admin UI connects to the SMTP server, starts TLS and signs in, then leaves without sending anything. A wrong password or a server that does not answer turns it down: an event, and an alert, which goes out once the server works again (alerts that could not be sent wait, at most 20 of each kind, the newest; the rest are counted by kind). While it is down it tries again every 10 minutes, not every minute: some servers block an address after a few wrong passwords.
- An email that could not be sent is kept and goes out with the next one (up to 200 lines). The overview says when the last alert email went out, or why the last one failed and how many alerts are waiting; Prometheus has `ffs_alert_last_success_timestamp_seconds`. That is kept in memory: after a restart, "none sent since the start".
- **Send a test email**, under the Health table: one email to `ADMIN_ALERT_EMAIL`, or without it to the admin signed in with single sign-on (never to an address typed in a form). The page shows the SMTP server's answer when it fails. The test is in the event log.

`FXA_SMTP_HOST` left at its placeholder (`<REPLACE_WITH_YOUR_SMTP_SERVER>`) counts as unset.

## Public checks

Every hour the admin UI looks at your server from the outside, the way Firefox does, for each `https://` URL: the Sync node the tokenserver hands out, and with self-hosted accounts `FXA_CONTENT_URL`, `FXA_AUTH_URL` and `FXA_PROFILE_URL`. For each it opens a TLS connection to read the certificate, then asks `/__heartbeat__` through your reverse proxy. The Health table shows `reachable, certificate expires in N days`, Prometheus `ffs_cert_expiry_seconds{host}`. Under 14 days left, or when the URL does not answer, the row turns to a problem, with an event and an alert. While a check fails it runs again every 5 minutes (5 times `HEALTH_CHECK_SECONDS`), so a name the server cannot reach does not hold up the other checks. A Sync node the tokenserver no longer hands out (downed or removed) leaves `ffs_cert_expiry_seconds`.

With self-hosted accounts it also checks that `POST /v1/account/create` of `FXA_AUTH_URL` reaches the [sign-up gate](#who-can-sign-up-self-hosted-accounts): it sends one with an empty body and a header carrying a random token of this start of the admin UI. The gate answers it itself (204, with the token) and passes nothing on. A reverse proxy that sends sign-ups to the accounts service directly gets the empty body to the accounts service, which refuses it: the row says the gate is bypassed. The probe never creates an account, whatever the sign-up policy.

"not reachable from the server" means the server could not connect to its own public name. Often that is split DNS or a firewall: the name resolves to another address inside your network than on the internet, or the server cannot reach its own public address (hairpin NAT). Firefox may well reach it from outside; add the name to the server's `/etc/hosts` or your local DNS if you want the check.

`http://` URLs and unset ones are not checked. `ADMIN_PUBLIC_CHECK=false` (or `0`) in `.env` turns all of them off, and then also the check of `FXA_OAUTH_SERVER_URL` when it is on the internet (Mozilla's accounts), see [Setup checks](#setup-checks).

## Setup checks

The overview lists settings that must agree with each other, each with what goes wrong when it does not:

- **Sync node**: the tokenserver hands out the Sync node in its `nodes` table, which the init container sets from `SYNCSTORAGE_DOMAIN` when it starts. When they differ (`.env` changed, the stack not restarted), the warning names both: Firefox syncs with the one of the table.
- **Sign-in keys** (`FXA_OAUTH_SERVER_URL`): the Sync server checks every sign-in of Firefox with the keys at `FXA_OAUTH_SERVER_URL/jwks` (`/v1` added when missing). Checked every hour. With Mozilla's accounts that is Mozilla's server, on the internet: only with the public checks on.
- **Account emails** (`FXA_EMAIL_DOMAIN`): the tokenserver keeps each account as `<uid>@FXA_EMAIL_DOMAIN`. After `FXA_EMAIL_DOMAIN` changed, everybody comes back as a new account, with empty storage, and counts twice against max users. The warning names the domain set and the others found, with how many accounts each.

The Sync nodes table, in the Sync section, shows the accounts on each node (those whose current keys are there), its capacity, current load, places available and backoff.

## Needs attention

The top of the overview lists what to look at now, one line each, with a link to where it is fixed. Nothing to list: "All good". It is built from what the overview shows anyway:

| Line | Link |
|---|---|
| a component down (the Health table), or the sign-in keys of `FXA_OAUTH_SERVER_URL` | Health, Setup |
| a newer release of a component | Health |
| a certificate of a public URL expiring in less than 14 days | Health |
| sign-ups that bypass the [sign-up gate](#public-checks) | Health |
| the SMTP server does not work, or the last alert email failed | Health, the alert status |
| 90% of max users or more taken (max users 0 is on purpose: not listed) | the max users form |
| a backup failed, or the last good one is older than 36 hours | [Backups](#backups) |
| orphaned Sync data (see [Storage](#storage)) | the purge |
| no metrics from the Sync server for 30 minutes while it is up: it needs a restart (see [Metrics](#metrics-and-the-event-log)). It reports its database pool every few seconds, so a quiet night is not silence | Activity |
| self-hosted accounts: accounts blocked by the rate limits | Security |
| accounts that never confirmed their email; accounts with an unconfirmed sign-in | the list of those accounts (one account: its page) |
| devices not used for `ADMIN_STALE_DAYS` (90), marked `inactive` on the account page | the list of those accounts (one account: its devices) |
| the accounts database not pruned for 2 days (see [Maintenance](#maintenance-and-retention)) | Activity |

The links to a part of the list show only those accounts (`/?show=blocked`, `unconfirmed`, `unconfirmed-sign-in`, `inactive`, `inactive-devices`).

Three of them also alert, and are events of kind `attention`: 90% of max users, no metrics for 30 minutes, alert emails failing. Each alerts once when it starts and once when it ends, not every minute; also at the start of the admin UI when it is already the case. Prometheus has them as `ffs_sync_near_max_users`, `ffs_statsd_silent` and `ffs_alert_send_failing` (1 or 0). The other lines have their own alerts already (components, releases, certificates, blocks, backups).

## Finding an account

The search above the accounts list (a plain form, `/?q=`) finds what contains it, without case: part of an email, part of an account id, part of a note (or the label of an account of Mozilla's accounts), and with a whole number the account of that tokenserver uid (any of its rows, also replaced ones); with self-hosted accounts a whole email finds the account of any of its addresses. The list shows 50 accounts a page, newest first, with links to the newer and older ones that keep the search (`/?q=alice&page=2`). `/find?q=` goes straight to the account page of an exact email, account id or tokenserver uid.

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
| `ffs_cert_expiry_seconds{host}` | seconds until the certificate of a public URL expires, see [Public checks](#public-checks) |
| `ffs_alert_last_success_timestamp_seconds` | when the last alert email went out (Unix time; 0: none since the start), with `ADMIN_ALERT_EMAIL` |
| `ffs_alert_send_failing` | 1 when the last alert email could not be sent, with `ADMIN_ALERT_EMAIL` |
| `ffs_sync_near_max_users` | 1 when 90% of max users or more are taken |
| `ffs_statsd_silent` | 1 when the Sync server is up but sent no metrics for 30 minutes |
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

Next to the versions, the overview shows the schema of each database: the newest migration syncstorage-rs ran on the tokenserver and storage databases (with when it ran), and the `schema-patch-level` of each accounts database (`fxa`, `fxa_oauth`, `fxa_profile`, `pushbox`). A change is recorded as an event (kind `update`) and alerted, once: an upgrade that migrated, or a database restored from an older backup. The levels seen last are kept in the tokenserver database (`ffs_schema_levels`), so an upgrade of the whole stack, the admin UI with it, is noticed too.

## Who can sign up (self-hosted accounts)

`FXA_SIGNUPS` in `.env`, or the page:

| `FXA_SIGNUPS` | who can create an account |
|---|---|
| `open` (default) | anybody who can reach your accounts pages |
| `allowlist` | only the emails (`alice@example.com`) and domains (`@example.com`) of `FXA_SIGNUP_ALLOWLIST`, comma-separated |
| `closed` | nobody |

Existing accounts are never affected: disable them in the accounts list instead.

Under the policy, the emails of the allowlist are listed with when they were added and whether they signed up yet (`signed up on <date>`, matched without case as the policy does), each with a Remove button; the domains are listed apart. Removing an entry stops new sign-ups with it, an account already created stays. Saving the policy only removes entries the page showed: an invitation sent from another tab or by another admin after you loaded the page stays on the allowlist.

How it works:

- The accounts database refuses the account itself: `fxa-policy`, which runs before the accounts service on every start, installs a trigger on the accounts table (and the `ffs` database it reads the policy from). Nothing reaching the accounts service, whatever the path, can create an account the policy does not allow.
- So that people see why, the admin UI also answers sign-up requests itself: point `POST /v1/account/create` of your accounts API host name to `ADMIN_GATE_EXPORT_PORT` (`127.0.0.1:8091`). `config/nginx/fxa-example.conf` does it, `prepare_environment.sh` removes it when you don't enable the admin UI. Refused sign-ups then get "The request was blocked for security reasons" on the sign-up page, instead of "Unexpected error". Everything else goes to the accounts service directly.
- `.env` and the page both change the policy: the values in `.env` are applied when you change them there (on the next `docker compose up -d`), otherwise what you set on the page stays. `MAX_USERS` works differently, see [Max users](#max-users).

## Invitations and Connect a device

**Invite**, under Sign-ups, takes an email:

- with the policy `allowlist`, it adds the email to the allowlist (`invited <date>, not signed up yet` until they do);
- with `open` it leaves the allowlist alone; with `closed` too, and the page warns that they cannot sign up until you open sign-ups (the email says so);
- it sends them a plain text email through the stack's SMTP server (`FXA_SMTP_*`, sender `FXA_SMTP_SENDER`): the link to create their account (`FXA_CONTENT_URL/?email=<their email>`, which opens the sign-up page with that email), then the steps to point Firefox on a computer, Android and iOS to this server, and to pair a phone from a computer. No HTML, no images, no tracking: the links are the plain URLs of your server. Without an SMTP server the entry is still added and the page says the email was not sent.

At most 20 invitations an hour go out, whoever sends them, so that a stolen session cannot make your SMTP server a spammer. Each one is in the event log.

**Connect a device** (in the menu) shows the same steps, built from `FXA_CONTENT_URL`, the Sync node and `FXA_PAIRING_URL`, exactly as in [FXA.md](FXA.md#setup): on a computer `identity.fxaccounts.autoconfig.uri` in `about:config`; on Android the debug menu (tap the Firefox logo 5 times in About Firefox), then `Custom Mozilla account server` and `Custom Sync server` (`<node>/1.0/sync/1.5`); on iOS the version number 5 times, then `Custom Account Content Server URI`; a phone can also pair with the QR code of a computer already signed in, through your pairing server or Mozilla's. With Mozilla's accounts the page shows the steps of the [README](README.md#firefox-setup) instead: `identity.sync.tokenserver.uri`, and the custom Sync server of the phones.

## Disabling an account

Disable (on the accounts list or the account page, then on the confirm page) signs the account out of every device, refuses new sign-ins and revokes its OAuth tokens (in the accounts database and in Redis), so the sync server refuses the account's access tokens from then on. Firefox can still sync with what it already has for up to about an hour: the sync server remembers a verified access token for 5 minutes, and a Sync token it handed out stays valid for up to 1 hour. Enable gives the account back, with its data, after a new sign-in.

Signing out goes through Mozilla's own procedure (`revokeAccountTokens_1`): sessions, key fetch, account reset, password change and password reset tokens, unconfirmed sign-ins, unblock codes and devices, then the OAuth tokens and codes. `fxa-policy` checks at every start that the Mozilla procedures it calls exist (`revokeAccountTokens_1`, `deleteTotpToken_4`, `deleteRecoveryKey_2`, `verifyEmail_9`, `deleteAccount_24`, `prune_10`). If one is missing (a newer accounts release renamed it, or the policy user of your own server has no `EXECUTE` on `fxa.*`), it logs a warning with its name and the accounts keep working, but what needs it (disabling an account and signing out everywhere, turning off two-step authentication, removing a recovery key, confirming an email, deleting accounts, pruning) answers with an error: update the admin UI image, or grant `EXECUTE` (see [DATABASES.md](DATABASES.md)).

`FXA_ACCESS_TOKEN_LIFETIME` (`60 minutes` by default, any duration like `2 hours`) is how long the access tokens of Firefox live. Revoking makes the lifetime irrelevant for disabled accounts; a short one is a backstop in case revoking fails (the page tells you), at the cost of Firefox asking for a new token every hour, nothing a small server notices. Mozilla's default is `365 minutes`. Keep the lifetime as is if you turn on JWT access tokens (`JWT_ACCESS_TOKENS_ENABLED_CLIENT_IDS`, off by default): those living 6 hours or less are checked by their signature only and cannot be revoked.

Mozilla's own admin panel (not part of this stack) disables accounts the same way, without revoking the tokens.

## Signing out everywhere, a device or a session

Sign out everywhere, on the account page, does what disabling does to the devices, sessions and tokens, but leaves the account active: its owner can sign in again right away. Use it after a lost laptop or a leaked password (with a new password). Like after disabling, Firefox can sync for up to about an hour with the Sync token it has, and the sync server remembers a checked access token for 5 minutes.

Sign out next to a device or a session removes that device and the session or OAuth refresh token it signed in with, so it cannot get new access tokens. The access tokens it already has keep working until they expire (`FXA_ACCESS_TOKEN_LIFETIME`, 60 minutes by default), and the sync server may accept them for up to an hour more. To lock every device out at once, sign out everywhere.

The admin UI connects to the accounts database as `ffs_admin`, which can read a few columns of the accounts and nothing else of FxA: it never sees the token ids (a session token id signs in as its account), and it cannot change FxA's tables. Sessions, devices, emails, how accounts sign in and the schema levels are listed through views (`ffs.sessions`, `ffs.devices`, `ffs.emails`, `ffs.account_security`, `ffs.schema_levels`), and disabling, enabling, signing out, turning off two-step authentication, removing a recovery key, confirming an email, deleting accounts and pruning run as procedures that `fxa-policy` installs (`ffs.disable_account`, `ffs.enable_account`, `ffs.sign_out_all`, `ffs.sign_out_device`, `ffs.sign_out_session`, `ffs.remove_totp`, `ffs.remove_recovery_key`, `ffs.confirm_email`, `ffs.delete_account`, `ffs.delete_unconfirmed`, `ffs.prune`), with the privileges of the policy user.

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

What runs by itself, on the Activity page (Maintenance: last run and what it did) and in the event log (kind `maintenance`), once a day, kept across restarts (`ffs_jobs` in the tokenserver database). A job that failed runs again an hour later:

- **Pruning the accounts database**, with self-hosted accounts: Mozilla's `prune_10` with Mozilla's defaults (unblock and sign-in codes after 30 days, reset and password change tokens and sessions without a device after 4 weeks; the session of a Firefox has its device and is never pruned), the same session rule once more for those `prune_10` stops at, expired OAuth codes (15 minutes), and the security events of the account settings after `ADMIN_RETENTION_DAYS`, which Mozilla's procedure never prunes. `ffs.prune` takes the database's clock, whatever time it is given, and keeps the security events of the last day at least. "Prune the accounts database now" on the Activity page runs it at once. The overview says when it last ran, next to the schema levels.
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
| `.env` | the stack's directory | every password and secret (`SYNC_MASTER_SECRET`, the accounts' keys...). **Critical**: without it nothing restored works as before |
| the `fxa-keys` volume | self-hosted accounts | the keys the accounts service signs with. **Critical**: new keys sign every Firefox out |
| the accounts databases | `fxa`, `fxa_oauth`, `fxa_profile`, `pushbox`, `ffs` | the accounts, their devices, the sign-up policy. **Critical**: lost, everybody creates a new account |
| the tokenserver database | `tokenserver` (or the PostgreSQL database) | which account syncs where, max users, notes, the event log. **Important**: without it every account starts over with empty storage, and Firefox uploads again |
| the storage database | `syncstorage` (or the PostgreSQL database) | the Sync data, encrypted by Firefox. **Rebuildable**: each Firefox uploads what it has |

`.env` and `fxa-keys` change rarely: copy them off the host once, and again after a change. The databases change every minute: that is what the backup service is for.

### The backup service

Optional: add `backup` to `COMPOSE_PROFILES` in `.env` (`COMPOSE_PROFILES=admin,backup`), then `docker compose up -d`. With Quadlets the units are installed already, off: `systemctl --user enable --now firefox-sync-backup.timer`.

Every night at `BACKUP_TIME` (`03:00`, UTC) it dumps each database, with `mariadb-dump --single-transaction --routines --triggers` (MariaDB), `pg_dump` (PostgreSQL), and for the accounts `mysqldump` (or `mariadb-dump` with `FXA_DB=mariadb`) with the events too and without the trigger of the sign-up policy (`fxa-policy` installs it again at every start, before the accounts service: a copy restored elsewhere does not put it on the real `fxa.accounts`), into `<scope>/<UTC time>/<database>.sql.gz` of the `backups` volume (`<project>_backups`, e.g. `firefox-sync_backups`; `firefox-sync-backups` with Quadlets), `sync/` and `accounts/`. Each file passes `gzip -t` or the run fails; the files are readable by root only (0600). The newest `BACKUP_KEEP` runs (7) stay, older ones go; a failed run leaves nothing and keeps the older copies. It runs in the images of the databases, already on the host (`mariadb:lts`, `postgres:18`, `mysql:8.4`, `mariadb:11.8`), as the stack's users: the tokenserver and storage users, and `FXA_MYSQL_USER` for the accounts. With compose, a backup container that starts after `BACKUP_TIME` and did not run that day runs at once (the first start); with Quadlets the timer catches up after a night the host was off.

One now: `docker compose exec backup sh /ffs-backup/backup.sh now` (and `backup-fxa` for the accounts); with Quadlets `systemctl --user start firefox-sync-backup.service`, which runs that of the accounts first.

Each run is a row of `ffs_backups` in the tokenserver database (when it started and finished, whether it worked, its size, where, the error), written as the tokenserver user. The accounts' run is recorded by the Sync backup service (its image has no client for PostgreSQL): within a minute with compose, right after it with Quadlets. The admin UI reads that table, it never sees the volume:

- the Health section of the overview: "Last backup of the Sync databases: 2026-10-13 03:00, 1.2 MB, ok", or failed with the error and the last good one;
- [Needs attention](#needs-attention), an event of kind `backup` and an alert when a run fails or the last good one is older than 36 hours, once, and when they work again;
- Prometheus: `ffs_backup_age_seconds{scope}` and `ffs_backup_last_ok{scope}`.

The rows are kept for `ADMIN_AUDIT_RETENTION_DAYS`.

### Copy them off the host

The volume is on the same disk as the databases: a dead disk takes both. Copy it elsewhere, e.g. every morning from cron:

```bash
# docker compose (the volume is named after the directory of the stack)
docker run --rm -v firefox-sync_backups:/backups:ro -v "$PWD":/out busybox tar -C /backups -czf /out/ffs-backups.tar.gz sync accounts
# Podman (Quadlets)
podman volume export firefox-sync-backups > ffs-backups.tar
# and once, after each change: .env and the accounts' keys
docker run --rm -v firefox-sync_fxa-keys:/keys:ro -v "$PWD":/out busybox tar -C /keys -czf /out/fxa-keys.tar.gz .
```

then `scp` or `rsync` them to another machine. The dumps hold what the databases hold (emails, the event log, the accounts' password checks): keep the copies as private as `.env`, encrypted if they leave your own machines.

### Your own database servers

The backup service is for the database containers of the stack: on [your own server](DATABASES.md) use its own backups (the accounts' user of the stack cannot read `ffs` there). To have the admin UI watch them, have your backup job record each run in the tokenserver database, as the tokenserver user. The admin UI creates the table when it starts:

```sql
-- MariaDB and MySQL
CREATE TABLE IF NOT EXISTS ffs_backups (id BIGINT AUTO_INCREMENT PRIMARY KEY, scope VARCHAR(32) NOT NULL, started BIGINT NOT NULL,
  finished BIGINT NOT NULL, ok SMALLINT NOT NULL, bytes BIGINT NOT NULL, error VARCHAR(512) NOT NULL DEFAULT '', location VARCHAR(255) NOT NULL DEFAULT '',
  KEY ffs_backups_started (started));
-- PostgreSQL: the same columns, with id BIGSERIAL PRIMARY KEY and without the KEY line
```

`scope` is `sync` or `accounts`, the times are milliseconds since 1970, `ok` is 1 or 0 (with the reason in `error`), `bytes` the size. At the end of your job, e.g.:

```bash
mariadb -h db.example.com -u tokenserver -p"$TOKENSERVER_PASSWORD" tokenserver -e \
  "INSERT INTO ffs_backups (scope, started, finished, ok, bytes, location) VALUES ('sync', ${START}000, $(date +%s)000, 1, ${BYTES}, 'backup-host:/srv/ffs')"
```

### Restoring

On the same host or a new one, with the `.env` of the stack (and the `fxa-keys` volume put back, with `tar -x` into it):

1. Stop the stack, `docker compose down` (not `-v`). On a new host, or to start from empty databases, remove their volumes, then start the databases alone: `docker compose up -d tokenserver_db syncstorage_db fxa-db` (`postgres_db` with PostgreSQL).
2. Pick a run: `docker compose run --rm --no-deps --entrypoint ls backup /backups/sync /backups/accounts`.
3. The accounts, as the user that made the dumps (`FXA_MYSQL_USER`, root in the stack): the views and procedures of `ffs` carry it as their `DEFINER`, which only that user (or one with `SET_USER_ID`) can restore. `ffs` last, its views read the others; at the next start `fxa-policy` installs the trigger of the sign-up policy again, and the admin UI's user and its grants, before the accounts service starts. With `FXA_DB=mariadb`, `mariadb` instead of `mysql`:

    ```bash
    docker compose run --rm --no-deps --entrypoint sh backup-fxa -c '
      run=/backups/accounts/20261013T030000Z
      for db in fxa fxa_oauth fxa_profile pushbox ffs; do
        mysql -h "$FXA_DB_HOST" -u"$FXA_DB_USER" -p"$FXA_DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $db" &&
        gunzip -c $run/$db.sql.gz | mysql -h "$FXA_DB_HOST" -u"$FXA_DB_USER" -p"$FXA_DB_PASSWORD" $db || exit 1
      done'
    ```

4. The tokenserver, as the tokenserver user (it is the `DEFINER` of the `MAX_USERS` trigger and procedure):

    ```bash
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      gunzip -c /backups/sync/20261013T030000Z/$TOKENSERVER_DB_NAME.sql.gz |
        mariadb -h "$TOKENSERVER_DB_HOST" -u"$TOKENSERVER_DB_USER" -p"$TOKENSERVER_DB_PASSWORD" "$TOKENSERVER_DB_NAME"'
    # PostgreSQL (tokenserver and storage, one database): into the empty database
    docker compose run --rm --no-deps --entrypoint sh backup -c '
      gunzip -c /backups/sync/20261013T030000Z/$TOKENSERVER_DB_NAME.sql.gz |
        PGPASSWORD="$TOKENSERVER_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$TOKENSERVER_DB_USER" -d "$TOKENSERVER_DB_NAME" -v ON_ERROR_STOP=1'
    ```

5. The storage: prefer to leave it empty. A copy of last night is older than what the browsers have: Firefox gets items back that were changed or deleted since. With the storage empty (a new `syncstorage-db` volume, or [Reset the Sync data](#sync-data-of-an-account) of each account after the restore) each Firefox finds the server empty and uploads what it has. Restore it only when no device has the data any more, as above with `$STORAGE_DB_NAME`, `$STORAGE_DB_USER` and `$STORAGE_DB_PASSWORD`.
6. `docker compose up -d`. The migrations bring an older schema up to date; the overview records the change of the schema levels (an event of kind `update`).

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
run=20261013T030000Z
dump() { podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts gunzip -c "/backups/$1"; }
for db in fxa fxa_oauth fxa_profile pushbox ffs; do   # MariaDB accounts: mariadb and $MARIADB_ROOT_PASSWORD
  podman exec firefox-sync-fxa-db sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e 'CREATE DATABASE IF NOT EXISTS $db'"
  dump accounts/$run/$db.sql.gz | podman exec -i firefox-sync-fxa-db sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $db"
done
dump sync/$run/tokenserver.sql.gz | podman exec -i firefox-sync-tokenserver-db sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
```

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

The two counts match (or the restored one is a bit lower: accounts created since the night). The tokenserver user cannot create databases: for the Sync databases `gzip -t` is checked at every run; the full test is a restore on another machine, with a copy of `.env`.

## Notes

Each account has a note, up to 500 characters on one line: who it is, why it was disabled. Edit it on the account page; the accounts list shows it under the email, or next to the account id with Mozilla's accounts, where it is the only way to tell whose an account is. The reason given when disabling an account is added to its note. Notes are kept in the tokenserver database (`ffs_account_notes`), with who changed them last, and every change is in the event log. Like the event log they are personal data: deleting an account for good removes its note (from its page, by the purge, or with the old unconfirmed accounts).

## Rate limits and the client IP address

The accounts service limits sign-in attempts per client IP address, which it takes from `X-Forwarded-For` at a fixed position from the end: `FXA_CLIENT_ADDRESS_DEPTH`, 2 by default for one reverse proxy in front of the stack. Mozilla's default (3, for their load balancers) let any client pick its IP address by sending its own `X-Forwarded-For`, and get around the limits. With another proxy in front of yours (a CDN, a load balancer), add 1 for each.

## Tests

[`tests/e2e-fxa.sh`](/tests/e2e-fxa.sh) runs [`tests/test_fxa_admin.py`](/tests/test_fxa_admin.py) against the full stack: the SMTP health row and a test email in the mail catcher, the public URLs through the HTTPS proxy with their certificates and the sign-up gate (the probe creates no account with open sign-ups), the schema levels, an invitation (the email with this server's values, invited then signed up, removed) and in open and closed mode, the Connect a device page; refused sign-ups through the gate and directly to the accounts service, the allowlist, closing and reopening sign-ups, the accounts list, disabling an account, max users, what an account stores, the metrics and the event log, health and database sizes, the badges, lifting a rate-limit block and the attempts close to one, signing out a session, a device of a session and a device of a refresh token, the alert emails (in the mail catcher), Prometheus, the password and form checks, and the `X-Forwarded-For` spoofing; the confirm pages, signing out everywhere (a new sign-in works at once), that disabling also ends a password reset started before, the audit trail naming the account and the admin, and that `ffs_admin` cannot delete FxA's tokens itself; two-step authentication turned on through the accounts API (badge, backup codes) and off from the admin UI (sign-in without the authenticator, the owner's notice in the mail catcher), a recovery key removed, secondary emails listed, an email confirmed from the admin UI then a Sync token, unconfirmed sign-ins and the last use from Redis, a member blocked by the rate limits (one alert, none for an unknown email, lifted from the account page), notes and the disable reason; a Sync client after its data was reset (a working token on empty storage, a new row once its slot is freed), deleting an account (refused while it is enabled, by the procedure itself, and with a wrong email typed; then gone from the accounts service, the list, max users, the tokenserver, the storage and the allowlist), an account its owner deleted showing as an orphan and purged, pruning (an old unblock code and an old session without a device go, an old session with a device stays) and deleting old unconfirmed accounts (a fresh one stays), Needs attention with a blocked member and an inactive device (its badge on the account page), the lists of a badge alone, the search by part of an email and by account id, the accounts list newest first.

`tests/e2e-fxa.sh` also runs the backups of the accounts and of Sync (five dumps passing `gzip -t`, both runs in `ffs_backups` and in Prometheus), restores the dump of `fxa` into a scratch database with every account and procedure, then drops it, and checks that `ffs_admin` reads the views but no secret column (`sharedSecret`, `codeHash`, `recoveryData`, `phoneNumber`, `emailCode`), with the accounts on MySQL, MariaDB and your own server.

A real Firefox follows the link of an invitation (the sign-up page with the email), checks the error shown for a refused sign-up, that the admin UI lists its two devices and its bookmarks, fits a 360 pixel wide screen, and disables the account through the confirm page with the CSP enforced ([`tests/test_fxa_browser.py`](/tests/test_fxa_browser.py)).

[`tests/e2e.sh`](/tests/e2e.sh) and [`tests/podman.sh`](/tests/podman.sh) check max users with `MAX_USERS=N` (set again on every start, read-only page) and `MAX_USERS=initial:N` (set on the page, kept across restarts), that the UI and the gate start with compose and Quadlets and reach every component (Prometheus `ffs_up`), the container healthcheck, signing in over `http://localhost` with the default cookie, that the Sync server sends its metrics (and is restarted with a new admin UI container), the pruning of old metrics and events (the audit trail kept longer), the event filters and pages, a label on an account of Mozilla's accounts, the tokenserver rows after a key change and the search by tokenserver uid, resetting the Sync data (one collection, all of it, freeing the slot) and syncing again, the storage report and a purge of expired items and replaced keys that leaves the live data, deleting the Sync data of an account id, the schema levels, the setup checks (an account of another email domain is a warning), the accounts per node, the Connect a device page, no SMTP row without `FXA_SMTP_HOST` and no public checks with `ADMIN_PUBLIC_CHECK=false`, a Sync server going down and back up, that the logs have no background errors, and with `COMPOSE_PROFILES=backup` and `BACKUP_KEEP=1` two backup runs (recorded, one copy kept, the dumps passing `gzip -t`, 0600), a failed run (recorded, its event and alert, then "works again"), the backup line on the overview and `ffs_backup_age_seconds`, the line of 90% of max users (and its gauge and event), the search by tokenserver uid; with `EXTERNAL_DB=1` the INSERT of your own backups.

`tests/e2e.sh` also signs in through [Dex](https://dexidp.io) with OpenID Connect and with a trusted header ([`tests/test_admin_auth.py`](/tests/test_admin_auth.py)): an allowed user or group gets in, anybody else, a replayed callback, a tampered state or code are refused, a header that changes or disappears ends the session, forms need the session token, and the event log says who signed in and how.

`tests/podman.sh` checks the backup timer (installed, off) and a backup by hand with the Quadlets, with the accounts too.

The program itself has unit tests (`cd admin && go test ./...`): the age and failure of the backups and their alerts, each line of Needs attention, the thresholds alerting once per state, the paging and the search.
