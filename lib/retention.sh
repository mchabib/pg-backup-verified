#!/usr/bin/env bash
# Backup selection and retention helpers. Pure file-system logic, unit-tested.
# Uses `stat -c` instead of `find -printf` so it also runs on busybox (Alpine).

# _by_mtime <find args...>  -> "<epoch> <path>" lines, newest first
_by_mtime() {
  find "$@" -exec stat -c '%Y %n' {} + 2>/dev/null | sort -rn
}

# latest_backup <dir> <glob>  -> path of the newest matching file, or nothing
latest_backup() {
  local dir="$1" glob="$2"
  [[ -d "$dir" ]] || return 0
  _by_mtime "$dir" -mindepth 1 -maxdepth 1 -name "$glob" | head -n1 | cut -d' ' -f2-
}

# age_hours <path> [now_epoch]  -> whole hours since the path was modified
age_hours() {
  local path="$1" now="${2:-$(date +%s)}"
  local mtime
  mtime="$(stat -c %Y -- "$path")" || return 1
  echo $(( (now - mtime) / 3600 ))
}

# cleanup_old_backups <dir> <days> [keep_min]
# Deletes entries older than <days>, but always keeps the newest <keep_min>
# (default 1) so a long outage of the backup job never deletes the last copy.
cleanup_old_backups() {
  local dir="$1" days="$2" keep_min="${3:-1}"

  if [[ -z "$dir" || -z "$days" ]]; then
    log WARN "cleanup_old_backups called without dir/days, skipping retention."
    return 0
  fi
  [[ -d "$dir" ]] || return 0

  local -a keep=()
  mapfile -t keep < <(_by_mtime "$dir" -mindepth 1 -maxdepth 1 ! -name '*.manifest' \
                        | head -n "$keep_min" | cut -d' ' -f2-)

  local item k skip
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    skip=0
    for k in "${keep[@]}"; do
      [[ "$item" == "$k" || "$item" == "$k.manifest" ]] && skip=1
    done
    (( skip )) && continue
    log INFO "Retention: removing $item (older than ${days}d)"
    rm -rf -- "$item"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -mtime "+$days" -print)
}
