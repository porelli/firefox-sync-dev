# Firefox Sync with Podman

This guide covers running Firefox Sync with Podman, including rootless configurations and systemd integration via Quadlets.

## Table of Contents

- [Why Podman?](#why-podman)
- [Rootless Podman Compatibility](#rootless-podman-compatibility)
- [Installation Methods](#installation-methods)
  - [Method 1: Using Quadlets (Recommended)](#method-1-using-quadlets)
  - [Method 2: Using docker compose with the Podman socket](#method-2-using-docker-compose-with-the-podman-socket)
  - [Why not podman-compose?](#why-not-podman-compose)
- [Troubleshooting](#troubleshooting)
- [Performance Considerations](#performance-considerations)

## Why Podman?

Podman is a daemonless container engine that offers several advantages:

- **Rootless by default**: Run containers without root privileges
- **Systemd integration**: Native integration with systemd via Quadlets
- **Docker-compatible**: Drop-in replacement for Docker in most cases
- **Security**: Better isolation and security model
- **No daemon**: Containers run as child processes

## Rootless Podman Compatibility

This project has been specifically optimized for rootless podman environments:

### Improvements Made

1. **Extended Wait Times**: The database initialization script waits up to 2 minutes (vs 50 seconds) for migrations to complete
2. **Proper Table Checking**: Verifies all required tables exist before initialization
3. **Better Error Handling**: Clear progress indicators and error messages
4. **Dynamic Configuration**: SYNC_MAX_USERS stored in database, updatable without rebuilding
5. **Podman-Specific Overrides**: Optional `docker-compose.podman.yml` with rootless optimizations

### Known Considerations

- **Slower Startup**: Rootless containers may start slower than rootful ones
- **Volume Permissions**: Only named volumes are used, rootless Podman handles their ownership
- **SELinux**: Labels stay enabled. Only named volumes are used, and Podman labels them automatically

## Installation Methods

### Prerequisites

1. Install Podman:
   ```bash
   # Fedora/RHEL/CentOS
   sudo dnf install podman

   # Ubuntu/Debian
   sudo apt install podman

   # Arch Linux
   sudo pacman -S podman
   ```

   Quadlets need Podman 4.4 or newer. For Method 2 you also need `docker compose` (v2), e.g.
   `docker-compose-v2` on Ubuntu/Debian or `docker-compose` on Fedora; the Docker daemon is not needed.

2. For rootless setup, configure subuid/subgid:
   ```bash
   # Check if already configured
   grep $USER /etc/subuid /etc/subgid
   
   # If not configured, add entries (requires root)
   sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
   ```

3. Run the environment preparation script:
   ```bash
   ./prepare_environment.sh
   ```

### Method 1: Using Quadlets

Quadlets provide native systemd integration for Podman. This is the **recommended method**.

#### What are Quadlets?

Quadlets are systemd unit files that Podman converts into container configurations. They provide:

- Native systemd integration
- Automatic dependency management
- Better logging via journald
- Easier service management
- Automatic updates support

#### Setup

1. Run the environment preparation script and choose Quadlets when prompted:
   ```bash
   ./prepare_environment.sh
   ```
   
   When asked about deployment method, select option 1 (Quadlets, the default).
   
   The script will automatically:
   - Create your `.env` file with configuration
   - Copy quadlet files to `~/.config/containers/systemd/`
   - Replace environment variables with your configuration
   - Reload systemd

2. Start the services:
   ```bash
   # Starts the databases, the migrations and the init first, then the service
   systemctl --user start firefox-sync-syncstorage.service
   ```

3. Services start on boot automatically (quadlets are generated units and cannot be
   enabled with `systemctl enable`, the `[Install]` section takes care of it)

5. Enable lingering (optional - allows services to start without login):
   ```bash
   loginctl enable-linger $USER
   ```

#### Self-hosted Mozilla accounts

If you also chose to self-host Mozilla accounts (see [FXA.md](FXA.md)), `prepare_environment.sh` installs their units as well (`firefox-sync-fxa-*`). Start them with:
```bash
systemctl --user start firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
  firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service
```
The databases, the migrations and the auth server are started automatically as dependencies.

#### MySQL instead of MariaDB

Answer `mysql` to the database backend question of `prepare_environment.sh` (`SYNC_DB=mysql` in `.env`): the units of [config/quadlet/sync-mysql/](/config/quadlet/sync-mysql) replace `firefox-sync-syncstorage-db.container` and `firefox-sync-tokenserver-db.container`, with their own volumes (`firefox-sync-syncstorage-db-mysql`, `firefox-sync-tokenserver-db-mysql`). The MariaDB volumes are left as they are; switching an existing install starts with empty databases, see [DATABASES.md](DATABASES.md#mariadb-or-mysql-containers).

#### Your own database server

To use a MariaDB or MySQL server you already run, answer `y` to "Use an existing database server instead of starting one?" in `prepare_environment.sh` (and for the accounts, a MySQL 8.0/8.4 or MariaDB 11.4 or later server, 12 with our accounts images). The database units are then not installed, the other units don't depend on them, and the script writes `database-setup.sql` for your server. A server on this host is `host.containers.internal` for the containers, not `localhost`. See [DATABASES.md](DATABASES.md).

#### Admin UI

If you enabled the [admin UI](ADMIN.md) in `prepare_environment.sh`, starting the Sync server also starts it, first, so that the Sync server sends it its metrics; on its own: `systemctl --user start firefox-sync-admin.service` (with self-hosted accounts it is also the sign-up gate, and starts the sign-up policy unit as a dependency). When the admin UI container is replaced (auto-update, restart) it restarts the Sync server, which only looks up its address at start.

#### Backups

`prepare_environment.sh` also installs the nightly backups, off: `firefox-sync-backup.container` (with self-hosted accounts `firefox-sync-backup-fxa.container`, which runs with it, just before) and `firefox-sync-backup.timer`, in `~/.config/systemd/user` (a timer is no Quadlet). Turn them on with `systemctl --user enable --now firefox-sync-backup.timer` (every day at `BACKUP_TIME`, UTC), run one with `systemctl --user start firefox-sync-backup.service`. The dumps are in the `firefox-sync-backups` volume, see [ADMIN.md](ADMIN.md#backups).

#### Managing Quadlet Services

```bash
# Check status
systemctl --user status firefox-sync-syncstorage.service

# View logs
journalctl --user -u firefox-sync-syncstorage.service -f

# Health: (healthy) next to each container that keeps running, the same checks as compose
# (see config/quadlet/README.md); one by one
podman ps
podman healthcheck run firefox-sync-syncstorage; echo $?   # 0: healthy

# Restart a service
systemctl --user restart firefox-sync-syncstorage.service

# Stop all services
systemctl --user stop firefox-sync-syncstorage.service
systemctl --user stop firefox-sync-syncstorage-db.service
systemctl --user stop firefox-sync-tokenserver-db.service

# Update containers (with AutoUpdate enabled)
podman auto-update
systemctl --user restart firefox-sync-syncstorage.service
```

#### Updating Configuration

To update SYNC_MAX_USERS or other settings:

1. Edit your `.env` file
2. Re-run the preparation script (it will detect existing config and update quadlets):
   ```bash
   ./prepare_environment.sh
   ```
   Or manually update quadlets by re-running with the same answers
3. Restart the service (this also re-runs the migrations and the init):
   ```bash
   systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-syncstorage.service
   ```
   With the admin UI, also restart `firefox-sync-admin.service` after changing `SYNC_MAX_USERS` between a plain number (read-only in the admin UI) and `initial:N` (managed there), see [ADMIN.md](ADMIN.md#max-users).

### Method 2: Using docker compose with the Podman socket

`docker compose` (v2) can drive Podman through its Docker-compatible API, using the same
`docker-compose.yml` as Docker and without the Docker daemon:

```bash
# once: start the Podman API socket for your user
systemctl --user enable --now podman.socket
export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock

# MariaDB, with longer healthcheck timings for rootless
docker compose -f docker-compose.yml -f docker-compose.podman.yml up -d

# MySQL 8.4 (SYNC_DB=mysql, see DATABASES.md)
docker compose -f docker-compose.yml -f docker-compose.podman.yml -f docker-compose.sync-mysql.yml up -d

# PostgreSQL
docker compose -f docker-compose.sync-postgres.yml up -d

# logs / stop
docker compose logs -f
docker compose down
```

Ports below 1024 need `sudo sysctl net.ipv4.ip_unprivileged_port_start=80` in rootless mode.

### Why not podman-compose?

The stack starts in a precise order: the databases, then a one-shot container running the
migrations, then the one-shot init that installs the max users limit, and only then the
public syncstorage service, so that nobody can sign up before the limit exists.

podman-compose links containers with `podman create --requires`, and Podman refuses to start
a container whose required container has already exited ("generating dependency graph for
container"), so the init and the service never start. It also does not check that a one-shot
container exited successfully. Use Quadlets or `docker compose` instead.

## Troubleshooting

### Issue: "Table 'tokenserver.users' doesn't exist"

This was the original rootless podman issue. If you still see this:

1. Check that you're using the latest init image:
   ```bash
   podman pull ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-init-latest
   ```

2. Check the init container logs:
   ```bash
   # With quadlets
   journalctl --user -u firefox-sync-tokenserver-db-init.service

   # With docker compose
   docker compose logs tokenserver_db_init
   ```

3. The script should show "Waiting for tables..." messages. If it times out, increase the wait time in the init script.

### Issue: Permission Denied on Volumes

```bash
# Check volume ownership
podman volume inspect firefox-sync-syncstorage-db
```

### Issue: Services Not Starting with Quadlets

```bash
# Check systemd status
systemctl --user status firefox-sync-syncstorage.service

# Reload systemd if you made changes
systemctl --user daemon-reload

# Check for errors in journal
journalctl --user -xe
```

### Issue: Port Already in Use

```bash
# Find what's using the port
sudo ss -tulpn | grep :5000

# Change the port in .env and re-run setup
```

### Issue: Slow Startup in Rootless Mode

This is normal. Rootless containers start slower than rootful ones. The init script now waits up to 2 minutes to accommodate this.

If you need faster startup:
1. Consider using rootful podman (requires sudo)
2. Increase system resources
3. Use SSD storage for volumes

## Performance Considerations

### Rootless vs Rootful

**Rootless** (Recommended for security):
- Better security isolation
- No root privileges required
- Slightly slower performance
- May have permission issues with some volumes

**Rootful** (Better performance):
- Faster startup and runtime
- Easier volume management
- Requires root privileges
- Less secure

### Storage Drivers

Podman supports multiple storage drivers. For best performance:

```bash
# Check current driver
podman info | grep graphDriverName

# overlay is fastest (default on most systems)
# vfs is slowest but most compatible
```

### Resource Limits

With rootless podman, you can set resource limits without root:

```bash
# In docker-compose.yml or quadlet files, add:
# deploy:
#   resources:
#     limits:
#       cpus: '2'
#       memory: 2G
```

### Volume Performance

For better volume performance:

1. Use named volumes (already configured)
2. Ensure volumes are on fast storage (SSD)
3. Consider using `:Z` or `:z` mount options for SELinux systems

## Migration from Docker

If you're migrating from Docker:

1. **Export volumes** (if you have existing data):
   ```bash
   docker run --rm -v syncstorage-db:/data -v $(pwd):/backup alpine tar czf /backup/syncstorage-db.tar.gz /data
   ```

2. **Import to Podman**:
   ```bash
   podman volume create firefox-sync-syncstorage-db
   podman run --rm -v firefox-sync-syncstorage-db:/data -v $(pwd):/backup alpine tar xzf /backup/syncstorage-db.tar.gz -C /
   ```

3. **Use Quadlets**, or `docker compose` with the Podman socket and the same docker-compose.yml file

## Additional Resources

- [Podman Documentation](https://docs.podman.io/)
- [Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [Rootless Podman Guide](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)
- [Firefox Sync Issue #11](https://github.com/porelli/firefox-sync/issues/11) - Original rootless podman issue

## Support

If you encounter issues:

1. Check this guide's troubleshooting section
2. Review the logs (journalctl or docker compose logs)
3. Open an issue on GitHub with:
   - Your podman version (`podman --version`)
   - Whether you're using rootless or rootful
   - Relevant logs
   - Your configuration (with secrets redacted)