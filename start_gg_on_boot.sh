#!/bin/bash

CONF_FILE="/opt/oracle/scripts/ogg_mon/ogg.conf"
TMP_HTML="/tmp/ogg_startup_report.html"
TMP_MAIL="/tmp/ogg_mail_body.txt"
HOSTNAME=$(hostname)
MAIL_SUBJECT="[$HOSTNAME] GoldenGate Auto Start Summary"
MAIL_FROM="ogg-monitor@$HOSTNAME"

# Collect unique recipients
declare -A RECIPIENTS

# Start HTML email body
cat <<EOF > "$TMP_HTML"
<html>
<head>
  <style>
    body { font-family: Arial, sans-serif; }
    table { border-collapse: collapse; width: 90%; }
    th, td { border: 1px solid #999; padding: 8px; text-align: left; }
    th { background-color: #eee; }
    .ok { color: green; }
    .fail { color: red; font-weight: bold; }
  </style>
</head>
<body>
<h2>GoldenGate Auto Start Summary - $HOSTNAME</h2>
<table>
<tr>
  <th>DB Name</th>
  <th>Manager</th>
  <th>Process Status</th>
</tr>
EOF

# Process config file
while IFS="|" read -r GG_HOME DB_NAME EMAIL START_PROCESS; do
  [[ "$GG_HOME" =~ ^#.*$ || -z "$GG_HOME" ]] && continue
  [[ "$START_PROCESS" != "YES" ]] && continue

  RECIPIENTS["$EMAIL"]=1

  if [ ! -x "$GG_HOME/ggsci" ]; then
    echo "<tr><td>$DB_NAME</td><td class='fail'>Error</td><td class='fail'>GGSCI Not Found</td></tr>" >> "$TMP_HTML"
    continue
  fi

  # Start manager
  echo "start mgr" | "$GG_HOME/ggsci" > /dev/null

  # Start all extract/replicat processes
  echo "start *" | "$GG_HOME/ggsci" > /dev/null

  # Get updated status
  INFO_ALL=$("$GG_HOME/ggsci" <<EOF
info all
EOF
)

  # Check if Manager is running
  if echo "$INFO_ALL" | awk '$1 == "MANAGER" && $2 == "RUNNING"' | grep -q "MANAGER"; then
    MANAGER_STATUS="<td class='ok'>Running</td>"
  else
    echo "<tr><td>$DB_NAME</td><td class='fail'>Down</td><td class='fail'>Not All Started</td></tr>" >> "$TMP_HTML"
    continue
  fi

  # Check if all processes are running
  ALL_STARTED=true

  # Check if any process is STOPPED or ABENDED
if echo "$INFO_ALL" | awk 'NR > 2 && ($1 == "EXTRACT" || $1 == "REPLICAT")' | grep -E 'STOPPED|ABENDED' > /dev/null; then
  PROCESS_STATUS="<td class='fail'>Not All Started</td>"
else
  PROCESS_STATUS="<td class='ok'>All Started</td>"
fi


  # Determine status
  if $ALL_STARTED; then
    PROCESS_STATUS="<td class='ok'>All Started</td>"
  else
    PROCESS_STATUS="<td class='fail'>Not All Started</td>"
  fi

  echo "<tr><td>$DB_NAME</td>$MANAGER_STATUS$PROCESS_STATUS</tr>" >> "$TMP_HTML"

done < "$CONF_FILE"

# Close HTML
echo "</table></body></html>" >> "$TMP_HTML"

# Send email to all recipients
TO_LIST=$(IFS=','; echo "${!RECIPIENTS[*]}")
{
  echo "To: $TO_LIST"
  echo "Subject: $MAIL_SUBJECT"
  echo "MIME-Version: 1.0"
  echo "Content-Type: text/html"
  echo "From: $MAIL_FROM"
  echo ""
  cat "$TMP_HTML"
} > "$TMP_MAIL"
/usr/sbin/sendmail -t < "$TMP_MAIL"

# Cleanup
rm -f "$TMP_HTML" "$TMP_MAIL"
