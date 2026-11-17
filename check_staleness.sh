#!/usr/bin/env bash
# Independent check: is the newest backup still recent enough?
# Run from its own cron entry. If the backup job dies completely (cron off,
# disk full before start, script error before notify), only this catches it.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/notify.sh
source "$ROOT/lib/notify.sh"
# shellcheck source=lib/retention.sh
source "$ROOT/lib/retention.sh"

load_config "$ROOT"

# check_one <label> <dir> <glob> <max_hours>
check_one() {
  local label="$1" dir="$2" glob="$3" max="$4" newest age
  newest="$(latest_backup "$dir" "$glob")"
  if [[ -z "$newest" ]]; then
    log WARN "$label: no backup found in $dir."
    notify stale "$label: no backup found" "Dir: $dir"
    return 1
  fi
  age="$(age_hours "$newest")"
  if (( age > max )); then
    log WARN "$label: newest backup is ${age}h old (limit ${max}h)."
    notify stale "$label is stale" "Newest: $(basename "$newest")" "Age: ${age}h (limit ${max}h)"
    return 1
  fi
  log INFO "$label: newest backup is ${age}h old (limit ${max}h)."
}

STATUS=0
[[ "${ENABLE_DUMPALL:-true}" == "true" ]] && \
  { check_one pg_dumpall "$DUMPALL_DIR" '*.sql.gz' "${DUMPALL_STALE_HOURS:-48}" || STATUS=1; }
[[ "${ENABLE_BASEBACKUP:-false}" == "true" ]] && \
  { check_one pg_basebackup "$BASEBACKUP_DIR" '*_[0-9]*' "${BASEBACKUP_STALE_HOURS:-336}" || STATUS=1; }
exit "$STATUS"
