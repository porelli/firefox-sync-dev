# firefox-sync

Self-hosted Firefox Sync: Mozilla's [syncstorage-rs](https://github.com/mozilla-services/syncstorage-rs) with its tokenserver, its databases (MariaDB, MySQL 8.4 or PostgreSQL, or your own server), and optionally an admin UI and nightly backups. Firefox signs in with Mozilla's accounts and stores its Sync data, encrypted by Firefox, on your cluster. The images are those of [porelli/firefox-sync](https://github.com/porelli/firefox-sync), which also runs with docker compose and Podman.

The full guide: [HELM.md](https://github.com/porelli/firefox-sync/blob/main/HELM.md).

## Install

Kubernetes 1.27 or later, Helm 3.

```bash
helm install ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 \
  -f my-values.yaml --wait --timeout 10m
```

```yaml
syncDomain: https://sync.example.com
maxUsers: "5"
ingress:
  enabled: true
  className: nginx
  tls:
    enabled: true
    secretName: sync-example-com-tls
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
```

Then set `identity.sync.tokenserver.uri` to `https://sync.example.com/1.0/sync/1.5` in Firefox ([Firefox setup](https://github.com/porelli/firefox-sync/blob/main/SYNC.md#firefox-setup)).

## Values

Every value is described in [values.yaml](https://github.com/porelli/firefox-sync/blob/main/charts/firefox-sync/values.yaml). The main ones:

| Value | Default | |
|---|---|---|
| `syncDomain` | required | the public URL of the Sync server |
| `maxUsers` | `"1"` | how many accounts can use it: `N`, `fixed:N`, `initial:N`, `unlimited` |
| `database.backend` | `mariadb` | `mariadb`, `mysql` or `postgres` |
| `database.bundled` | `true` | `false`: your own server, `database.external.*` and `existingSecret` |
| `existingSecret` | | a Secret of your own; required with your own server and with `helm template` or GitOps rendering |
| `ingress.*` | off | the Sync server's Ingress |
| `admin.enabled`, `admin.*` | off | the admin UI; `admin.ingress.*` for its own Ingress, behind your own sign-in |
| `backup.enabled`, `backup.*` | off | a CronJob dumping the databases into a PVC |

## Good to know

- The generated Secret (`<release>-firefox-sync`) is read back on upgrades and kept on `helm uninstall`, like the database volumes. Keep a copy off the cluster.
- One Sync server replica: the migrations run in its init containers.
- Release names: at most 24 characters with the bundled MariaDB or MySQL, 30 with PostgreSQL, 32 with the backups (or `fullnameOverride`): longer names are refused at render time.
- Not in the chart yet: self-hosted Mozilla accounts.
