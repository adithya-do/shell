#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-ogg_ms.conf}"

# ---------- helpers ----------
ts() { date "+%Y-%m-%d %H:%M:%S"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[$(ts)] ERROR: Missing required command: $1"
    exit 2
  }
}

# Use jq if available, else use python for JSON parsing
json_get() {
  # usage: json_get '<json>' '<python_expr>'   (python_expr uses obj variable)
  local json="$1"
  local pyexpr="$2"
  python3 - <<PY
import json, sys
obj=json.loads(sys.stdin.read())
print($pyexpr)
PY
}

http_get() {
  # usage: http_get URL USER PASS
  local url="$1" user="$2" pass="$3"
  curl -sk --connect-timeout 10 --max-time 20 -u "${user}:${pass}" "$url"
}

http_code() {
  local url="$1" user="$2" pass="$3"
  curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20 -u "${user}:${pass}" "$url"
}

print_hdr() {
  printf "\n%-19s | %-10s | %-8s | %-10s | %-10s | %-10s | %-10s\n" \
    "TIME" "DEPLOY" "ADMIN" "EXTRACTS" "REPLICATS" "WARN" "CRIT"
  printf -- "-------------------+------------+----------+------------+------------+------------+------------\n"
}

# Try common endpoints (version/deployment may differ). Script tries several.
ADMIN_STATUS_ENDPOINTS=(
  "/services/v2/info/status"
  "/services/v2/info"
  "/services/v2/health"
)

EXTRACTS_ENDPOINTS=(
  "/services/v2/extracts"
)

REPLICATS_ENDPOINTS=(
  "/services/v2/replicats"
)

# Parse lag from common field names if present (best-effort).
# Returns lag minutes as int if found, else -1
extract_lag_minutes() {
  local item_json="$1"
  python3 - <<PY
import json, re, sys
x=json.loads(sys.stdin.read())

# common candidates
cands=[]
for k in ("lag", "checkpointLag", "checkpoint_lag", "lagTime", "lagtime", "applyLag", "extractLag"):
    if k in x: cands.append(x[k])

def to_minutes(v):
    if v is None: return None
    # numeric seconds/minutes
    if isinstance(v, (int,float)):
        # assume seconds if large; otherwise minutes
        return int(v/60) if v > 600 else int(v)
    if isinstance(v, str):
        s=v.strip()
        # HH:MM:SS
        m=re.match(r"^(\d+):(\d+):(\d+)$", s)
        if m:
            h=int(m.group(1)); mi=int(m.group(2)); se=int(m.group(3))
            return h*60+mi + (1 if se>=30 else 0)
        # MM:SS
        m=re.match(r"^(\d+):(\d+)$", s)
        if m:
            mi=int(m.group(1)); se=int(m.group(2))
            return mi + (1 if se>=30 else 0)
        # PT#H#M#S (ISO-8601 duration)
        m=re.match(r"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$", s)
        if m:
            h=int(m.group(1) or 0); mi=int(m.group(2) or 0); se=int(m.group(3) or 0)
            return h*60+mi + (1 if se>=30 else 0)
    return None

for v in cands:
    mn=to_minutes(v)
    if mn is not None:
        print(mn)
        sys.exit(0)

print(-1)
PY <<<"$item_json"
}

# Count running/stopped and track lag threshold breaches (best-effort)
analyze_list() {
  # usage: analyze_list '<json>' warn_min crit_min
  local body="$1" warn_min="$2" crit_min="$3"

  # Expecting either:
  # 1) {"items":[...]} or {"response":{"items":[...]}} or {"data":[...]} or a plain list
  python3 - <<PY
import json, sys
warn_min=int(sys.argv[1]); crit_min=int(sys.argv[2])
obj=json.loads(sys.stdin.read())

def find_items(o):
    if isinstance(o, list): return o
    if isinstance(o, dict):
        for k in ("items","data","extracts","replicats"):
            if k in o and isinstance(o[k], list):
                return o[k]
        # nested response common pattern
        for k in ("response","result"):
            if k in o:
                it=find_items(o[k])
                if it is not None: return it
    return []

items=find_items(obj)
running=0
stopped=0
unknown=0
warn=0
crit=0

def status_of(x):
    if not isinstance(x, dict): return "UNKNOWN"
    for k in ("status","state","runtimeStatus","processStatus"):
        if k in x and isinstance(x[k], str):
            return x[k].upper()
    return "UNKNOWN"

def lag_minutes_of(x):
    # try multiple fields; allow strings like HH:MM:SS / PT.. / numbers
    if not isinstance(x, dict): return None
    for k in ("lag","checkpointLag","checkpoint_lag","lagTime","lagtime","applyLag","extractLag"):
        if k in x:
            v=x[k]
            if v is None: continue
            if isinstance(v,(int,float)):
                return int(v/60) if v>600 else int(v)
            if isinstance(v,str):
                s=v.strip()
                # HH:MM:SS
                import re
                m=re.match(r"^(\d+):(\d+):(\d+)$", s)
                if m:
                    h=int(m.group(1)); mi=int(m.group(2)); se=int(m.group(3))
                    return h*60+mi + (1 if se>=30 else 0)
                m=re.match(r"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$", s)
                if m:
                    h=int(m.group(1) or 0); mi=int(m.group(2) or 0); se=int(m.group(3) or 0)
                    return h*60+mi + (1 if se>=30 else 0)
    return None

for it in items:
    st=status_of(it)
    if "RUN" in st or "ACTIVE" in st:
        running += 1
    elif "STOP" in st or "ABEND" in st or "KILL" in st:
        stopped += 1
    else:
        unknown += 1

    lagm=lag_minutes_of(it)
    if lagm is None: 
        continue
    if crit_min>0 and lagm >= crit_min:
        crit += 1
    elif warn_min>0 and lagm >= warn_min:
        warn += 1

print(f"{running}|{stopped}|{unknown}|{warn}|{crit}")
PY "$warn_min" "$crit_min" <<<"$body"
}

# ---------- main ----------
need_cmd curl
need_cmd python3

if [[ ! -f "$CONF" ]]; then
  echo "[$(ts)] ERROR: Config not found: $CONF"
  exit 1
fi

print_hdr

while IFS='|' read -r NAME HOST PORT USER PASS_ENV WARN_MIN CRIT_MIN; do
  [[ -z "${NAME:-}" ]] && continue
  [[ "$NAME" =~ ^# ]] && continue

  PASS="${!PASS_ENV:-}"
  if [[ -z "$PASS" ]]; then
    printf "%-19s | %-10s | %-8s | %-10s | %-10s | %-10s | %-10s\n" \
      "$(ts)" "$NAME" "NO-PASS" "-" "-" "-" "-"
    continue
  fi

  BASE="https://${HOST}:${PORT}"

  # Admin status: try endpoints, accept 200 as UP
  ADMIN="DOWN"
  for ep in "${ADMIN_STATUS_ENDPOINTS[@]}"; do
    code="$(http_code "${BASE}${ep}" "$USER" "$PASS" || true)"
    if [[ "$code" == "200" ]]; then
      ADMIN="UP"
      break
    fi
  done

  EX_SUM="-"
  RE_SUM="-"
  WARN_BREACH=0
  CRIT_BREACH=0

  if [[ "$ADMIN" == "UP" ]]; then
    # Extracts
    for ep in "${EXTRACTS_ENDPOINTS[@]}"; do
      code="$(http_code "${BASE}${ep}" "$USER" "$PASS" || true)"
      if [[ "$code" == "200" ]]; then
        body="$(http_get "${BASE}${ep}" "$USER" "$PASS" || true)"
        ex="$(analyze_list "$body" "${WARN_MIN:-0}" "${CRIT_MIN:-0}" || echo "0|0|0|0|0")"
        IFS='|' read -r ex_run ex_stop ex_unk ex_warn ex_crit <<<"$ex"
        EX_SUM="R:${ex_run} S:${ex_stop} U:${ex_unk}"
        WARN_BREACH=$((WARN_BREACH + ex_warn))
        CRIT_BREACH=$((CRIT_BREACH + ex_crit))
        break
      fi
    done

    # Replicats
    for ep in "${REPLICATS_ENDPOINTS[@]}"; do
      code="$(http_code "${BASE}${ep}" "$USER" "$PASS" || true)"
      if [[ "$code" == "200" ]]; then
        body="$(http_get "${BASE}${ep}" "$USER" "$PASS" || true)"
        re="$(analyze_list "$body" "${WARN_MIN:-0}" "${CRIT_MIN:-0}" || echo "0|0|0|0|0")"
        IFS='|' read -r re_run re_stop re_unk re_warn re_crit <<<"$re"
        RE_SUM="R:${re_run} S:${re_stop} U:${re_unk}"
        WARN_BREACH=$((WARN_BREACH + re_warn))
        CRIT_BREACH=$((CRIT_BREACH + re_crit))
        break
      fi
    done
  fi

  printf "%-19s | %-10s | %-8s | %-10s | %-10s | %-10s | %-10s\n" \
    "$(ts)" "$NAME" "$ADMIN" "$EX_SUM" "$RE_SUM" "$WARN_BREACH" "$CRIT_BREACH"

done < "$CONF"
