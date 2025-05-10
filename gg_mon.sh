import subprocess
import os
import socket
import re
import argparse

# Constants
CONFIG_FILE = "/opt/oracle/scripts/ogg_mon/ogg_config.txt"
STATE_DIR = "/opt/oracle/scripts/ogg_mon/state"
LAG_THRESHOLD_SECONDS = 300  # 5 minutes

def debug_print(debug, message):
    if debug:
        print(f"[DEBUG] {message}")

def read_config(debug):
    with open(CONFIG_FILE) as f:
        lines = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    debug_print(debug, f"Read config lines: {lines}")
    return [tuple(line.split("|")) for line in lines]

def run_ggsci(gg_home, command, debug):
    ggsci = f"{gg_home}/ggsci"
    full_cmd = f"echo '{command}' | {ggsci}"
    result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True)
    debug_print(debug, f"Running GGSCI Command: {full_cmd}\nOutput:\n{result.stdout}")
    return result.stdout

def time_str_to_seconds(time_str):
    try:
        h, m, s = map(int, time_str.strip().split(":"))
        return h * 3600 + m * 60 + s
    except:
        return 0

def parse_status_and_lag(gg_home, debug):
    output = run_ggsci(gg_home, "info all", debug)
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

    debug_print(debug, f"Parsed processes: {processes}")
    return processes

def send_email(to_email, subject, body, debug):
    mail_cmd = f'echo "{body}" | mailx -s "{subject}" {to_email}'
    debug_print(debug, f"Sending email with command: {mail_cmd}")
    subprocess.run(mail_cmd, shell=True)

def get_state_file_path(gg_home):
    safe_name = gg_home.replace("/", "_").strip("_")
    return os.path.join(STATE_DIR, f"{safe_name}.state")

def read_previous_state(gg_home, debug):
    path = get_state_file_path(gg_home)
    if os.path.exists(path):
        with open(path) as f:
            state = f.read().strip()
            debug_print(debug, f"Previous state for {gg_home}: {state}")
            return state
    debug_print(debug, f"First run detected for {gg_home} (no state file)")
    return None

def write_state(gg_home, status, debug):
    os.makedirs(STATE_DIR, exist_ok=True)
    path = get_state_file_path(gg_home)
    with open(path, "w") as f:
        f.write(status)
    debug_print(debug, f"Wrote state '{status}' to {path}")

def main():
    parser = argparse.ArgumentParser(description="GoldenGate Monitoring Script")
    parser.add_argument("--debug", action="store_true", help="Enable debug output")
    args = parser.parse_args()
    debug = args.debug

    host = socket.gethostname()
    configs = read_config(debug)

    for gg_home, db_name, email in configs:
        debug_print(debug, f"Checking GoldenGate at {gg_home} for {db_name}")
        processes = parse_status_and_lag(gg_home, debug)
        previous_state = read_previous_state(gg_home, debug)

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

        current_state = "ALERT" if alerts else "OK"

        if previous_state is None:
            debug_print(debug, f"First run: writing initial state '{current_state}' for {gg_home}")
            if alerts:
                body = (
                    f"ALERT: Issues detected on {db_name} @ {host}\n\n"
                    f"{header}\n{divider}\n" + "\n".join(alerts)
                )
                subject = f"GG ALERT: {db_name} on {host}"
                send_email(email, subject, body, debug)
            else:
                body = f"Initial check OK: All GoldenGate processes are healthy on {db_name} @ {host}."
                subject = f"GG OK (Initial): {db_name} on {host}"
                send_email(email, subject, body, debug)
            write_state(gg_home, current_state, debug)

        elif alerts and previous_state in ("OK", "UNKNOWN"):
            body = (
                f"ALERT: Issues detected on {db_name} @ {host}\n\n"
                f"{header}\n{divider}\n" + "\n".join(alerts)
            )
            subject = f"GG ALERT: {db_name} on {host}"
            send_email(email, subject, body, debug)
            write_state(gg_home, "ALERT", debug)

        elif not alerts and previous_state == "ALERT":
            body = f"CLEAR: All GoldenGate processes are healthy on {db_name} @ {host}."
            subject = f"GG CLEAR: {db_name} on {host}"
            send_email(email, subject, body, debug)
            write_state(gg_home, "OK", debug)

        else:
            debug_print(debug, f"No state change for {db_name}. Current: {current_state}, Previous: {previous_state}")

if __name__ == "__main__":
    main()
