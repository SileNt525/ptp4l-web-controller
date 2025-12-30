import os
import subprocess
import re
import json
import socket
import shutil
import threading
import time
from datetime import datetime
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)

# --- Configuration ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = "/etc/linuxptp/ptp4l.conf"
PHC2SYS_SERVICE_FILE = "/etc/systemd/system/phc2sys-custom.service"
# Fix: Ensure this path is valid, we will auto-create the dir if missing
SAFE_WRAPPER_SCRIPT = "/usr/local/bin/ptp-safe-wrapper.sh"
USER_PROFILES_FILE = os.path.join(BASE_DIR, "user_profiles.json")

# --- Built-in Profiles ---
BUILTIN_PROFILES = {
    "default": { "name": "Default (IEEE 1588)", "timeStamping": "hardware", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": 0, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3, "syncSystem": False, "logLevel": 6 },
    "aes67": { "name": "AES67 (Media)", "timeStamping": "hardware", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": -3, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3, "syncSystem": True, "logLevel": 6 },
    "st2059": { "name": "SMPTE ST 2059-2 (Broadcast)", "timeStamping": "hardware", "domain": 127, "priority1": 128, "priority2": 128, "logAnnounceInterval": -2, "logSyncInterval": -3, "logMinDelayReqInterval": -2, "announceReceiptTimeout": 3, "syncSystem": True, "logLevel": 6 }
}

def run_cmd_safe(cmd_list):
    """Execute command safely without shell injection risk."""
    try:
        env = os.environ.copy()
        env['LANG'] = 'C'
        result = subprocess.check_output(cmd_list, stderr=subprocess.STDOUT, timeout=2, env=env)
        return result.decode('utf-8', errors='ignore')
    except:
        return ""

def get_current_interface():
    """Extract active interface from config file."""
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, 'r') as f:
                for line in f:
                    # Match [eth0] but exclude [global]
                    m = re.match(r'^\[([^\]]+)\]', line.strip())
                    if m and m.group(1) != 'global':
                        return m.group(1)
    except: pass
    return None

def get_ptp_time(interface):
    """Directly query the PTP Hardware Clock time."""
    if not interface: return None
    try:
        # 1. Get PTP Device ID (e.g. 0 for /dev/ptp0)
        # Add /usr/sbin to path just in case
        ethtool_out = run_cmd_safe(["ethtool", "-T", interface])
        
        # FIX: Regex updated to support both old "PTP Hardware Clock" and new "Hardware timestamp provider index"
        m = re.search(r'(?:PTP Hardware Clock|Hardware timestamp provider index):\s+(\d+)', ethtool_out)
        
        if not m: return None
        ptp_dev = f"/dev/ptp{m.group(1)}"
        
        # 2. Get Time using phc_ctl
        out = run_cmd_safe(["phc_ctl", ptp_dev, "get"])
        m_ts = re.search(r'clock time is (\d+)\.', out)
        if m_ts:
            ts = int(m_ts.group(1))
            return datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S')
    except: pass
    return None

def get_pmc_dict():
    """Revised Expert-level PTP status query."""
    cmd = ["pmc", "-u", "-b", "0", "-d", "0", 
           "GET CURRENT_DATA_SET", 
           "GET PORT_DATA_SET", 
           "GET TIME_STATUS_NP",
           "GET PARENT_DATA_SET"]
    
    output = run_cmd_safe(cmd)
    
    data = {
        "port_state": "UNKNOWN",
        "offset": 0,
        "path_delay": 0,
        "steps_removed": -1,
        "gm_id": "Unknown",
        "gm_present": False,
        "clock_id": "",
        "phc2sys_state": "STOPPED"
    }

    m_delay = re.search(r'meanPathDelay\s+([\d\.\-eE]+)', output)
    if m_delay:
        try: data['path_delay'] = float(m_delay.group(1))
        except: data['path_delay'] = 0

    m_steps = re.search(r'stepsRemoved\s+(\d+)', output)
    if m_steps:
        try: data['steps_removed'] = int(m_steps.group(1))
        except: pass

    m_off = re.search(r'offsetFromMaster\s+([\d\.\-eE]+)', output)
    if m_off:
        try: data['offset'] = float(m_off.group(1))
        except: data['offset'] = 0

    m_gm = re.search(r'grandmasterIdentity\s+([0-9a-fA-F\.]+)', output)
    if m_gm: data['gm_id'] = m_gm.group(1)
        
    m_clk = re.search(r'clockIdentity\s+([0-9a-fA-F\.]+)', output)
    if not m_clk: m_clk = re.search(r'^([0-9a-fA-F\.]+).*RESPONSE', output, re.MULTILINE)
    if m_clk: data['clock_id'] = m_clk.group(1)

    states = re.findall(r'portState\s+(\w+)', output)
    if states:
        if 'SLAVE' in states: data['port_state'] = 'SLAVE'
        elif all(s == 'MASTER' for s in states): data['port_state'] = 'MASTER'
        elif 'UNCALIBRATED' in states: data['port_state'] = 'UNCALIBRATED'
        elif all(s == 'LISTENING' for s in states): data['port_state'] = 'LISTENING'
        else: data['port_state'] = states[0]

    m_gmp = re.search(r'gmPresent\s+(\w+)', output)
    if m_gmp: data['gm_present'] = (m_gmp.group(1).lower() == 'true')

    if run_cmd_safe(["pgrep", "-f", "phc2sys"]):
        data["phc2sys_state"] = "RUNNING"

    return data

def load_user_profiles():
    if os.path.exists(USER_PROFILES_FILE):
        try:
            with open(USER_PROFILES_FILE, 'r') as f: return json.load(f)
        except: return {}
    return {}

def save_user_profiles(profiles):
    with open(USER_PROFILES_FILE, 'w') as f:
        json.dump(profiles, f, indent=4)

def create_safe_wrapper_script():
    """Create a wrapper script that checks year > 2023 before syncing."""
    
    # 1. Fix: Ensure directory exists
    script_dir = os.path.dirname(SAFE_WRAPPER_SCRIPT)
    if not os.path.exists(script_dir):
        try:
            os.makedirs(script_dir, exist_ok=True)
        except:
            pass 

    # 2. Fix: Use standard escaping for backslashes to avoid SyntaxWarning
    # In Python strings, backslashes for regex/shell must be doubled: \\
    # Example: To output '\(' in shell, we write '\\(' in Python string.
    
    script_content = f"""#!/bin/bash
export PATH=$PATH:/usr/sbin:/usr/bin:/sbin:/bin

INTERFACE=$1
shift
ARGS="$@"

# --- 1. Robust PTP Device Discovery ---
# Works for "PTP Hardware Clock: 0" and "Hardware timestamp provider index: 0"
# We use grep to find the line, then sed to strip everything before the colon and space.
PTP_DEV_ID=$(ethtool -T $INTERFACE 2>/dev/null | grep -E "(Clock|index):" | sed 's/.*: //')

if [ -z "$PTP_DEV_ID" ]; then
    echo "❌ Error: No PTP hardware clock found for $INTERFACE"
    echo "--- Debug: ethtool output ---"
    ethtool -T $INTERFACE
    exit 1
fi

PTP_DEV="/dev/ptp$PTP_DEV_ID"

if [ ! -e "$PTP_DEV" ]; then
    echo "❌ Error: Device node $PTP_DEV does not exist!"
    exit 1
fi

# --- 2. Sanity Check (Year > 2023) ---
# Get seconds from PTP clock using phc_ctl
# FIX: All backslashes below are doubled for Python syntax safety
PTP_SECONDS=$(phc_ctl $PTP_DEV get 2>/dev/null | sed -n 's/.*clock time is \\([0-9]\\+\\)\\..*/\\1/p')

# Threshold: 1700000000 (Year ~2023)
if [ -z "$PTP_SECONDS" ] || [ "$PTP_SECONDS" -lt 1700000000 ]; then
    echo "⚠️ DANGER: PTP time on $INTERFACE is < Year 2023."
    echo "    Aborting system clock sync to protect SSL/TLS state."
    exit 1
fi

echo "✅ PTP time is valid (>2023). Device: $PTP_DEV. Starting phc2sys..."
exec /usr/sbin/phc2sys -s $INTERFACE -c CLOCK_REALTIME -w -O 0
"""
    with open(SAFE_WRAPPER_SCRIPT, 'w') as f:
        f.write(script_content)
    os.chmod(SAFE_WRAPPER_SCRIPT, 0o755)

def create_phc2sys_service(interface, mode):
    """Create systemd service using the safe wrapper."""
    create_safe_wrapper_script()
    
    service_content = f"""[Unit]
Description=Safe System Clock Sync (phc2sys)
After=ptp4l.service
Requires=ptp4l.service

[Service]
Type=simple
ExecStart={SAFE_WRAPPER_SCRIPT} {interface}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""
    with open(PHC2SYS_SERVICE_FILE, 'w') as f:
        f.write(service_content)
    
    subprocess.run(["systemctl", "daemon-reload"], check=False)

def restart_services_async(enable_phc2sys):
    def _restart():
        time.sleep(0.5)
        subprocess.run(["systemctl", "restart", "ptp4l"], check=False)
        if enable_phc2sys:
            subprocess.run(["systemctl", "enable", "--now", "phc2sys-custom"], check=False)
            subprocess.run(["systemctl", "restart", "phc2sys-custom"], check=False)
        else:
            subprocess.run(["systemctl", "stop", "phc2sys-custom"], check=False)
            subprocess.run(["systemctl", "disable", "phc2sys-custom"], check=False)
    threading.Thread(target=_restart).start()

def safe_int(val, default=0):
    try: return int(val)
    except: return default

# --- Routes ---

@app.route('/')
def index():
    nics = []
    try:
        nics = [n for n in os.listdir('/sys/class/net/') if not n.startswith('lo')]
        nics.sort()
    except: pass
    return render_template('index.html', nics=nics, hostname=socket.gethostname())

@app.route('/api/profiles', methods=['GET', 'POST'])
def handle_profiles():
    if request.method == 'GET':
        user_profiles = load_user_profiles()
        combined = {k: {**v, 'is_builtin': True, 'id': k} for k, v in BUILTIN_PROFILES.items()}
        for k, v in user_profiles.items():
            combined[k] = {**v, 'is_builtin': False, 'id': k}
        return jsonify(combined)
    
    req = request.json
    name = req.get('name', 'Untitled')
    pid = "user_" + re.sub(r'\W+', '_', name).lower()
    profiles = load_user_profiles()
    profiles[pid] = req['config']
    profiles[pid]['name'] = name
    save_user_profiles(profiles)
    return jsonify({"status": "success", "id": pid})

@app.route('/api/profiles/<pid>', methods=['DELETE'])
def delete_profile(pid):
    profiles = load_user_profiles()
    if pid in profiles:
        del profiles[pid]
        save_user_profiles(profiles)
        return jsonify({"status": "success"})
    return jsonify({"status": "error"}), 404

@app.route('/api/apply', methods=['POST'])
def apply_config():
    req = request.json
    mode = req.get('clockMode', 'OC')
    ts_mode = req.get('timeStamping', 'hardware')
    sync_system = req.get('syncSystem', False)
    log_level = safe_int(req.get('logLevel'), 6)

    if ts_mode not in ['hardware', 'software', 'legacy', 'onestep']: ts_mode = 'hardware'
    if os.path.exists(CONFIG_FILE): shutil.copy(CONFIG_FILE, CONFIG_FILE + ".bak")
    
    try:
        cfg = f"""[global]
network_transport       UDPv4
time_stamping           {ts_mode}
delay_mechanism         E2E
domainNumber            {safe_int(req.get('domain'))}
priority1               {safe_int(req.get('priority1'), 128)}
priority2               {safe_int(req.get('priority2'), 128)}
logAnnounceInterval     {safe_int(req.get('logAnnounceInterval'), 1)}
logSyncInterval         {safe_int(req.get('logSyncInterval'))}
logMinDelayReqInterval  {safe_int(req.get('logMinDelayReqInterval'))}
announceReceiptTimeout  {safe_int(req.get('announceReceiptTimeout'), 3)}
logging_level           {log_level}
use_syslog              1
verbose                 1
"""
        target_if = ""
        if mode == 'BC':
            cfg += "boundary_clock_jbod 1\n\n"
            slave_if = req.get('bcSlaveIf')
            master_if = req.get('bcMasterIf')
            if not slave_if or not master_if:
                return jsonify({"status":"error", "message":"BC mode needs 2 interfaces"}), 400
            cfg += f"[{slave_if}]\n\n[{master_if}]\nserverOnly 1\n"
            target_if = slave_if 
        else:
            cfg += "\n"
            target_if = req.get('interface')
            if not target_if:
                return jsonify({"status":"error", "message":"Interface missing"}), 400
            cfg += f"[{target_if}]\n"

        with open(CONFIG_FILE, 'w') as f: f.write(cfg)

        if sync_system and target_if:
            create_phc2sys_service(target_if, mode)

        restart_services_async(sync_system)
        
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/status')
def get_status():
    data = { 
        "ptp4l": "STOPPED", 
        "phc2sys": "STOPPED",
        "port": "Offline", 
        "offset": 0, 
        "path_delay": 0,
        "steps_removed": -1,
        "gm": "Scanning...", 
        "ptp_time": "--",
        "is_self": False 
    }
    
    iface = get_current_interface()
    if iface:
        t = get_ptp_time(iface)
        if t: data["ptp_time"] = t

    if run_cmd_safe(["pgrep", "-x", "ptp4l"]):
        data["ptp4l"] = "RUNNING"
        
    if data["ptp4l"] == "RUNNING":
        pmc = get_pmc_dict()
        if 'port_state' in pmc: data["port"] = pmc['port_state']
        if 'offset' in pmc: data["offset"] = pmc['offset']
        if 'path_delay' in pmc: data["path_delay"] = pmc['path_delay']
        if 'steps_removed' in pmc: data["steps_removed"] = pmc['steps_removed']
        if 'phc2sys_state' in pmc: data["phc2sys"] = pmc['phc2sys_state']
        
        if 'gm_id' in pmc:
            data["gm"] = pmc['gm_id']
            if 'clock_id' in pmc and pmc['gm_id'] == pmc['clock_id']:
                data["is_self"] = True
                data["gm"] += " (Self)"
        
        if data["port"] in ["MASTER", "GRAND_MASTER"]:
            data["offset"] = 0
            data["path_delay"] = 0
            data["steps_removed"] = 0
            data["is_self"] = True
    
    return jsonify(data)

@app.route('/api/logs')
def get_logs():
    return jsonify({"logs": run_cmd_safe(["journalctl", "-u", "ptp4l", "-u", "phc2sys-custom", "-n", "50", "--no-pager", "--output", "cat"])})

@app.route('/api/stop', methods=['POST'])
def stop_service():
    subprocess.run(["systemctl", "stop", "ptp4l"], check=False)
    subprocess.run(["systemctl", "stop", "phc2sys-custom"], check=False)
    return jsonify({"status": "success"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
