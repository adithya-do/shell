#!/usr/bin/env bash
set -u

CONF="${1:-ogg_ms.conf}"

ts() { date "+%Y-%m-%d %H:%M:%S"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "[$(ts)] ERROR: need $1"; exit 2; }; }

# curl HTTP code (200 = OK)
http_code() {
  # $1=url $2=user $3=pass
  curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20 -u "$2:$3" "$1" 2>/dev/null
}

# curl body
http_body() {
  curl -sk --connect-timeout 10 --max-time 20 -u "$2:$3" "$1" 2>/dev/null
}

# Count statuses from JSON text without parsing (best-effort)
# Looks for "RUNNING"/"STOPPED"/"ABENDED"/"ACTIVE" etc
count_statuses() {
  # $1 = json text
  local txt="$1"

  # normalize to uppercase to simplify matching
  local up
  up="$(printf "%s" "$txt" | tr '[:lower:]' '[:upper:]')"

  local running stopped unknown
  running=$(printf "%s" "$up" | grep -Eo '"(STATUS|STATE|RUNTIMESTATUS|PROCESSSTATUS)"[[:space:]]*:[[:space:]]*"[^"]+"' | grep -E '"(RUN|ACTIVE)"' | wc -l | tr -d ' ')
  stopped=$(printf "%s" "$up"  | grep -Eo '"(STATUS|STATE|RUNTIMESTATUS|PROCESSSTATUS)"[[:space:]]*:[[:space:]]*"[^"]+"' | grep -E '"(STOP|ABEND|KILL|FAILED)"' | wc -l | tr -d ' ')

  # If we couldn’t detect any status fields, treat as unknown
  if [ "$running" -eq 0 ] && [ "$stopped" -eq 0 ]; then
    unknown=1
  else
    unknown=0
  fi

  printf "R:%s S:%s U:%s" "$running" "$stopped" "$unknown"
}

print_hdr() {
  printf "\n%-19s | %-10s | %-10s | %-8s | %-14s | %-14s\n" \
    "TIME" "DEPLOY" "SID" "ADMIN" "EXTRACTS" "REPLICATS"
  printf -- "-------------------+------------+------------+----------+----------------+----------------\n"
}

need curl
if [ ! -f "$CONF" ]; then
  echo "[$(ts)] ERROR: Config not found: $CONF"
  exit 1
fi

# endpoints to try
ADMIN_EPS="/services/v2/info/status /services/v2/info /services/v2/health"
EX_EPS="/services/v2/extracts"
RE_EPS="/services/v2/replicats"

print_hdr

# Config format:
# NAME|SID|HOST|PORT|USER|PASS_ENV
while IFS='|' read -r NAME SID HOST PORT USER PASS_ENV; do
  [ -z "${NAME:-}" ] && continue
  case "$NAME" in \#*) continue ;; esac

  PASS="${!PASS_ENV:-}"
  if [ -z "${PASS:-}" ]; then
    printf "%-19s | %-10s | %-10s | %-8s | %-14s | %-14s\n" \
      "$(ts)" "$NAME" "${SID:-NA}" "NO-PASS" "-" "-"
    continue
  fi

  BASE="https://${HOST}:${PORT}"

  ADMIN="DOWN"
  for ep in $ADMIN_EPS; do
    code="$(http_code "${BASE}${ep}" "$USER" "$PASS")"
    if [ "$code" = "200" ]; then
      ADMIN="UP"
      break
    fi
  done

  EX_SUM="-"
  RE_SUM="-"

  if [ "$ADMIN" = "UP" ]; then
    # Extracts
    for ep in $EX_EPS; do
      code="$(http_code "${BASE}${ep}" "$USER" "$PASS")"
      if [ "$code" = "200" ]; then
        body="$(http_body "${BASE}${ep}" "$USER" "$PASS")"
        EX_SUM="$(count_statuses "$body")"
        break
      fi
    done

    # Replicats
    for ep in $RE_EPS; do
      code="$(http_code "${BASE}${ep}" "$USER" "$PASS")"
      if [ "$code" = "200" ]; then
        body="$(http_body "${BASE}${ep}" "$USER" "$PASS")"
        RE_SUM="$(count_statuses "$body")"
        break
      fi
    done
  fi

  printf "%-19s | %-10s | %-10s | %-8s | %-14s | %-14s\n" \
    "$(ts)" "$NAME" "${SID:-NA}" "$ADMIN" "$EX_SUM" "$RE_SUM"

done < "$CONF"
