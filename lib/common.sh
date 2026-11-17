#!/usr/bin/env bash
# Shared helpers: config loading and logging.
# Sourced by every entry-point script; never executed directly.

# log <LEVEL> <message...>  -> stdout + $LOG_DIR/pgbv-YYYY-MM-DD.log
log() {
  local level="$1"; shift
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$line"
  if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p "$LOG_DIR" 2>/dev/null && echo "$line" >> "$LOG_DIR/pgbv-$(date '+%Y-%m-%d').log"
  fi
}

die() {
  log ERROR "$*"
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" &>/dev/null || die "Required command '$c' not found in PATH."
  done
}

# load_config <repo_root>
# Reads $PGBV_ENV_FILE (default <repo_root>/.env), applies defaults and
# validates required variables. Relative LOG_DIR / BACKUP_ROOT_DIR are
# resolved against the repo root so cron and manual runs behave the same.
load_config() {
  local root="$1"
  local env_file="${PGBV_ENV_FILE:-$root/.env}"

  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  elif [[ -z "${PGHOST:-}" ]]; then
    echo "[ERROR] No config: $env_file not found and PGHOST not set." >&2
    echo "        Run: cp .env.example .env && chmod 600 .env" >&2
    exit 1
  fi

  local var
  for var in PGHOST PGUSER BACKUP_ROOT_DIR; do
    [[ -n "${!var:-}" ]] || { echo "[ERROR] Required variable '$var' is empty." >&2; exit 1; }
  done

  PGPORT="${PGPORT:-5432}"
  RETENTION_DAYS="${RETENTION_DAYS:-7}"
  SERVER_LABEL="${SERVER_LABEL:-$(hostname)}"
  LOG_DIR="${LOG_DIR:-./logs}"
  VERIFY_TABLE_LIMIT="${VERIFY_TABLE_LIMIT:-20}"

  [[ "$LOG_DIR" == /* ]] || LOG_DIR="$root/${LOG_DIR#./}"
  [[ "$BACKUP_ROOT_DIR" == /* ]] || BACKUP_ROOT_DIR="$root/${BACKUP_ROOT_DIR#./}"

  # Used by the entry-point scripts that source this file.
  # shellcheck disable=SC2034
  DUMPALL_DIR="$BACKUP_ROOT_DIR/dumpall"
  # shellcheck disable=SC2034
  BASEBACKUP_DIR="$BACKUP_ROOT_DIR/basebackup"

  export PGHOST PGPORT PGUSER PGPASSWORD
}

# human_size <file|dir>
human_size() {
  du -sh "$1" 2>/dev/null | cut -f1
}
