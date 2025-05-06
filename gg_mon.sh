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

parse_lag_seconds() {
    lag_str="$1"
    IFS=':' read -r h m s <<< "$lag_str"
    [[ -z "$s" ]] && s=0
    [[ -z "$m" ]] && m=0
    [[ -z "$h" ]] && h=0
    echo $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

send_summary() {
    date_today=$(date '+%Y-%m-%d')
    html="<html><b>GoldenGate Monitoring Summary - $date_today (Host: $HOSTNAME)</b><br><br>
    <table border=1 cellpadding=4 cellspacing=0>
    <tr>
        <th>GoldenGate Home</th>
        <th>Database</th>
        <th>Total Processes</th>
        <th>Running</th>
        <th>Stopped</th>
        <th>Abended</th>
        <th>Lag &gt;30 min</th>
    </tr>"

    while read -r ogg_home contact db; do
        [[ -z "$ogg_home" || -z "$db" ]] && continue

        cd "$ogg_home" || continue
        output=$(echo "info all" | ./ggsci 2>/dev/null)

        total=0
        running=0
        stopped=0
        abended=0
        lagover=0

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

                if [[ "$proc_type" == "EXTRACT" || "$proc_type" == "REPLICAT" ]]; then
                    lag_output=$(echo "lag $proc_name" | ./ggsci 2>/dev/null | grep "Lag at")
                    lag_time=$(echo "$lag_output" | sed -n 's/.*Lag at Chkpt //p' | awk '{print $1}')
                    
                    if [[ -n "$lag_time" ]]; then
                        lag_sec=$(parse_lag_seconds "$lag_time")
                        if [[ $lag_sec -gt 1800 ]]; then
                            lagover=$((lagover+1))
                        fi
                    fi
                fi
            fi
        done <<< "$(echo "$output" | grep -E 'MANAGER|EXTRACT|REPLICAT')"

        html+="<tr>
            <td>$ogg_home</td>
            <td>$db</td>
            <td>$total</td>
            <td>$running</td>
            <td>$stopped</td>
            <td>$abended</td>
            <td>$lagover</td>
        </tr>"
    done < "$CONFIG_FILE"

    html+="</table></html>"

    send_email "GoldenGate Summary - $date_today" "$html"
}

send_summary
