import os
import subprocess
import re
import json
import socket
import shutil
import threading
import time
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)

# --- Configuration ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = "/etc/linuxptp/ptp4l.conf"
USER_PROFILES_FILE = os.path.join(BASE_DIR, "user_profiles.json")

# --- Built-in Profiles ---
BUILTIN_PROFILES = {
    "default": { "name": "Default (IEEE 1588)", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": 0, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3 },
    "aes67": { "name": "AES67 (Media)", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": -3, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3 },
    "st2059": { "name": "SMPTE ST 2059-2 (Broadcast)", "domain": 127, "priority1": 128, "priority2": 128, "logAnnounceInterval": -2, "logSyncInterval": -3, "logMinDelayReqInterval": -2, "announceReceiptTimeout": 3 }
}

def run_cmd_safe(cmd_list):
    """Execute command safely without shell injection risk."""
    try:
        result = subprocess.check_output(cmd_list, stderr=subprocess.STDOUT, timeout=1)
        return result.decode('utf-8', errors='ignore')
    except:
        return ""

def get_pmc_dict():
    """Query PTP status using PMC tool."""
    cmd = ["pmc", "-u", "-b", "0", "-d", "0", 
           "GET PORT_DATA_SET", "GET PARENT_DATA_SET", 
           "GET DEFAULT_DATA_SET", "GET CURRENT_DATA_SET"]
    output = run_cmd_safe(cmd)
    
    data = {}
    
    # Check Port State (Handle multiple ports for BC)
    states = re.findall(r'portState\s+(\w+)', output)
    if states:
        if 'SLAVE' in states:
            data['port_state'] = 'SLAVE'
        elif 'UNCALIBRATED' in states:
            data['port_state'] = 'UNCALIBRATED'
        elif all(s == 'MASTER' for s in states):
            data['port_state'] = 'MASTER'
        else:
            data['port_state'] = states[0]
    
    # Get GM ID
    m_gm = re.search(r'grandmasterIdentity\s+([0-9a-fA-F\.]+)', output)
    if m_gm:
        data['gm_id'] = m_gm.group(1)
    
    # Get Local Clock ID (for Self detection)
    m_clk = re.search(r'clockIdentity\s+([0-9a-fA-F\.]+)', output)
    if m_clk:
        data['clock_id'] = m_clk.group(1)
    
    # Get Offset
    m_off = re.search(r'offsetFromMaster\s+([0-9\.\-]+)', output)
    if m_off:
        data['offset'] = m_off.group(1)
    
    return data

def load_user_profiles():
    if os.path.exists(USER_PROFILES_FILE):
        try:
            with open(USER_PROFILES_FILE, 'r') as f:
                return json.load(f)
        except:
            return {}
    return {}

def save_user_profiles(profiles):
    with open(USER_PROFILES_FILE, 'w') as f:
        json.dump(profiles, f, indent=4)

def restart_ptp_async():
    """Restart PTP service in background to avoid blocking HTTP response."""
    def _restart():
        time.sleep(0.5)
        subprocess.run(["systemctl", "restart", "ptp4l"], check=False)
    threading.Thread(target=_restart).start()

def safe_int(val, default=0):
    try:
        return int(val)
    except:
        return default

# --- Routes ---

@app.route('/')
def index():
    nics = []
    try:
        nics = [n for n in os.listdir('/sys/class/net/') if not n.startswith('lo')]
    except:
        pass
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
    
    if os.path.exists(CONFIG_FILE):
        shutil.copy(CONFIG_FILE, CONFIG_FILE + ".bak")
    
    try:
        # 1. Global Config
        cfg = f"""[global]
network_transport       UDPv4
time_stamping           hardware
delay_mechanism         E2E
domainNumber            {safe_int(req.get('domain'))}
priority1               {safe_int(req.get('priority1'), 128)}
priority2               {safe_int(req.get('priority2'), 128)}
logAnnounceInterval     {safe_int(req.get('logAnnounceInterval'), 1)}
logSyncInterval         {safe_int(req.get('logSyncInterval'))}
logMinDelayReqInterval  {safe_int(req.get('logMinDelayReqInterval'))}
announceReceiptTimeout  {safe_int(req.get('announceReceiptTimeout'), 3)}
logging_level           6
use_syslog              1
verbose                 1
"""
        # BC Mode Flag
        if mode == 'BC':
            cfg += "boundary_clock_jbod 1\n\n"
        else:
            cfg += "\n"

        # 2. Interface Config
        if mode == 'BC':
            slave_if = req.get('bcSlaveIf')
            master_if = req.get('bcMasterIf')
            if not slave_if or not master_if:
                return jsonify({"status":"error", "message":"BC mode needs 2 interfaces"}), 400
            
            # Upstream (Slave-capable)
            cfg += f"[{slave_if}]\n\n"
            # Downstream (Master-forced)
            cfg += f"[{master_if}]\nmasterOnly 1\n"
        else:
            # OC Mode
            oc_if = req.get('interface')
            if not oc_if:
                return jsonify({"status":"error", "message":"Interface missing"}), 400
            cfg += f"[{oc_if}]\n"

        # 3. Write & Restart
        with open(CONFIG_FILE, 'w') as f:
            f.write(cfg)
        
        restart_ptp_async()
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/status')
def get_status():
    data = { 
        "ptp4l": "STOPPED", 
        "port": "Offline", 
        "offset": "0", 
        "gm": "Scanning...", 
        "is_self": False 
    }
    
    if run_cmd_safe(["pgrep", "-x", "ptp4l"]):
        data["ptp4l"] = "RUNNING"
        
    if data["ptp4l"] == "RUNNING":
        pmc = get_pmc_dict()
        if 'port_state' in pmc:
            data["port"] = pmc['port_state']
        if 'offset' in pmc:
            data["offset"] = pmc['offset']
        if 'gm_id' in pmc:
            data["gm"] = pmc['gm_id']
            # Self detection logic
            if 'clock_id' in pmc and pmc['gm_id'] == pmc['clock_id']:
                data["is_self"] = True
                data["gm"] += " (Self)"
        
        # If we are GM, offset is logically 0
        if data["port"] in ["MASTER", "GRAND_MASTER"]:
            data["offset"] = "0"
            data["is_self"] = True
    
    return jsonify(data)

@app.route('/api/logs')
def get_logs():
    return jsonify({"logs": run_cmd_safe(["journalctl", "-u", "ptp4l", "-n", "50", "--no-pager", "--output", "cat"])})

@app.route('/api/stop', methods=['POST'])
def stop_service():
    subprocess.run(["systemctl", "stop", "ptp4l"], check=False)
    return jsonify({"status": "success"})

if __name__ == '__main__':
    # For manual debugging
    app.run(host='0.0.0.0', port=5000)
