#!/usr/bin/env bash
# Physical backup with pg_basebackup (tar + gzip, WAL streamed), with a
# checksum manifest for every tar file. Needs a role with REPLICATION and a
# matching pg_hba.conf entry.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/notify.sh
source "$ROOT/lib/notify.sh"
# shellcheck source=lib/retention.sh
source "$ROOT/lib/retention.sh"

load_config "$ROOT"
require_cmd pg_basebackup sha256sum

mkdir -p "$BASEBACKUP_DIR"
TARGET="$BASEBACKUP_DIR/${SERVER_LABEL}_$(date '+%Y%m%d_%H%M%S')"
PARTIAL="$TARGET.partial"

log INFO "pg_basebackup -> $TARGET"
START=$(date +%s)

if ! pg_basebackup -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
      -D "$PARTIAL" -Ft -z -X stream --checkpoint=fast --label="pgbv-$(date +%s)"; then
  DURATION=$(( $(date +%s) - START ))
  rm -rf -- "$PARTIAL"
  log ERROR "pg_basebackup failed after ${DURATION}s."
  notify fail "pg_basebackup FAILED" "Duration: ${DURATION}s"
  exit 1
fi
DURATION=$(( $(date +%s) - START ))

( cd "$PARTIAL" && sha256sum -- *.tar.gz backup_manifest > SHA256SUMS )
mv -- "$PARTIAL" "$TARGET"

SIZE="$(human_size "$TARGET")"
log INFO "Done in ${DURATION}s, $SIZE. Verify later with: (cd $TARGET && sha256sum -c SHA256SUMS)"

cleanup_old_backups "$BASEBACKUP_DIR" "$RETENTION_DAYS"

notify ok "pg_basebackup OK" "Dir: $(basename "$TARGET")" "Size: $SIZE" "Duration: ${DURATION}s"
