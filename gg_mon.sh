#!/bin/bash

CONFIG_FILE="/opt/oracle/scripts/gg_monitoring/ogg_homes.txt"
EMAIL_RECIPIENT="abc@abc.com"
HOSTNAME=$(hostname)

send_email() {
    subject="$1"
    body="$2"
    (
        echo "Subject: $subject"
        echo "Content-Type: text/html"
        echo
        echo "$body"
    ) | /usr/sbin/sendmail "$EMAIL_RECIPIENT"
}

send_summary() {
    date_today=$(date '+%Y-%m-%d')

    html="<html><b>GoldenGate Monitoring Summary - $date_today</b><br><br>
    <table border=1 cellpadding=4 cellspacing=0>
    <tr>
        <th>GoldenGate Home</th>
        <th>Database</th>
        <th>Total Processes</th>
        <th>Running</th>
        <th>Stopped</th>
        <th>Abended</th>
    </tr>"

    while read -r ogg_home contact db; do
        if [[ -z "$ogg_home" || -z "$contact" || -z "$db" ]]; then continue; fi

        cd "$ogg_home" || continue
        output=$(echo "info all" | ./ggsci 2>/dev/null)

        total=0
        running=0
        stopped=0
        abended=0

        while read -r line; do
            proc_type=$(echo "$line" | awk '{print $1}')
            proc_name=$(echo "$line" | awk '{print $2}')
            proc_status=$(echo "$line" | awk '{print $3}')

            if [[ "$proc_type" =~ (MANAGER|EXTRACT|REPLICAT) ]]; then
                total=$((total+1))
                case "$proc_status" in
                    RUNNING) running=$((running+1)) ;;
                    STOPPED) stopped=$((stopped+1)) ;;
                    ABENDED) abended=$((abended+1)) ;;
                    *) ;;
                esac
            fi
        done <<< "$(echo "$output" | grep -E 'MANAGER|EXTRACT|REPLICAT')"

        html+="<tr>
            <td>$ogg_home</td>
            <td>$db</td>
            <td>$total</td>
            <td>$running</td>
            <td>$stopped</td>
            <td>$abended</td>
        </tr>"

    done < "$CONFIG_FILE"

    html+="</table></html>"

    send_email "GoldenGate Summary - $date_today" "$html"
}

# If 'summary' passed → only send summary
if [[ "$1" == "summary" ]]; then
    send_summary
    exit 0
fi

# --- normal monitoring logic here (same as before or empty if skipped) ---

# Auto summary at 4 PM
hour=$(date +%H)
if [[ "$hour" -eq 16 ]]; then
    send_summary
fi
