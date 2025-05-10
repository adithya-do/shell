import subprocess
import os
import socket
import re

# Constants
CONFIG_FILE = "/opt/oracle/scripts/ogg_mon/ogg_config.txt"
STATE_DIR = "/opt/oracle/scripts/ogg_mon/state"
LAG_THRESHOLD_SECONDS = 300  # 5 minutes

def read_config():
    with open(CONFIG_FILE) as f:
        lines = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    return [tuple(line.split("|")) for line in lines]

def run_ggsci(gg_home, command):
    ggsci = f"{gg_home}/ggsci"
    full_cmd = f"echo '{command}' | {ggsci}"
    result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True)
    return result.stdout

def time_str_to_seconds(time_str):
    try:
        h, m, s = map(int, time_str.strip().split(":"))
        return h * 3600 + m * 60 + s
    except:
        return 0

def parse_status_and_lag(gg_home):
    output = run_ggsci(gg_home, "info all")
    processes = {}

    for line in output.splitlines():
        line = line.strip()
        if line.startswith(("EXTRACT", "REPLICAT")):
            parts = line.split()
            if len(parts) < 6:
                continue

            proc_type = parts[0]
            name = parts[1]
            status = parts[2]
            lag = parts[-2]
            time_since = parts[-1]

            key = f"{proc_type} {name}"
            processes[key] = {
                "status": status,
                "lag": lag,
                "time_since": time_since
            }

    return processes

def send_email(to_email, subject, body):
    mail_cmd = f'echo "{body}" | mailx -s "{subject}" {to_email}'
    subprocess.run(mail_cmd, shell=True)

def get_state_file_path(gg_home):
    os.makedirs(STATE_DIR, exist_ok=True)
    safe_name = gg_home.replace("/", "_").strip("_")
    return os.path.join(STATE_DIR, f"{safe_name}.state")

def read_previous_state(gg_home):
    path = get_state_file_path(gg_home)
    if os.path.exists(path):
        with open(path) as f:
            return f.read().strip()
    return "OK"

def write_state(gg_home, status):
    path = get_state_file_path(gg_home)
    with open(path, "w") as f:
        f.write(status)

def main():
    host = socket.gethostname()
    configs = read_config()

    for gg_home, db_name, email in configs:
        print(f"Checking GoldenGate at {gg_home} for {db_name}")
        processes = parse_status_and_lag(gg_home)
        previous_state = read_previous_state(gg_home)

        alerts = []
        header = "Program     Status   Group    Lag at Chkpt    Time Since Chkpt"
        divider = "-" * len(header)

        for proc, info in processes.items():
            proc_type, name = proc.split()
            status = info.get("status", "UNKNOWN")
            lag = info.get("lag", "N/A")
            since = info.get("time_since", "N/A")

            lag_secs = time_str_to_seconds(since)
            if status != "RUNNING" or lag_secs > LAG_THRESHOLD_SECONDS:
                alerts.append(f"{proc_type:<11}{status:<9}{name:<8}{lag:<16}{since:<}")

        if alerts and previous_state == "OK":
            body = (
                f"ALERT: Issues detected on {db_name} @ {host}\n\n"
                f"{header}\n{divider}\n" + "\n".join(alerts)
            )
            subject = f"GG ALERT: {db_name} on {host}"
            send_email(email, subject, body)
            write_state(gg_home, "ALERT")

        elif not alerts and previous_state == "ALERT":
            body = f"CLEAR: All GoldenGate processes are healthy on {db_name} @ {host}."
            subject = f"GG CLEAR: {db_name} on {host}"
            send_email(email, subject, body)
            write_state(gg_home, "OK")

        else:
            print(f"No state change for {db_name}.")

if __name__ == "__main__":
    main()
