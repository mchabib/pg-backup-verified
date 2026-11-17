#!/usr/bin/env bash
# Telegram notifications. Fail-safe: missing credentials or a failed request
# is logged and never fails the backup itself.

notify_telegram() {
  local text="$1"

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    log INFO "Telegram skipped (TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not set)."
    return 0
  fi

  local code
  code="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" 2>/dev/null)" || code="000"

  [[ "$code" == 2* ]] || log WARN "Telegram notification failed (HTTP $code)."
  return 0
}

# notify <ok|fail|stale> <title> <detail lines...>
notify() {
  local status="$1" title="$2"; shift 2
  local icon
  case "$status" in
    ok)    icon="✅" ;;
    stale) icon="⚠️" ;;
    *)     icon="🔴" ;;
  esac

  local body="${icon} ${title}
Server: ${SERVER_LABEL:-unknown}"
  local line
  for line in "$@"; do
    body+=$'\n'"$line"
  done
  notify_telegram "$body"
}
