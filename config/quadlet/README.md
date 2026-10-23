# Podman Quadlet files

The units that run firefox-sync with rootless Podman and systemd. How to install and run them: [docs/install/podman.md](../../docs/install/podman.md).

## Files in this directory

Network and volumes:

- `firefox-sync-network.network`: the containers' network
- `firefox-sync-syncstorage-db.volume`, `firefox-sync-tokenserver-db.volume`: the volumes of the storage and tokenserver databases

Containers:

- `firefox-sync-syncstorage-db.container`, `firefox-sync-tokenserver-db.container`: the storage and tokenserver databases, MariaDB
- `firefox-sync-syncstorage-migrate.container`: the database migrations, without exposing the service (runs once)
- `firefox-sync-tokenserver-db-init.container`: the database initialization and `SYNC_MAX_USERS` (runs once, after the migrations)
- `firefox-sync-syncstorage.container`: the Sync server, which starts only after the init succeeded
- `firefox-sync-backup.container`, `firefox-sync-backups.volume` and `firefox-sync-backup.timer`: the nightly backups of the databases. The timer is a plain systemd unit, installed in `~/.config/systemd/user` and off until you turn it on ([Backups](../../docs/backups.md#the-backup-service))

Subdirectories, installed only for the choices of `prepare_environment.sh`:

- `sync-mysql/`: with `SYNC_DB=mysql`, these replace the two database units and their volumes with MySQL ones (`firefox-sync-*-db-mysql`)
- `sync-postgres/`: with the Sync server on PostgreSQL (`SYNC_IMAGE=syncstorage-rs-postgres`), these replace the units of the Sync server, its migrations, its init container and the backups, and add `firefox-sync-postgres-db.container` and its volume (one database instead of the two MariaDB units, which are not installed) and `firefox-sync-sync-role-init.container` (the Sync server's own role, before the migrations). The admin UI's unit is rendered with the Sync database of PostgreSQL, as in `docker-compose.sync-postgres.yml`
- `admin/firefox-sync-admin.container`: the optional [admin UI](../../docs/admin/README.md)
- `fxa/`: the [self-hosted accounts](../../docs/accounts.md). `firefox-sync-fxa-policy.container` installs the sign-up policy before the accounts start, and `firefox-sync-backup-fxa.container` backs up their databases. `fxa/admin/` is the admin UI's unit with the accounts, where it also manages them and is the sign-up gate. With `FXA_DB=mariadb`, the files of `fxa/mariadb/` replace `firefox-sync-fxa-db.container` and its volume

With your own database server (`SYNC_DB_CONTAINERS=0`, or `FXA_DB_CONTAINERS=0` for the accounts), the database units are not installed, and the other units no longer depend on them: see [Your own database server](../../docs/databases.md#with-quadlets).

## The setup script

`prepare_environment.sh`, from the root of the repository, with Quadlets as its deployment method:

- copies these files to `~/.config/containers/systemd/` (or `QUADLET_DIR`), and the timer to `~/.config/systemd/user/`;
- replaces their `%VARIABLE%` placeholders with the values of your `.env`;
- reloads systemd.

It is meant for the first install: run again, it writes a new `.env` with new secrets. To change a setting later, see [Change a setting](../../docs/install/podman.md#change-a-setting).
