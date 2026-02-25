#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-ogg_ms_adminclient.conf}"
TMPDIR="${TMPDIR:-/tmp}"
TIMEOUT_SEC="${TIMEOUT_SEC:-25}"
MAIL_FROM="${MAIL_FROM:-ogg-monitor@$(hostname -f 2>/dev/null || hostname)}"
SUBJECT_PREFIX="${SUBJECT_PREFIX:-OGG MS ALERT}"

ts(){ date "+%Y-%m-%d %H:%M:%S"; }

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[$(ts)] ERROR: need $1"; exit 2; }; }

# Convert Windows CRLF if needed (prevents "unexpected EOF" issues)
fix_crlf() { sed -i 's/\r$//' "$1" 2>/dev/null || true; }

hhmmss_to_sec() {
  local s="${1:-00:00:00}"
  if [[ "$s" =~ ^([0-9]+):([0-9]{2}):([0-9]{2})$ ]]; then
    echo $((10#${BASH_REMATCH[1]}*3600 + 10#${BASH_REMATCH[2]}*60 + 10#${BASH_REMATCH[3]}))
  else
    echo 0
  fi
}

send_email() {
  # args: to subject html_body
  local to="$1" subject="$2" body="$3"

  if command -v sendmail >/dev/null 2>&1; then
    /usr/sbin/sendmail -t <<EOF
To: $to
From: $MAIL_FROM
Subject: $subject
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

$body
EOF
  elif command -v mailx >/dev/null 2>&1; then
    # mailx generally sends text; some versions support -a for headers; keep it simple as text fallback
    printf "%s\n" "$(echo "$body" | sed 's/<[^>]*>//g')" | mailx -s "$subject" "$to"
  else
    echo "[$(ts)] ERROR: Neither sendmail nor mailx found; cannot send email"
    return 1
  fi
}

run_adminclient_infoall() {
  # args: ogg_home host port user pass outfile
  local ogg_home="$1" host="$2" port="$3" user="$4" pass="$5" out="$6"
  local ac_bin="$ogg_home/bin/adminclient"
  [[ -x "$ac_bin" ]] || { echo "[$(ts)] ERROR: adminclient not found/executable: $ac_bin"; return 3; }

  local cmdfile
  cmdfile="$(mktemp "$TMPDIR/adminclient_cmd.XXXXXX")"

  cat >"$cmdfile" <<EOF
CONNECT https://$host:$port DEPLOYMENT DEFAULT AS $user PASSWORD $pass
INFO ALL
EXIT
EOF

  timeout "$TIMEOUT_SEC" "$ac_bin" < "$cmdfile" > "$out" 2>&1 || { rm -f "$cmdfile"; return 4; }
  rm -f "$cmdfile"
  return 0
}

# Build alert rows for any process where lag > 00:00:00 OR status not RUNNING/ACTIVE
# INFO ALL output formats vary; we do best-effort:
# - process type in column 1
# - process name in column 2
# - status in column 3
# - lag = first HH:MM:SS token found anywhere on the row
parse_infoall_alerts() {
  # args: file -> prints:
  #   1) writes HTML rows to stdout (only offending rows)
  #   2) sets global counters: OFF_LAG_COUNT, OFF_DOWN_COUNT
  local f="$1"
  OFF_LAG_COUNT=0
  OFF_DOWN_COUNT=0

  while IFS= read -r line; do
    line="${line//$'\r'/}"
    # Match common row starters (add more if your INFO ALL includes others)
    if [[ "$line" =~ ^[[:space:]]*(EXTRACT|REPLICAT|PUMP|DISTSRVR|RECVSRVR|PMSRVR)[[:space:]]+ ]]; then
      local type name status lag
      type="$(awk '{print $1}' <<<"$line")"
      name="$(awk '{print $2}' <<<"$line")"
      status="$(awk '{print $3}' <<<"$line")"

      # first HH:MM:SS token
      lag="$(grep -Eo '[0-9]+:[0-9]{2}:[0-9]{2}' <<<"$line" | head -n1 || true)"
      [[ -z "${lag:-}" ]] && lag="00:00:00"

      # Determine flags
      local lag_sec down_flag lag_flag
      lag_sec="$(hhmmss_to_sec "$lag")"
      lag_flag=0
      down_flag=0

      if [[ "$lag_sec" -gt 0 ]]; then
        lag_flag=1
      fi

      case "$status" in
        RUNNING|ACTIVE|STARTING) down_flag=0 ;;
        STOPPED|ABENDED|ABEND|KILLED|FAILED|DOWN) down_flag=1 ;;
        *) down_flag=1 ;; # unknown = treat as down
      esac

      if [[ "$lag_flag" -eq 1 || "$down_flag" -eq 1 ]]; then
        [[ "$lag_flag" -eq 1 ]] && OFF_LAG_COUNT=$((OFF_LAG_COUNT+1))
        [[ "$down_flag" -eq 1 ]] && OFF_DOWN_COUNT=$((OFF_DOWN_COUNT+1))

        # simple highlight
        local lag_cell status_cell
        if [[ "$lag_flag" -eq 1 ]]; then
          lag_cell="<td style='padding:6px;border:1px solid #ccc;color:#b00020;font-weight:700'>$lag</td>"
        else
          lag_cell="<td style='padding:6px;border:1px solid #ccc'>$lag</td>"
        fi

        if [[ "$down_flag" -eq 1 ]]; then
          status_cell="<td style='padding:6px;border:1px solid #ccc;color:#b00020;font-weight:700'>$status</td>"
        else
          status_cell="<td style='padding:6px;border:1px solid #ccc'>$status</td>"
        fi

        printf "<tr><td style='padding:6px;border:1px solid #ccc'>%s</td><td style='padding:6px;border:1px solid #ccc'>%s</td>%s%s</tr>\n" \
          "$type" "$name" "$status_cell" "$lag_cell"
      fi
    fi
  done < "$f"
}

# ---------- main ----------
need timeout
need awk
need grep
need head
need mktemp
fix_crlf "$0" 2>/dev/null || true

if [[ ! -f "$CONF" ]]; then
  echo "[$(ts)] ERROR: Config not found: $CONF"
  exit 1
fi

rc=0

while IFS='|' read -r NAME SID OGG_HOME ADMIN_HOST ADMIN_PORT USER PASS_ENV EMAIL_TO; do
  [[ -z "${NAME:-}" ]] && continue
  [[ "$NAME" =~ ^# ]] && continue

  PASS="${!PASS_ENV:-}"
  if [[ -z "${PASS:-}" ]]; then
    echo "[$(ts)] [$NAME] ERROR: Password env var $PASS_ENV not set"
    rc=2
    continue
  fi
  if [[ -z "${EMAIL_TO:-}" ]]; then
    echo "[$(ts)] [$NAME] ERROR: EMAIL_TO missing in config"
    rc=2
    continue
  fi

  out="$(mktemp "$TMPDIR/ogg_infoall_${NAME}.XXXXXX")"

  if ! run_adminclient_infoall "$OGG_HOME" "$ADMIN_HOST" "$ADMIN_PORT" "$USER" "$PASS" "$out"; then
    # Login failure alert
    subject="$SUBJECT_PREFIX | $NAME | SID=${SID:-NA} | ADMINCLIENT LOGIN FAIL"
    body="<html><body>
      <h3 style='font-family:Arial'>GoldenGate MS Alert</h3>
      <p style='font-family:Arial'>Deployment: <b>$NAME</b> &nbsp; SID: <b>${SID:-NA}</b></p>
      <p style='font-family:Arial;color:#b00020'><b>adminclient login / INFO ALL failed.</b></p>
      <pre style='border:1px solid #ccc;padding:10px;background:#f7f7f7;white-space:pre-wrap'>$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$out" | tail -n 80)</pre>
      <p style='font-family:Arial;font-size:12px;color:#666'>Time: $(ts) Host: $(hostname)</p>
    </body></html>"
    send_email "$EMAIL_TO" "$subject" "$body" || true
    rm -f "$out"
    rc=2
    continue
  fi

  # Parse offending rows (lag>0 OR down)
  OFF_LAG_COUNT=0
  OFF_DOWN_COUNT=0
  rows="$(parse_infoall_alerts "$out" || true)"

  if [[ "${OFF_LAG_COUNT:-0}" -gt 0 || "${OFF_DOWN_COUNT:-0}" -gt 0 ]]; then
    # Trigger email if ANY lag happens (OFF_LAG_COUNT>0), per your requirement.
    # Also triggers if any down/abended.
    subject="$SUBJECT_PREFIX | $NAME | SID=${SID:-NA} | LAG:${OFF_LAG_COUNT} DOWN:${OFF_DOWN_COUNT}"
    body="<html><body>
      <h3 style='font-family:Arial'>GoldenGate Microservices Alert</h3>
      <p style='font-family:Arial'>
        Deployment: <b>$NAME</b> &nbsp; SID: <b>${SID:-NA}</b> <br/>
        AdminServer: <b>https://$ADMIN_HOST:$ADMIN_PORT</b> <br/>
        Time: <b>$(ts)</b> &nbsp; Host: <b>$(hostname)</b>
      </p>

      <p style='font-family:Arial'>
        Trigger: <b>Any lag &gt; 00:00:00</b> (count: <b>${OFF_LAG_COUNT}</b>) &nbsp;
        Down/Abended count: <b>${OFF_DOWN_COUNT}</b>
      </p>

      <table style='border-collapse:collapse;font-family:Arial;font-size:13px'>
        <tr style='background:#efefef'>
          <th style='padding:6px;border:1px solid #ccc'>TYPE</th>
          <th style='padding:6px;border:1px solid #ccc'>NAME</th>
          <th style='padding:6px;border:1px solid #ccc'>STATUS</th>
          <th style='padding:6px;border:1px solid #ccc'>LAG</th>
        </tr>
        ${rows}
      </table>

      <p style='font-family:Arial;font-size:12px;color:#666'>
        Note: This email triggers on any non-zero lag. If you want threshold-based alerts (warn/crit), tell me your minutes.
      </p>
    </body></html>"

    send_email "$EMAIL_TO" "$subject" "$body" || true

    # exit code: 2 if down/abended, else 1 if only lag
    if [[ "${OFF_DOWN_COUNT:-0}" -gt 0 ]]; then
      rc=2
    elif [[ "$rc" -lt 1 ]]; then
      rc=1
    fi
  fi

  rm -f "$out"
done < "$CONF"

exit "$rc"
