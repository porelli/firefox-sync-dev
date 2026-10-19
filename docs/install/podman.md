# Install with Podman

This page installs the Sync server with rootless Podman, in one of two ways: Quadlets, which run the stack as systemd units of your user (recommended), or docker compose on the Podman socket. Read [What you need](../README.md#what-you-need) first.

## Requirements

- Podman 4.4 or later ([install](https://podman.io/docs/installation)), set up for rootless use ([Podman's rootless tutorial](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)).
- For docker compose on the Podman socket: `docker compose` v2. The Docker daemon is not needed.
- A host name with HTTPS, proxied to the port of the Sync server: see [Reverse proxy](../reverse-proxy.md).

The stack uses named volumes only, so rootless Podman handles their ownership, and SELinux labels stay on.

| | Quadlets | docker compose on the Podman socket |
|---|---|---|
| MariaDB, MySQL | yes | yes |
| PostgreSQL | no | yes |
| self-hosted accounts | yes | yes |

## Quadlets

Quadlets are unit files that Podman turns into systemd services: see [podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html).

1. Clone the repository and run the setup script:

   ```bash
   git clone https://github.com/porelli/firefox-sync.git
   cd firefox-sync
   ./prepare_environment.sh
   ```

   It detects Podman and asks for the deployment method: answer `1`, Quadlets (the default). Its other questions are those of [docker compose](compose.md#what-the-setup-script-asks). It writes `.env`, copies the units of [config/quadlet/](/config/quadlet) with your values into `~/.config/containers/systemd/` (the backup timer into `~/.config/systemd/user/`), and reloads systemd.

1. Start the Sync server:

   ```bash
   systemctl --user start firefox-sync-syncstorage.service
   ```

   Its dependencies start first: the databases, the migrations, the init container and, when you enabled it, the admin UI.

1. Let your units start at boot without a login:

   ```bash
   loginctl enable-linger $USER
   ```

   Quadlets are generated units: their `[Install]` section starts them at boot, and `systemctl enable` does not work on them.

1. [Set up Firefox](../firefox.md).

To install the units somewhere else than `~/.config/containers/systemd/`, set `QUADLET_DIR` when you run the script:

```bash
QUADLET_DIR=/path/to/units ./prepare_environment.sh
```

Other choices of the setup script, with Quadlets:

- MySQL instead of MariaDB: see [Databases](../databases.md#mysql-instead-of-mariadb).
- Your own database server: see [Databases](../databases.md#with-quadlets).
- The admin UI: see [Admin UI](../admin/README.md#set-up).
- The nightly backups: see [Backups](../backups.md#the-backup-service).

### Self-hosted accounts

If you chose to self-host Mozilla accounts, the script also installs their units, `firefox-sync-fxa-*`. Start them:

```bash
systemctl --user start firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
  firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service
```

Their database, the migrations and the auth server start as dependencies. The rest of the setup is in [Self-hosted accounts](../accounts.md#set-up).

### Check the units

Status and logs:

```bash
systemctl --user status firefox-sync-syncstorage.service
journalctl --user -u firefox-sync-syncstorage.service -f
journalctl --user -u 'firefox-sync-*' -f
```

Health: every unit that keeps running has the healthcheck of its compose service, with the same timings. `podman ps` shows `(healthy)` next to each. One at a time:

```bash
podman healthcheck run firefox-sync-syncstorage; echo $?   # 0: healthy
```

The one-shot units have no healthcheck: the migrations, the init container, `fxa-keys-owner`, `fxa-policy` and the backups. `systemctl --user status <unit>` says how they ended.

Restart and stop:

```bash
systemctl --user restart firefox-sync-syncstorage.service
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-syncstorage-db.service firefox-sync-tokenserver-db.service
```

A new admin UI container restarts the Sync server: see [Sync metrics](../admin/monitoring.md#sync-metrics).

<details><summary>Podman before 5: the units start before their database is healthy</summary>

Podman 4.9 (Ubuntu 24.04) orders the units on the start of their container, not on its health: `Notify=healthy` needs Podman 5. Where compose waits for a healthy database, the next unit retries on its own instead: the migrations of the Sync server for 2 minutes, those of the accounts for 5. `Restart=always` starts again what gave up.

</details>

### Change a setting

The installed units hold their own copy of the values: a change of `.env` alone does nothing. Don't run `prepare_environment.sh` again on a running install either: it writes a new `.env` from `.env-example`, with new passwords and secrets that the databases don't have.

1. Find the units that have the setting. Inside the units some settings have the containers' names, for example `MAX_USERS` for `SYNC_MAX_USERS`:

   ```bash
   grep -l 'MAX_USERS=' ~/.config/containers/systemd/firefox-sync-*.container
   ```

1. Change the value in their `Environment=` lines (a `%` is written `%%`), and in `.env` too, so that both agree.
1. Reload systemd:

   ```bash
   systemctl --user daemon-reload
   ```

1. Restart the init container and the Sync server. The migrations run again before the Sync server starts.

   ```bash
   systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-syncstorage.service
   ```

   With the admin UI, also restart `firefox-sync-admin.service` when `SYNC_MAX_USERS` changes between a plain number and `initial:N` ([Limits](../limits.md#switch-between-the-forms)).

Upgrading the images: see [Upgrading](../upgrading.md#quadlets).

## docker compose on the Podman socket

`docker compose` v2 can drive Podman through its Docker-compatible API, with the same compose files as Docker.

1. Run the setup script, and answer `2` to the deployment method:

   ```bash
   ./prepare_environment.sh
   ```

1. Start the Podman API socket of your user, and point `docker compose` to it:

   ```bash
   systemctl --user enable --now podman.socket
   export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock
   ```

1. Start the stack, with the file of your database backend:

   ```bash
   # MariaDB
   docker compose -f docker-compose.yml -f docker-compose.podman.yml up -d
   # MySQL
   docker compose -f docker-compose.yml -f docker-compose.podman.yml -f docker-compose.sync-mysql.yml up -d
   # PostgreSQL
   docker compose -f docker-compose.sync-postgres.yml up -d
   ```

   [docker-compose.podman.yml](/docker-compose.podman.yml) gives the healthchecks of the Sync server and the MariaDB or MySQL databases more time, for slower rootless starts.

Everything else works as in [docker compose](compose.md): logs with `docker compose logs -f`, `docker compose down` to stop.

## Why not podman-compose?

The stack starts in a precise order: the databases, then a one-shot container running the migrations, then the one-shot init that installs the limit of users, and only then the public Sync server, so that nobody can sign in before the limit exists.

podman-compose links containers with `podman create --requires`. Podman refuses to start a container whose required container has already exited ("generating dependency graph for container"), so the init and the Sync server never start. podman-compose also does not check that a one-shot container exited successfully. Use Quadlets or docker compose instead.

Something fails: see [Troubleshooting](../troubleshooting.md).
