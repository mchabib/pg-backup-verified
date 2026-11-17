#!/usr/bin/env bash
# Restore drill: prove the newest pg_dumpall backup can actually be restored.
#
#   1. verify the file checksum against its manifest
#   2. start a throwaway PostgreSQL container (no access to production)
#   3. restore the dump into it and time it (RTO)
#   4. compare databases, table counts and row counts with the manifest
#   5. report, notify, and remove the container
#
# Usage: ./restore_drill.sh [backup.sql.gz]   (default: newest in DUMPALL_DIR)
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
require_cmd docker gzip sha256sum awk

DRILL_IMAGE="${DRILL_IMAGE:-postgres:16}"
DRILL_TOLERANCE_PCT="${DRILL_TOLERANCE_PCT:-5}"
DRILL_TIMEOUT_SEC="${DRILL_TIMEOUT_SEC:-60}"
DRILL_REPORT_DIR="${DRILL_REPORT_DIR:-$BACKUP_ROOT_DIR/drills}"

BACKUP="${1:-$(latest_backup "$DUMPALL_DIR" '*.sql.gz')}"
[[ -n "$BACKUP" && -f "$BACKUP" ]] || die "No backup to drill (looked in $DUMPALL_DIR)."
[[ -f "$BACKUP.manifest" ]] || die "No manifest for $BACKUP; cannot verify contents."

NAME="pgbv-drill-$$"
WORK="$(mktemp -d)"
cleanup() {
  docker rm -f "$NAME" &>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT

fail() {
  log ERROR "Drill FAILED: $*"
  write_report FAIL "$*"
  notify fail "Restore drill FAILED" "Backup: $(basename "$BACKUP")" "Reason: $*"
  exit 1
}

write_report() {
  mkdir -p "$DRILL_REPORT_DIR"
  local report
  report="$DRILL_REPORT_DIR/drill_$(date '+%Y%m%d_%H%M%S').txt"
  {
    echo "result:     $1"
    echo "backup:     $BACKUP"
    echo "detail:     $2"
    echo "image:      $DRILL_IMAGE"
    echo "restore_s:  ${RESTORE_SECONDS:-n/a}"
    echo "date:       $(date -Iseconds)"
  } > "$report"
  log INFO "Report: $report"
}

dexec() { docker exec -i -u postgres "$NAME" "$@"; }

log INFO "Drill on $(basename "$BACKUP") ($(human_size "$BACKUP"))"

# 1. Checksum
if ! out="$(verify_checksum "$BACKUP")"; then
  fail "$out"
fi
log INFO "Checksum OK."

# 2. Throwaway server
docker run -d --name "$NAME" --network none \
  -e POSTGRES_HOST_AUTH_METHOD=trust "$DRILL_IMAGE" >/dev/null \
  || fail "could not start $DRILL_IMAGE"

for _ in $(seq 1 "$DRILL_TIMEOUT_SEC"); do
  dexec pg_isready -q 2>/dev/null && dexec psql -Atqc 'SELECT 1' &>/dev/null && break
  sleep 1
done
dexec pg_isready -q || fail "drill server did not become ready in ${DRILL_TIMEOUT_SEC}s"

# 3. Restore. pg_dumpall always emits CREATE ROLE for the bootstrap superuser,
# which already exists in a fresh server; that one error is expected.
START=$(date +%s)
gzip -dc -- "$BACKUP" | dexec psql -X -q -v ON_ERROR_STOP=0 -d postgres >/dev/null 2>"$WORK/restore.err"
RESTORE_SECONDS=$(( $(date +%s) - START ))

UNEXPECTED="$(grep 'ERROR:' "$WORK/restore.err" | grep -v 'role "postgres" already exists' || true)"
if [[ -n "$UNEXPECTED" ]]; then
  fail "restore errors: $(head -n3 <<< "$UNEXPECTED" | tr '\n' ' ')"
fi
log INFO "Restore finished in ${RESTORE_SECONDS}s."

# 4. Compare with manifest. Run the same stats queries inside the container.
# No -i here: collect_stats calls this inside `while read` loops, and an
# interactive exec would swallow the loop's input.
psql_q() { docker exec -u postgres "$NAME" psql -X -At -F $'\t' -v ON_ERROR_STOP=1 -d "$1" -c "$2" </dev/null; }
limit="$(awk -F'\t' '$1 == "rows" { n[$2]++ } END { m = 0; for (d in n) if (n[d] > m) m = n[d]; print m }' "$BACKUP.manifest")"
ACTUAL="$(collect_stats "${limit:-$VERIFY_TABLE_LIMIT}")" || fail "could not read stats from restored server"
EXPECTED="$(cat "$BACKUP.manifest")"

if ! problems="$(compare_stats "$EXPECTED" "$ACTUAL" "$DRILL_TOLERANCE_PCT")"; then
  fail "$(head -n3 <<< "$problems" | tr '\n' ' ')"
fi

DBS="$(grep -c '^db' "$BACKUP.manifest")"
TABLES="$(grep -c '^rows' "$BACKUP.manifest")"
log INFO "Verified $DBS database(s), $TABLES table row counts within ${DRILL_TOLERANCE_PCT}%."

write_report PASS "databases=$DBS tables_checked=$TABLES"
notify ok "Restore drill PASSED" "Backup: $(basename "$BACKUP")" \
  "Restore time (RTO): ${RESTORE_SECONDS}s" "Databases: $DBS, tables checked: $TABLES"
