# pg-backup-verified

PostgreSQL backups that prove they can be restored.

Most backup scripts stop at "the file exists". This toolkit records what each
backup *should* contain when it is taken, then regularly restores it into a
throwaway container and checks that it really does.

```
backup_dumpall.sh ──▶ app_20261117_013000.sql.gz
                      app_20261117_013000.sql.gz.manifest   (sha256 + databases + row counts)
                                │
restore_drill.sh ───────────────┘
  1. sha256 matches manifest?
  2. docker run postgres:16  (--network none, thrown away after)
  3. restore, measure time        → RTO
  4. same databases? same table count? row counts within tolerance?
  5. report + Telegram, remove container
```

## What is included

| Script | Does |
|---|---|
| `backup_dumpall.sh` | `pg_dumpall` piped to gzip, written as `.partial` then renamed (no truncated file ever looks valid), plus a manifest |
| `backup_basebackup.sh` | `pg_basebackup` tar+gzip with streamed WAL and a `SHA256SUMS` file |
| `restore_drill.sh` | restores the newest dump into an isolated container and verifies it against the manifest |
| `check_staleness.sh` | independent cron job that alerts when the newest backup is too old, even if the backup job itself died |
| `lib/retention.sh` | deletes old backups but **always keeps the newest one**, so a long outage of the backup job never removes the last copy |

All alerts go to Telegram (optional). Everything is Bash plus the standard
PostgreSQL client tools; the drill also needs Docker.

## Quick start

```bash
cp .env.example .env && chmod 600 .env    # set PGHOST, PGUSER, PGPASSWORD, BACKUP_ROOT_DIR
./backup_dumpall.sh
./restore_drill.sh                         # newest backup, or pass a file
crontab crontab.example                    # daily backup, weekly drill, 6-hourly staleness check
```

Example drill output:

```
[INFO] Drill on it_20261117_090503.sql.gz (576K)
[INFO] Checksum OK.
[INFO] Restore finished in 1s.
[INFO] Verified 2 database(s), 5 table row counts within 5%.
```

and when something is wrong:

```
[ERROR] Drill FAILED: checksum mismatch: expected 52a1e5…, got aa0f1f…
[ERROR] Drill FAILED: row count off in shop public.customers: expected 9999, got 5000 (tolerance 5%)
```

## Design notes

- **Why a row-count tolerance?** `pg_dumpall` does not take one snapshot across
  databases, and the manifest counts are taken right after the dump on a live
  server. Exact equality would fail on any busy system. Table *existence* and
  per-database table counts must match exactly. Drift is set by `DRILL_TOLERANCE_PCT`.
- **Why only the N largest tables?** Exact `count(*)` on every table of a big
  database is expensive. `VERIFY_TABLE_LIMIT` (default 20) covers the tables
  that matter most.
- **The drill container has `--network none`**, so a restored dump can never
  reach production, even if it contains connection settings.
- **One expected restore error:** `pg_dumpall` always emits `CREATE ROLE postgres`,
  which already exists in a fresh server. Every other `ERROR:` fails the drill.
- **The drill image must match the source major version** (`DRILL_IMAGE`).

## Tests

```bash
make lint          # shellcheck
make test          # bats unit tests (retention, manifest, checksum, comparison)
make integration   # Docker only: real backup -> drill PASS -> corrupted file FAIL -> tampered manifest FAIL
```

`PG_IMAGE=postgres:16-alpine make integration` works too; the scripts avoid GNU-only flags so they run on busybox.

CI runs all three on every push (`.github/workflows/ci.yml`).

## Limitations

- The restore drill covers `pg_dumpall` backups. Physical backups get checksums only; a PITR drill is on the roadmap.
- Row counts verify volume, not content. For critical tables, add your own checks after the restore step.

## License

MIT
