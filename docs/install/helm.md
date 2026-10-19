# Install with Helm

This page installs the Sync server on Kubernetes with the Helm chart [charts/firefox-sync](/charts/firefox-sync). The chart runs the same images as docker compose, with the settings of `.env` as values. Read [What you need](../README.md#what-you-need) first.

The chart runs syncstorage-rs with its tokenserver, its migrations and the init container of `maxUsers`, and the databases: MariaDB, MySQL or PostgreSQL, or [your own server](../databases.md#with-helm). The admin UI and the nightly backups are optional.

## Requirements

- Kubernetes 1.27 or later, and Helm 3.
- A default StorageClass, or `database.persistence.storageClass` and `backup.persistence.storageClass`. The chart needs one volume per database server and one for the backups.
- A host name with HTTPS that reaches the Sync server: an Ingress controller ([Ingress](#ingress)), or your own reverse proxy in front of the Service `<release>-firefox-sync-syncstorage`, port 8000.
- A namespace at the [PodSecurity](https://kubernetes.io/docs/concepts/security/pod-security-standards/) level `baseline`, or `privileged` (the default):

  ```bash
  kubectl label ns <namespace> pod-security.kubernetes.io/enforce=baseline
  ```

- In a namespace with a ResourceQuota on `cpu` or `memory`: requests and limits for every container ([Resources](#resources)), or a LimitRange with defaults.

<details><summary>Why not <code>restricted</code></summary>

Only the admin UI's pod meets `restricted`. The database servers start as root and drop to their user (the images' entrypoints, with `gosu`). The backups run as root, because the dumps are root's. So do the Sync server's init containers `sync-role` and `db-init`: their images have no other user.

Every pod has `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false` and no service account token. The tests install the chart into a namespace that enforces `baseline`.

</details>

## Install

1. Write a `my-values.yaml`. A minimal one, with ingress-nginx and cert-manager:

   ```yaml
   syncDomain: https://sync.example.com
   # how many accounts can use the server, see docs/limits.md
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

   `maxUsers` takes the forms of [`SYNC_MAX_USERS`](../limits.md#sync_max_users). The body size is explained in [Ingress](#ingress).

1. Install the chart:

   ```bash
   helm install ffs oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 \
     -f my-values.yaml --wait --timeout 10m
   ```

   `ffs` is the release name: the objects are called `ffs-firefox-sync-*`, as in the commands of this page. For a namespace of its own, add `-n <namespace> --create-namespace`, and `-n <namespace>` to every `kubectl` command.

1. Read what `helm install` prints next (the NOTES). The first start takes a minute or two: the databases are created, then the migrations and the init container run before the Sync server.

1. Check the pods and the init container:

   ```bash
   kubectl get pods -l app.kubernetes.io/instance=ffs
   kubectl logs deploy/ffs-firefox-sync-syncstorage -c db-init   # Current users: N
   ```

1. [Set up Firefox](../firefox.md), with `https://sync.example.com`.

With PostgreSQL, pin its major in your values after the first install: see [Upgrading](../upgrading.md#postgresql). `helm upgrade` refuses a database image of another major than the one running: see [Database majors](../upgrading.md#database-majors).

Every value is in [values.yaml](/charts/firefox-sync/values.yaml), with what it does. Each setting of `.env` and its value are in [Settings](../reference/settings.md), in the Helm column. The chart's schema refuses a key it does not know, so a typo such as `admin.enable` fails the install instead of doing nothing. The maps of Kubernetes (annotations, resources, the scheduling) are not checked.

### Resources

None by default, as compose sets none. What the database servers need grows with the data and the accounts, and a memory limit set too low gets a server killed in the middle of a write. Set them where your cluster wants them, for example with a ResourceQuota or nodes shared with others.

| Values | Containers |
|---|---|
| `syncstorage.resources` | the Sync server |
| `syncstorage.initResources` | its init containers `wait-db`, `sync-role` (PostgreSQL), `migrate` and `db-init`, one at a time before it. `migrate` runs a whole Sync server: give it about what `syncstorage.resources` has |
| `database.resources` | each bundled database server: two with MariaDB and MySQL, one with PostgreSQL |
| `admin.resources` | the admin UI and its init container `wait-sync` |
| `backup.resources` | the backup, and the one-shot Job that binds its PVC at install |

For a few accounts, for example:

```yaml
syncstorage:
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {memory: 512Mi}
  initResources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {memory: 512Mi}
database:
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 1Gi}
```

### Scheduling and pulling

`nodeSelector`, `tolerations`, `affinity` (as in a pod spec) and `podAnnotations` apply to every pod of the chart: the Sync server, the admin UI, the database servers and the backups. The chart's own annotations, its checksums, stay.

`imagePullSecrets` (`[{name: my-registry}]`) applies to every pod too, for a registry that needs a login. That is a mirror of `ghcr.io/porelli/firefox-sync`, and of Docker Hub, whose official images the database servers and the backups run. The `database.image.*` values are fully qualified (`docker.io/library/...`) for the nodes whose runtime has another default registry.

### Database volumes

`database.persistence.size` and `.storageClass` are those of the database servers' StatefulSets (`volumeClaimTemplates`), which Kubernetes never changes: choose them before the first install. A `helm upgrade` with another value fails with `StatefulSet.apps ... is invalid: spec: Forbidden: updates to statefulset spec for fields other than ...`.

To grow a volume, keep the values as they were and resize its PVC, with a StorageClass that has `allowVolumeExpansion: true` ([volume expansion](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims)):

```bash
kubectl patch pvc data-ffs-firefox-sync-tokenserver-db-0 -p '{"spec": {"resources": {"requests": {"storage": "20Gi"}}}}'
```

The other PVCs are `data-ffs-firefox-sync-storage-db-0` (the storage) and `data-ffs-firefox-sync-postgres-0`. Some storage drivers grow a volume only when its pod restarts: `kubectl delete pod ffs-firefox-sync-storage-db-0`.

The backups' PVC (`backup.persistence.*`) is a plain one: the same `kubectl patch` grows it, and its storage class never changes either. Another StorageClass needs a backup and a restore into a new install: see [Restore on Kubernetes](../backups.md#restore-on-kubernetes).

## The Secret

On the first install, the chart generates the secrets of `.env` into the Secret `ffs-firefox-sync`. It reads them back on every `helm upgrade` (Helm's `lookup`), so they never change: `SYNC_MASTER_SECRET`, `METRICS_HASH_SECRET` (`.env`'s `SYNC_METRICS_HASH_SECRET`), `ADMIN_PASSWORD` (unless you set `admin.password`) and the database passwords. A key that a new chart version adds is generated at the upgrade.

The Secret has `helm.sh/resource-policy: keep`: `helm uninstall` leaves it, like the databases' volumes. A new install with the same release name then finds the passwords the databases were created with.

Keep a copy of it, with your values, off the cluster. The backups do not have it.

```bash
kubectl get secret ffs-firefox-sync -o json \
  | jq '{apiVersion, kind, type, data, metadata: (.metadata | {name, labels, annotations})}' > ffs-secret.json
```

The optional secrets of the admin UI come from the values alone: `smtp.password`, `admin.oidc.clientSecret`, `admin.metricsToken` and `admin.notify`. The chart writes them into the Secret on every install and upgrade (`FXA_SMTP_PASS`, `ADMIN_OIDC_CLIENT_SECRET`, `ADMIN_METRICS_TOKEN`, `ADMIN_NOTIFY`). An empty value turns that feature off, whatever was put into the Secret by hand.

### existingSecret

A Secret of your own, which the chart reads and never writes. It is required:

- with your own database server (`database.bundled: false`): the chart cannot generate passwords your server knows;
- when the chart is rendered without the cluster: `helm template`, or a GitOps tool that renders it (Argo CD...). `lookup` finds nothing there, so every render would generate new secrets. Every Firefox would be signed out, and the databases would refuse the new passwords.

Its keys:

| Key | Backend | What it is |
|---|---|---|
| `SYNC_MASTER_SECRET` | all | the Sync server's tokens (`.env`: `SYNC_MASTER_SECRET`) |
| `METRICS_HASH_SECRET` | all | the hash of the account ids in the metrics (`.env`: `SYNC_METRICS_HASH_SECRET`) |
| `ADMIN_DB_PASSWORD` | all, except MariaDB and MySQL on your own server without the admin UI and the backups | the admin UI's two database users ([The admin UI's own database](../reference/database-users.md#the-admin-uis-own-database)) |
| `TOKENSERVER_DB_PASSWORD`, `STORAGE_DB_PASSWORD` | `mariadb`, `mysql` | the tokenserver and storage users |
| `POSTGRES_PASSWORD` | `postgres` | the superuser of the bundled server; on your own server the owner, `database.external.postgresUser` |
| `POSTGRES_SYNC_PASSWORD` | `postgres`, bundled | the Sync server's own role `syncserver_app` (`database.postgresSyncUser`), no superuser |
| `ADMIN_PASSWORD` | optional | the admin UI's password. Missing or empty: no password form ([Signing in](../admin/signing-in.md)) |
| `FXA_SMTP_PASS`, `ADMIN_OIDC_CLIENT_SECRET`, `ADMIN_METRICS_TOKEN`, `ADMIN_NOTIFY` | optional | the admin UI's. Missing or empty: that feature is off |

With `existingSecret`, the chart does not read the values of those optional secrets (`smtp.password`, `admin.oidc.clientSecret`, `admin.metricsToken`, `admin.notify`), nor `admin.password`.

For MariaDB or MySQL, for example:

```bash
rnd() { LC_ALL=C tr -dc A-Za-z0-9 < /dev/urandom | head -c 32; }
kubectl create secret generic ffs-secrets \
  --from-literal=SYNC_MASTER_SECRET="$(rnd)" --from-literal=METRICS_HASH_SECRET="$(rnd)" \
  --from-literal=ADMIN_PASSWORD="$(rnd)" --from-literal=ADMIN_DB_PASSWORD="$(rnd)" \
  --from-literal=TOKENSERVER_DB_PASSWORD="$(rnd)" --from-literal=STORAGE_DB_PASSWORD="$(rnd)"
```

Then set `existingSecret: ffs-secrets` in your values. With PostgreSQL, use `POSTGRES_PASSWORD` and `POSTGRES_SYNC_PASSWORD` instead of the last two. With a GitOps tool, create the same keys from your secrets manager (Sealed Secrets, External Secrets...).

A key missing that a pod needs stops it in `CreateContainerConfigError` until the key is there; `kubectl describe pod` names it. A new chart version that needs a new key says so in its release notes.

## Your own database server

`database.bundled: false`, `database.external.*`, and an `existingSecret` with the passwords of the users you created: see [Databases](../databases.md#with-helm).

## Ingress

`ingress.enabled` publishes the Sync server at `/` of `ingress.host` (empty: the host of `syncDomain`), with the controller of `ingress.className`.

- TLS: `ingress.tls.enabled`, with `ingress.tls.secretName`. Empty, the controller's default certificate is used. cert-manager needs a `secretName` to write the certificate into.
- Body size: with ingress-nginx, raise `nginx.ingress.kubernetes.io/proxy-body-size`, `"10m"` in the example above. Why: [Request size](../reverse-proxy.md#request-size). Other controllers: their own limit of the request body, if they have one.

Without the Ingress, publish the Service `ffs-firefox-sync-syncstorage:8000` your own way, at `syncDomain`. The admin UI never shares this Ingress: see [Admin UI](#admin-ui).

## Admin UI

Turn it on in your values, then `helm upgrade`:

```yaml
admin:
  enabled: true
  alertEmail: you@example.com
smtp:
  host: smtp.example.com
  user: sync@example.com
  password: <the SMTP password>
  sender: sync@example.com
```

The values are the settings of `.env` under other names: `admin.alertEmail` is `ADMIN_ALERT_EMAIL`, `admin.oidc.*` is `ADMIN_OIDC_*`, `admin.notify` is `ADMIN_NOTIFY` (a list of URLs), and so on. Email alerts also need the SMTP server, the top-level `smtp.*` (`FXA_SMTP_*`), which the self-hosted accounts share. Each one is in [values.yaml](/charts/firefox-sync/values.yaml) and in the Helm column of [Settings](../reference/settings.md#admin-ui).

The chart tells the admin UI that it runs on Kubernetes (`ADMIN_DEPLOYMENT=kubernetes`). Its pages then give `kubectl` and `helm upgrade` commands and the names of the values, instead of `.env` and docker compose.

The admin UI is not published. Reach it with a port-forward, then open `http://localhost:8090`:

```bash
kubectl port-forward svc/ffs-firefox-sync-admin 8090:8080
kubectl get secret ffs-firefox-sync -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d   # the password
```

Or give it an Ingress of its own, on a host of its own: the chart refuses the Sync server's host. Put it behind your own sign-in, since the admin UI can delete accounts. For example only from your network, with OpenID Connect (`admin.oidc.*`, with `admin.oidc.redirectUrl: https://admin.example.com/auth/callback`) or with a forward-auth proxy (`admin.trustedHeader.*`): see [Signing in](../admin/signing-in.md).

```yaml
admin:
  enabled: true
  ingress:
    enabled: true
    className: nginx
    host: admin.example.com
    tls:
      enabled: true
      secretName: admin-example-com-tls
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
      nginx.ingress.kubernetes.io/whitelist-source-range: 192.0.2.0/24
```

Without `admin.ingress.tls.enabled` the NOTES warn: unless the controller adds TLS, the password and the session cookie cross the network in plain HTTP.

<!-- helm-fxa: accounts values go here -->

## Backups and upgrades

- Backups: `backup.enabled`, see [Backups on Kubernetes](../backups.md#kubernetes).
- Upgrades, and what `helm uninstall` keeps: see [Upgrading with Helm](../upgrading.md#helm).
- From docker compose to Kubernetes: see [Migrating](../migrating.md#from-docker-compose-to-kubernetes).

## Limits

- **One Sync server.** `syncstorage.replicas` stays 1: the migrations and the `maxUsers` init run in its init containers, and two at once is not tested.
- **Release names.** The names the admin UI builds from the release are never truncated: the Services, the StatefulSets, the Sync server's Deployment and the backup CronJob. A name over Kubernetes' limits is refused at render time, with the name that is too long. Only the one-shot Job that binds the backups' PVC has a shortened name of its own.

  With the default fullname `<release>-firefox-sync`, the release name is at most:

  | With | Longest name | Release name |
  |---|---|---|
  | the bundled MariaDB or MySQL | `<fullname>-tokenserver-db`, a StatefulSet (52) | 24 characters |
  | the bundled PostgreSQL | `<fullname>-postgres` | 30 characters |
  | the backups | `<fullname>-backup`, a CronJob (52) | 32 characters |

  The shortest of those that apply wins. A release name that contains `firefox-sync` is the fullname itself, and `fullnameOverride` sets it.
- **Probes.** The database servers have up to 30 minutes for their first start (a new database, a long recovery), and are restarted only after 5 minutes without an answer, so a server that recovers is not killed half-way. The Sync server is ready once its heartbeat answers, as with the healthcheck of compose.

## Troubleshooting

See [Troubleshooting: Kubernetes](../troubleshooting.md#kubernetes).
