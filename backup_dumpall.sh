#!/usr/bin/env bash
# Logical backup of the whole cluster with pg_dumpall, gzipped, plus a
# manifest (checksum + per-database stats) that restore_drill.sh verifies.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/notify.sh
source "$ROOT/lib/notify.sh"
# shellcheck source=lib/retention.sh
source "$ROOT/lib/retention.sh"
# shellcheck source=lib/manifest.sh
source "$ROOT/lib/manifest.sh"

load_config "$ROOT"
require_cmd pg_dumpall psql gzip sha256sum

mkdir -p "$DUMPALL_DIR"
TARGET="$DUMPALL_DIR/${SERVER_LABEL}_$(date '+%Y%m%d_%H%M%S').sql.gz"
PARTIAL="$TARGET.partial"

log INFO "pg_dumpall -> $TARGET (host=$PGHOST port=$PGPORT user=$PGUSER)"
START=$(date +%s)

pg_dumpall -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" | gzip > "$PARTIAL"
CODES=("${PIPESTATUS[@]}")
DURATION=$(( $(date +%s) - START ))

if [[ "${CODES[0]}" -ne 0 || "${CODES[1]}" -ne 0 ]]; then
  rm -f -- "$PARTIAL"
  log ERROR "pg_dumpall failed (exit ${CODES[0]}, gzip ${CODES[1]}) after ${DURATION}s."
  notify fail "pg_dumpall FAILED" "Exit code: ${CODES[0]}" "Duration: ${DURATION}s"
  exit 1
fi

# Only a complete dump gets the final name, so a crash never leaves a
# truncated file that looks valid.
mv -- "$PARTIAL" "$TARGET"

log INFO "Collecting stats for manifest (top $VERIFY_TABLE_LIMIT tables per database)."
if ! STATS="$(collect_stats "$VERIFY_TABLE_LIMIT")"; then
  log ERROR "Could not collect stats; backup kept but has no manifest."
  notify fail "pg_dumpall: manifest FAILED" "File: $(basename "$TARGET")"
  exit 1
fi
write_manifest "$TARGET" "$STATS"

SIZE="$(human_size "$TARGET")"
DBS="$(grep -c '^db' "$TARGET.manifest")"
log INFO "Done in ${DURATION}s, $SIZE, $DBS database(s)."

cleanup_old_backups "$DUMPALL_DIR" "$RETENTION_DAYS"

notify ok "pg_dumpall OK" "File: $(basename "$TARGET")" "Size: $SIZE" "Databases: $DBS" "Duration: ${DURATION}s"
