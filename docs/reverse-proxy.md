# Reverse proxy

The stack serves plain HTTP on ports of the host: your reverse proxy adds HTTPS and the public host names. This page says what to proxy where, and the few rules the proxy must follow. On Kubernetes, see [Kubernetes](#kubernetes).

The examples are nginx configs. `prepare_environment.sh` writes them with your values: `config/nginx/syncstorage-rs.conf` from [syncstorage-rs-example.conf](/config/nginx/syncstorage-rs-example.conf) and, with self-hosted accounts, `config/nginx/fxa.conf` from [fxa-example.conf](/config/nginx/fxa-example.conf). They are the reference for the rules below.

## Host names and ports

| Host name | Setting | Proxy to |
|---|---|---|
| `sync.example.com` | `SYNC_PUBLIC_URL` | `SYNC_EXPORT_PORT` (`5000`) |

The admin UI is better reached through an SSH tunnel than published: see [Reach it](admin/README.md#reach-it).

With [self-hosted accounts](accounts.md), three more, and two optional:

| Host name | Setting | Proxy to |
|---|---|---|
| `accounts.example.com` | `FXA_CONTENT_URL` | `127.0.0.1:3030` |
| `api.example.com` | `FXA_AUTH_URL` | `127.0.0.1:9000`, and with the admin UI `POST /v1/account/create` to `127.0.0.1:8091`: see [Sign-up gate](#sign-up-gate) |
| `profile.example.com` | `FXA_PROFILE_URL` | `127.0.0.1:1111`, and `/img/` to `127.0.0.1:1112/` |
| `admin.example.com` (optional) | `ADMIN_OIDC_REDIRECT_URL` | `127.0.0.1:8090`, to [sign in to the admin UI with these accounts](admin/signing-in.md#self-hosted-accounts) |
| `pairing.example.com` (optional) | `FXA_PAIRING_URL` | `127.0.0.1:8058`, a websocket: see [Pairing](#pairing) |

The ports of the accounts are those of `FXA_*_EXPORT_PORT` and `ADMIN_GATE_EXPORT_PORT` in `.env`: see [Settings](reference/settings.md#accounts).

`SYNC_EXPORT_PORT` takes the form of a compose port. A bare port, such as `5000`, listens on every address of the host. `127.0.0.1:5000` keeps it to a proxy on the same host. The others listen on `127.0.0.1` only by default.

## Request size

Firefox sends batches up to the Sync server's limit, about 2.5 MB a request. nginx refuses more than 1 MB by default, so raise its limit on the Sync server's host:

```nginx
client_max_body_size 10m;
```

Without it, large batches fail with `413 Request Entity Too Large`, which shows in `about:sync-log`. Other proxies and Ingress controllers have their own limit of the request body, if any.

## Sign-up gate

With self-hosted accounts and the admin UI, send `POST /v1/account/create` of the accounts API host name to the admin UI's gate, `ADMIN_GATE_EXPORT_PORT` (`127.0.0.1:8091`). Everything else on that host goes to the accounts service.

```nginx
location = /v1/account/create {
  proxy_pass http://127.0.0.1:8091;
  proxy_set_header Host $http_host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

`prepare_environment.sh` removes this block when you don't enable the admin UI. Without the gate the accounts database still refuses the sign-ups the policy does not allow. What the gate adds: see [Who can sign up](accounts.md#who-can-sign-up).

## Pairing

With self-hosted accounts, a phone pairs with a computer through Mozilla's pairing server, unless you run your own ([Pair a phone](firefox.md#pair-a-phone)). To run your own:

1. In `.env`, add `pairing` to `COMPOSE_PROFILES`, and set `FXA_PAIRING_URL=wss://pairing.example.com`.
1. Proxy that host name to `FXA_PAIRING_EXPORT_PORT` (`127.0.0.1:8058`), as a websocket:

   ```nginx
   location / {
     proxy_pass http://127.0.0.1:8058;
     proxy_http_version 1.1;
     proxy_set_header Upgrade $http_upgrade;
     proxy_set_header Connection "upgrade";
     proxy_read_timeout 600;
     proxy_set_header Host $http_host;
     proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   }
   ```

1. Start it: `docker compose up -d`.

The full server block is commented out at the end of [fxa-example.conf](/config/nginx/fxa-example.conf).

## Client IP address

The accounts service limits sign-in attempts per client IP address. It takes the address from `X-Forwarded-For`, at a fixed position from the end: `FXA_CLIENT_ADDRESS_DEPTH` (`2`), for one reverse proxy in front of the stack.

- Your proxy must set `X-Forwarded-For`, as the examples do: `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`.
- With another proxy in front of yours, such as a CDN or a load balancer, add 1 to `FXA_CLIENT_ADDRESS_DEPTH` for each.

<details><summary>Why not Mozilla's default</summary>

Mozilla's default depth is 3, for their load balancers. Behind a single proxy, it lets any client pick its IP address by sending its own `X-Forwarded-For`, and so get around the limits.

</details>

## The admin UI

The admin UI listens on `ADMIN_EXPORT_PORT` (`127.0.0.1:8090`), and is best reached without publishing it: see [Reach it](admin/README.md#reach-it).

To publish it behind nginx instead, on a host name of its own:

- restrict it to your own addresses;
- keep the `Host` header: the forms check that they are posted from the same site.

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

Sessions, plain HTTP and signing in: see [Admin UI](admin/README.md#set-up) and [Signing in](admin/signing-in.md). A sign-in proxy in front of it: see [Trusted header](admin/signing-in.md#trusted-header).

## Kubernetes

With the Helm chart, the chart's Ingress publishes the Sync server, and the admin UI on a host of its own: see [Ingress](install/helm.md#ingress) and [Admin UI](install/helm.md#admin-ui). The rules of this page still apply, in the Ingress controller's terms: [Request size](#request-size) is the one that matters for the Sync server.

With your own reverse proxy in front of the cluster, proxy the Sync server's host name to the Service `<release>-firefox-sync-syncstorage`, port 8000.
