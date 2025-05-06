#!/bin/bash

CONFIG_FILE="/opt/oracle/scripts/gg_monitoring/ogg_homes.txt"
ALERTS_FILE="/opt/oracle/scripts/gg_monitoring/alerts.txt"
HISTORY_FILE="/opt/oracle/scripts/gg_monitoring/alert_history.txt"
EMAIL_RECIPIENT="abc@abc.com"
HOSTNAME=$(hostname)

mkdir -p /opt/oracle/scripts/gg_monitoring
touch "$ALERTS_FILE" "$HISTORY_FILE"

send_email() {
    subject="$1"
    body="$2"
    (
        echo "Subject: $subject"
        echo "Content-Type: text/html"
        echo
        echo "$body"
    ) | /usr/sbin/sendmail "$3"
}

send_summary() {
    date_today=$(date '+%Y-%m-%d')
    summary_sent_flag="/opt/oracle/scripts/gg_monitoring/summary_sent_$date_today"

    # If called manually, skip flag check
    if [[ "$1" != "manual" && -f "$summary_sent_flag" ]]; then return; fi

    active_count=$(wc -l < "$ALERTS_FILE")
    echo "$date_today:$active_count" >> "$HISTORY_FILE"

    html="<html><b>GoldenGate Monitoring Summary - $date_today</b><br><br>
    <table border=1 cellpadding=4 cellspacing=0>
    <tr><th>Date</th><th>Alert Count</th><th>Graph</th></tr>"

    max_count=$(awk -F: 'BEGIN{max=0} {if($2>max) max=$2} END{print max}' "$HISTORY_FILE")
    [[ "$max_count" -eq 0 ]] && max_count=1

    while read -r history_line; do
        h_date=$(echo "$history_line" | cut -d: -f1)
        h_count=$(echo "$history_line" | cut -d: -f2)
        bar_len=$(( (h_count * 20) / max_count ))
        bar=""
        for ((i=0; i<bar_len; i++)); do bar="${bar}▇"; done
        html+="<tr><td>$h_date</td><td>$h_count</td><td>$bar</td></tr>"
    done < <(tail -7 "$HISTORY_FILE")

    html+="</table><br><p>Active Alerts:</p><ul>"

    while read -r alert_line; do
        a_key=$(echo "$alert_line" | cut -d: -f1,2)
        severity=$(echo "$alert_line" | cut -d: -f3)
        process=$(echo "$a_key" | cut -d: -f2)
        ogg_home=$(echo "$a_key" | cut -d: -f1)
        db=$(awk -v home="$ogg_home" '$1==home {print $3}' "$CONFIG_FILE")
        html+="<li>$severity - $db - $process - $HOSTNAME</li>"
    done < "$ALERTS_FILE"

    html+="</ul></html>"

    send_email "GoldenGate Monitoring Summary - $date_today" "$html" "$EMAIL_RECIPIENT"

    if [[ "$1" != "manual" ]]; then
        touch "$summary_sent_flag"
    fi
}

# If 'summary' passed as argument, only send summary
if [[ "$1" == "summary" ]]; then
    send_summary manual
    exit 0
fi

# --- normal monitoring ---
date_today=$(date '+%Y-%m-%d')
current_alert_keys=()

while read -r ogg_home contact db; do
    if [[ -z "$ogg_home" || -z "$contact" || -z "$db" ]]; then continue; fi

    cd "$ogg_home" || continue
    output=$(echo "info all" | ./ggsci 2>/dev/null)

    while read -r line; do
        process=$(echo "$line" | awk '{print $2}')
        state=$(echo "$line" | awk '{print $3}')
        proc_key="$ogg_home:$process"

        if echo "$state" | grep -E "STOP|ABEND" >/dev/null; then
            severity="CRITICAL"
        elif ! echo "$state" | grep "RUNNING" >/dev/null && echo "$line" | grep -E "MANAGER|EXTRACT|REPLICAT" >/dev/null; then
            severity="WARNING"
        else
            continue
        fi

        if ! grep -q "$proc_key" "$ALERTS_FILE"; then
            now=$(date '+%Y-%m-%d %H:%M:%S')
            echo "$proc_key:$severity:$now" >> "$ALERTS_FILE"

            subject="[$severity] GoldenGate Alert: $process on $db@$HOSTNAME"
            body="<html>
            <b>Alert: $severity</b><br>
            <b>Database:</b> $db<br>
            <b>Host:</b> $HOSTNAME<br>
            <b>Process:</b> $process<br>
            <b>GoldenGate Home:</b> $ogg_home<br>
            <b>Time:</b> $now<br>
            </html>"

            send_email "$subject" "$body" "$contact"
        fi

        current_alert_keys+=("$proc_key")

    done <<< "$(echo "$output" | grep -E "MANAGER|EXTRACT|REPLICAT")"

done < "$CONFIG_FILE"

# Clear resolved alerts
temp_file=$(mktemp)
for line in $(awk -F":" '{print $1 ":" $2}' "$ALERTS_FILE"); do
    found=false
    for key in "${current_alert_keys[@]}"; do
        if [[ "$line" == "$key" ]]; then found=true; break; fi
    done
    if $found; then
        grep "$line" "$ALERTS_FILE" >> "$temp_file"
    fi
done
mv "$temp_file" "$ALERTS_FILE"

# Auto send summary at 4 PM
hour=$(date +%H)
if [[ "$hour" -eq 16 ]]; then
    send_summary
fi
