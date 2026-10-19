# Storage and maintenance

What the [admin UI](README.md) shows of the Sync storage database, how it purges what nobody reads any more, and what it cleans up by itself every day. For one account's Sync data, see [Sync data](accounts.md#sync-data).

## The storage report

The Storage section of the overview splits what the storage database holds:

| Part | What it is |
|---|---|
| live | what Firefox reads back |
| expired | items past their time to live, which the Sync server no longer returns |
| orphaned | storage nobody reads any more, see below |
| stale batches | uploads in several parts never committed, past their 2 hours |

Orphaned storage is:

- the rows of replaced keys, a day after they were replaced, unless it is the current row of its email. A device still on the old keys may need them once more in that day.
- with self-hosted accounts, the rows of `FXA_EMAIL_DOMAIN` whose account is gone from the accounts database (deleted by its owner in the account settings), and the storage of each;
- storage user ids with no tokenserver row at all.

Rows of another email domain whose account is not in the accounts database are listed apart, and never purged. They come from an earlier `FXA_EMAIL_DOMAIN`, or from Mozilla's accounts before the self-hosted ones. Delete them from their [account page](accounts.md#delete-an-account) if they are gone.

The section also lists the 10 largest accounts. On MariaDB it shows the space the tables keep after deletions. This gives it back to the disk, by rebuilding the table, best run when few people sync:

```sql
OPTIMIZE TABLE bso;
```

## Purge

**Purge now…**, then the confirm page, which lists the orphans, deletes in this order:

1. the orphans, their tokenserver rows and storage;
1. the expired items: `DELETE FROM bso WHERE ttl < now LIMIT 1000` until none are left on MariaDB and MySQL, and `bsos` and `batches` past `expiry` on PostgreSQL;
1. the stale batches.

It deletes 1000 rows at a time, so the Sync server keeps answering. Live data stays. Deleted accounts no longer count towards max users once purged. Past 20 seconds the purge goes on in the background, and the event log has what it removed.

With `ADMIN_PURGE=1` it runs every day by itself. It then leaves for a purge by hand what looks like a database that came back empty, or from an older backup, rather than people leaving:

- the deleted accounts, when they are more than half of the accounts using Sync, or no account is left (so also the only account of a one-account server);
- the storage without a tokenserver row, when it is more than half of the storage user ids, or the tokenserver has no row at all.

The event says what it left.

## Maintenance and retention

What runs by itself, once a day, kept across restarts (`ffs_jobs` in the admin UI's database). The Activity page shows each job's last run and what it did, and the event log has it (kind `maintenance`). A job that failed runs again an hour later.

- **Pruning the accounts database**, with self-hosted accounts. See [below](#prune-the-accounts-database).
- **The purge of the Sync storage**, with `ADMIN_PURGE=1`, see [Purge](#purge).
- **Deleting old unconfirmed accounts**, with `ADMIN_DELETE_UNCONFIRMED_DAYS=N`, see [below](#delete-old-unconfirmed-accounts).

Every minute the admin UI also counts the accounts created in the last hour. More than `ADMIN_SIGNUP_BURST` (10; 0: never) is an event and an alert (kind `sign-up burst`), at most once an hour. It means someone is creating accounts in bulk: close sign-ups or switch to an allowlist if they are not yours, see [Sign-ups](accounts.md#sign-ups).

### Prune the accounts database

The daily pruning deletes:

- what Mozilla's `prune_10` deletes, with Mozilla's defaults: unblock and sign-in codes after 30 days; reset and password change tokens, and sessions without a device, after 4 weeks. The session of a Firefox has its device and is never pruned;
- the same session rule once more, for those `prune_10` stops at;
- expired OAuth codes (15 minutes);
- the security events of the account settings after `ADMIN_RETENTION_DAYS`, which Mozilla's procedure never prunes.

`ffs.prune` takes the database's clock, whatever time it is given, and keeps at least the security events of the last day.

To run it at once, click **Prune the accounts database now…** on the Activity page. Its confirm page says what goes (`GET /maintenance/prune`, whose form posts there). The overview says when it last ran, next to the schema levels.

### Delete old unconfirmed accounts

With `ADMIN_DELETE_UNCONFIRMED_DAYS=N` (at least 1), the admin UI deletes the accounts created more than N days ago that never confirmed an email:

- with Mozilla's deletion (reason `fxa_unverified_account_delete`) and their OAuth tokens;
- at most 10000 a run, one at a time, through `ffs.delete_unconfirmed`. It refuses an account that confirmed its email or was created less than a day ago, whatever the admin UI asks.

The event names the accounts deleted (as many emails as fit, then how many more), also when it stops partway.

By hand: **Delete the old ones…**, next to the count of unconfirmed accounts on the overview. Its confirm page lists them first. It takes 30 days by default, or `?days=N` in the address of the confirm page.

### What is kept for how long

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
| the backups themselves | `backups` volume | the newest `BACKUP_KEEP` runs, see [Backups](../backups.md#the-backup-service) |

The tables named `ffs_*` are in the admin UI's own database, see [The admin UI's own database](../reference/database-users.md#the-admin-uis-own-database).
