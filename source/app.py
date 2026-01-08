import os
import subprocess
import re
import json
import socket
import shutil
import threading
import time
import atexit
from datetime import datetime
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)

# --- Configuration ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = "/etc/linuxptp/ptp4l.conf"
PHC2SYS_SERVICE_FILE = "/etc/systemd/system/phc2sys-custom.service"
SAFE_WRAPPER_SCRIPT = "/usr/local/bin/ptp-safe-wrapper.sh"
INJECT_SCRIPT = "/usr/local/bin/ptp-inject"
USER_PROFILES_FILE = os.path.join(BASE_DIR, "user_profiles.json")

# Global Cache
STATUS_CACHE = { "time": 0, "data": None }

# --- Client Monitoring Globals ---
MONITOR_CONFIG = { "mode": "disabled", "interfaces": [] }
CLIENTS = {} # { ip: { mac: str, last_seen: float } }
CLIENTS_LOCK = threading.Lock()

# --- Cleanup on Exit ---
def cleanup_subprocesses():
    # 退出时强制清理 tcpdump，防止僵尸进程
    os.system("pkill -f 'tcpdump -i .* dst port 319'")

atexit.register(cleanup_subprocesses)

# --- Built-in Profiles ---
BUILTIN_PROFILES = {
    "default": { "name": "Default (IEEE 1588)", "timeStamping": "hardware", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": 0, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3, "syncMode": "none", "logLevel": 6 },
    "aes67": { "name": "AES67 (Media)", "timeStamping": "hardware", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": -3, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3, "syncMode": "slave", "logLevel": 6 },
    "st2059": { "name": "SMPTE ST 2059-2 (Broadcast)", "timeStamping": "hardware", "domain": 127, "priority1": 128, "priority2": 128, "logAnnounceInterval": -2, "logSyncInterval": -3, "logMinDelayReqInterval": -2, "announceReceiptTimeout": 3, "syncMode": "slave", "logLevel": 6 }
}

def run_cmd_safe(cmd_list):
    try:
        env = os.environ.copy()
        env['LANG'] = 'C'
        # Reduced timeout to prevent long blocking
        result = subprocess.check_output(cmd_list, stderr=subprocess.STDOUT, timeout=1.5, env=env)
        return result.decode('utf-8', errors='ignore')
    except:
        return ""

def validate_interface(iface):
    if not iface: return False
    try:
        valid_nics = os.listdir('/sys/class/net/')
        return iface in valid_nics
    except:
        return False

# --- Monitor Logic (Multi-Interface) ---
def get_ip_address(iface):
    try:
        out = subprocess.check_output(["ip", "-4", "addr", "show", iface], text=True)
        m = re.search(r'inet\s+(\d+\.\d+\.\d+\.\d+)', out)
        return m.group(1) if m else None
    except: return None

def monitor_worker(iface):
    global CLIENTS
    proc = None
    my_ip = get_ip_address(iface)
    
    while True:
        # Check global config (simple polling)
        if MONITOR_CONFIG["mode"] == "disabled" or iface not in MONITOR_CONFIG["interfaces"]:
            if proc:
                try: proc.terminate(); proc.wait()
                except: pass
                proc = None
            time.sleep(1)
            # If interface was removed from config, exit this worker
            if iface not in MONITOR_CONFIG["interfaces"]: return
            continue

        if not proc or proc.poll() is not None:
            # Capture both Sync/FollowUp and DelayReq to see EVERYONE (GM + Clients)
            cmd = ["tcpdump", "-i", iface, "-nn", "-l", "-e", "dst port 319"]
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
            except:
                time.sleep(5)
                continue

        try:
            line = proc.stdout.readline()
            if not line:
                time.sleep(0.1)
                continue
            
            # Simple interaction update
            current_time = time.time()
            # Regex: SourceMAC > ... SourceIP.319 >
            # Note: tcpdump format varies slightly by version, but usually:
            # HH:MM:SS.us MAC1 > MAC2, ethertype IPv4 (0x0800), length 76: 192.168.1.55.319 > 224.0.1.129.319: UDP, length 44
            # We want source IP.
            m = re.search(r'([0-9a-fA-F:]{17}) > .*? (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\.319 >', line)
            
            # If standard regex failed, try alternative format (sometimes source port is not 319)
            # e.g. 192.168.1.55.56789 > 224.0.1.129.319
            if not m:
                m = re.search(r'([0-9a-fA-F:]{17}) > .*? (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\.(\d+) > .*?\.319', line)

            if m:
                mac = m.group(1)
                ip = m.group(2)
                # Filter out our own MAC/IP if possible? (Hard without netifaces)
                # But seeing "Self" in radar is sometimes useful debugging.
                is_self = (ip == my_ip)
                with CLIENTS_LOCK:
                    # Append interface name to info for UI
                    CLIENTS[ip] = { "mac": mac, "last_seen": current_time, "iface": iface, "is_self": is_self }       
        except:
            time.sleep(1)

def monitor_manager_thread():
    # Spawns workers for interfaces in MONITOR_CONFIG
    active_workers = {} # iface -> thread
    while True:
        target_ifaces = MONITOR_CONFIG.get("interfaces", [])
        mode = MONITOR_CONFIG.get("mode", "disabled")
        
        if mode == "disabled":
             target_ifaces = []

        # Start new workers
        for iface in target_ifaces:
                if iface not in active_workers or not active_workers[iface].is_alive():
                    # Refresh IP in case it changed
                    t = threading.Thread(target=monitor_worker, args=(iface,), daemon=True)
                    t.start()
                    active_workers[iface] = t
        
        # Prune old workers (logic handled inside worker loop checking config)
        time.sleep(2)

# Start Manager
threading.Thread(target=monitor_manager_thread, daemon=True).start()

def cleanup_thread():
    while True:
        time.sleep(5)
        now = time.time()
        with CLIENTS_LOCK:
            to_remove = [ip for ip, d in CLIENTS.items() if now - d['last_seen'] > 120]
            for ip in to_remove:
                del CLIENTS[ip]


threading.Thread(target=cleanup_thread, daemon=True).start()

def get_current_interface():
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, 'r') as f:
                for line in f:
                    m = re.match(r'^\[([^\]]+)\]', line.strip())
                    if m and m.group(1) != 'global':
                        return m.group(1)
    except: pass
    return None

def get_ptp_time(interface):
    if not interface: return None
    try:
        ethtool_out = run_cmd_safe(["ethtool", "-T", interface])
        m = re.search(r'(?:PTP Hardware Clock|Hardware timestamp provider index):\s+(\d+)', ethtool_out)
        if not m: return None
        ptp_dev = f"/dev/ptp{m.group(1)}"
        out = run_cmd_safe(["phc_ctl", ptp_dev, "get"])
        m_ts = re.search(r'clock time is (\d+)\.', out)
        if m_ts:
            ts = int(m_ts.group(1))
            return datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S')
    except: pass
    return None

def get_pmc_dict():
    cmd = ["pmc", "-u", "-b", "0", 
           "GET CURRENT_DATA_SET", 
           "GET PORT_DATA_SET", 
           "GET TIME_STATUS_NP", 
           "GET PARENT_DATA_SET"]
    output = run_cmd_safe(cmd)
    data = { "port_state": "UNKNOWN", "offset": 0, "path_delay": 0, "steps_removed": -1, "gm_id": "Unknown", "gm_present": False, "clock_id": "", "phc2sys_state": "STOPPED" }

    m_delay = re.search(r'meanPathDelay\s+([\d\.\-eE]+)', output)
    if m_delay: 
        try: data['path_delay'] = float(m_delay.group(1))
        except: pass

    m_steps = re.search(r'stepsRemoved\s+(\d+)', output)
    if m_steps: 
        try: data['steps_removed'] = int(m_steps.group(1))
        except: pass

    m_off = re.search(r'offsetFromMaster\s+([\d\.\-eE]+)', output)
    if m_off: 
        try: data['offset'] = float(m_off.group(1))
        except: pass

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
        else: data['port_state'] = states[0]

    if run_cmd_safe(["pgrep", "-f", "phc2sys"]): data["phc2sys_state"] = "RUNNING"
    return data

def get_bmca_info():
    # Helper to parse hex/int
    def p_val(txt, key, type_func=lambda x: int(x, 0)):
        # Match "key value"
        m = re.search(f'{key}\\s+([\\w\\d\\.\\-]+)', txt)
        if not m: return None
        try: return type_func(m.group(1))
        except: return None

    # 1. Get ALL Data in one go (More efficient)
    cmd = ["pmc", "-u", "-b", "0", "GET DEFAULT_DATA_SET", "GET PARENT_DATA_SET", "GET TIME_PROPERTIES_DATA_SET"]
    out_all = run_cmd_safe(cmd)
    
    # Check if we got valid output
    if "RESPONSE" not in out_all:
        return { "local": {}, "gm": {}, "flags": {}, "decision": [], "winner": "unknown", "error": "No PTP response" }

    local = {
        "priority1": p_val(out_all, "priority1"),
        "class": p_val(out_all, "clockClass"),
        "accuracy": p_val(out_all, "clockAccuracy"), 
        "variance": p_val(out_all, "offsetScaledLogVariance"),
        "priority2": p_val(out_all, "priority2"),
        "id": "", 
    }
    # Local ID usually appears under generic clockIdentity or PTP port identity
    # In bundled output, we need to be careful. GET DEFAULT_DATA_SET response usually has clockIdentity.
    # We'll look for the first clockIdentity which is usually local.
    m_id = re.search(r'clockIdentity\s+([0-9a-fA-F\.]+)', out_all)
    if m_id: local["id"] = m_id.group(1)

    gm = {
        "priority1": p_val(out_all, "grandmasterPriority1"),
        "class": p_val(out_all, "grandmasterClockQuality.clockClass"),
        "accuracy": p_val(out_all, "grandmasterClockQuality.clockAccuracy"),
        "variance": p_val(out_all, "grandmasterClockQuality.offsetScaledLogVariance"),
        "priority2": p_val(out_all, "grandmasterPriority2"),
        "id": ""
    }
    m_gmid = re.search(r'grandmasterIdentity\s+([0-9a-fA-F\.]+)', out_all)
    if m_gmid: gm["id"] = m_gmid.group(1)

    flags = {
        "currentUtcOffset": p_val(out_all, "currentUtcOffset"),
        "leap61": p_val(out_all, "leap61"),
        "leap59": p_val(out_all, "leap59"),
        "currentUtcOffsetValid": p_val(out_all, "currentUtcOffsetValid"),
        "ptpTimescale": p_val(out_all, "ptpTimescale"),
        "timeTraceable": p_val(out_all, "timeTraceable"),
        "frequencyTraceable": p_val(out_all, "frequencyTraceable"),
        "timeSource": p_val(out_all, "timeSource")
    }

    # 4. Analyze Winner
    decision = []
    
    # 辅助比较函数
    def compare(tag, l_val, r_val, lower_is_better=True):
        if l_val is None or r_val is None: return "draw"
        l_num = l_val; r_num = r_val
        if l_num == r_num: return "draw"
        if lower_is_better: return "local" if l_num < r_num else "remote"
        else: return "local" if l_num > r_num else "remote"

    winner = "unknown"
    
    # 如果 GM ID 就是 Local ID，那是自己赢了
    if local.get('id') and gm.get('id') and local['id'] == gm['id']:
        winner = "local"
        decision.append({"step": "Identity", "reason": "Local Clock is Grandmaster", "result": "win"})
    else:
        # 逐步比较
        steps = [
            ("Priority 1", "priority1", True),
            ("Class", "class", True),
            ("Accuracy", "accuracy", True),
            ("Variance", "variance", True),
            ("Priority 2", "priority2", True)
        ]
        
        determined = False
        for name, key, lower_better in steps:
            l_v = local.get(key); r_v = gm.get(key)
            res = compare(name, l_v, r_v, lower_better)
            
            # Use raw strings for display if needed, but here we have ints.
            # Convert hex fields back to hex string for display if they are typical hex fields
            l_disp = f"0x{l_v:02x}" if key in ['accuracy', 'variance'] and l_v is not None else l_v
            r_disp = f"0x{r_v:02x}" if key in ['accuracy', 'variance'] and r_v is not None else r_v
            
            if res == "draw":
                decision.append({"step": name, "l": l_disp, "r": r_disp, "result": "tie"})
            elif res == "local":
                decision.append({"step": name, "l": l_disp, "r": r_disp, "result": "win"})
                winner = "local"; determined = True; break
            else:
                decision.append({"step": name, "l": l_disp, "r": r_disp, "result": "lose"})
                winner = "remote"; determined = True; break
        
        if not determined:
            # Final tiebreaker: ID (Low is better)
            # Remove dots for hex comparison
            l_id_raw = local.get("id", "").replace(".", "")
            r_id_raw = gm.get("id", "").replace(".", "")
            # Convert large hex ID to int for comparison
            try:
                l_int = int(l_id_raw, 16); r_int = int(r_id_raw, 16)
                res = compare("Identity", l_int, r_int, True)
            except: res = "draw"
            
            if res == "local": winner="local"; decision.append({"step": "Identity", "result": "win (lower ID)"})
            else: winner="remote"; decision.append({"step": "Identity", "result": "lose (higher ID)"})

    return { "local": local, "gm": gm, "flags": flags, "decision": decision, "winner": winner }


def load_user_profiles():
    if os.path.exists(USER_PROFILES_FILE):
        try: 
            with open(USER_PROFILES_FILE, 'r') as f: return json.load(f)
        except: return {}
    return {}

def save_user_profiles(profiles):
    tmp_file = USER_PROFILES_FILE + ".tmp"
    with open(tmp_file, 'w') as f: json.dump(profiles, f, indent=4)
    os.rename(tmp_file, USER_PROFILES_FILE)

def create_safe_wrapper_script(sync_mode, log_level):
    script_dir = os.path.dirname(SAFE_WRAPPER_SCRIPT)
    if not os.path.exists(script_dir):
        try: os.makedirs(script_dir, exist_ok=True)
        except: pass 

    content = """#!/bin/bash
export PATH=$PATH:/usr/sbin:/usr/bin:/sbin:/bin
INTERFACE=$1
"""
    if sync_mode == 'master':
        content += f"""
echo "⚙️ Master Mode detected (SYS -> PHC)."
exec /usr/sbin/phc2sys -s CLOCK_REALTIME -c $INTERFACE -O 0 -l {log_level}
"""
    else:
        content += f"""
PTP_DEV_ID=$(ethtool -T $INTERFACE 2>/dev/null | grep -E "(Clock|index):" | sed 's/.*: //')
if [ -z "$PTP_DEV_ID" ]; then exit 1; fi
PTP_DEV="/dev/ptp$PTP_DEV_ID"
PTP_SECONDS=$(phc_ctl $PTP_DEV get 2>/dev/null | sed -n 's/.*clock time is \\([0-9]\\+\\)\\..*/\\1/p')
if [ -z "$PTP_SECONDS" ] || [ "$PTP_SECONDS" -lt 1700000000 ]; then
    echo "⚠️ DANGER: PTP time < 2023. Aborting."
    exit 1
fi
echo "✅ PTP time valid. Syncing System..."
exec /usr/sbin/phc2sys -s $INTERFACE -c CLOCK_REALTIME -w -O 0 -l {log_level}
"""
    try:
        with open(SAFE_WRAPPER_SCRIPT, 'w') as f: f.write(content)
        os.chmod(SAFE_WRAPPER_SCRIPT, 0o755)
    except Exception as e: print(f"Error writing wrapper script: {e}")

def create_phc2sys_service(interface, sync_mode, log_level):
    create_safe_wrapper_script(sync_mode, log_level)
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
    tmp_svc = PHC2SYS_SERVICE_FILE + ".tmp"
    with open(tmp_svc, 'w') as f: f.write(service_content)
    os.rename(tmp_svc, PHC2SYS_SERVICE_FILE)
    subprocess.run(["systemctl", "daemon-reload"], check=False)

def restart_services_async(enable_phc2sys, master_mode=False, domain=0):
    def _restart():
        time.sleep(0.5)
        subprocess.run(["systemctl", "restart", "ptp4l"], check=False)
        time.sleep(2) 
        if enable_phc2sys:
            subprocess.run(["systemctl", "enable", "--now", "phc2sys-custom"], check=False)
            subprocess.run(["systemctl", "restart", "phc2sys-custom"], check=False)
        else:
            subprocess.run(["systemctl", "stop", "phc2sys-custom"], check=False)
            subprocess.run(["systemctl", "disable", "phc2sys-custom"], check=False)
        
        if master_mode:
            print(f"Fire-and-forget injection for Domain {domain}")
            subprocess.Popen([INJECT_SCRIPT, str(domain)], 
                             stdout=subprocess.DEVNULL, 
                             stderr=subprocess.DEVNULL)
            
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
        for k, v in user_profiles.items(): combined[k] = {**v, 'is_builtin': False, 'id': k}
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
    target_if = req.get('interface')
    mode = req.get('clockMode', 'OC')
    if mode == 'BC':
        slave_if = req.get('bcSlaveIf'); master_if = req.get('bcMasterIf')
        if not validate_interface(slave_if) or not validate_interface(master_if): return jsonify({"status":"error", "message":"Invalid Interface"}), 400
    else:
        if not validate_interface(target_if): return jsonify({"status":"error", "message":"Invalid Interface"}), 400

    monitor_mode = req.get('monitorMode', 'disabled')
    MONITOR_CONFIG["mode"] = monitor_mode
    # Populate interfaces list based on mode
    if mode == 'BC':
        MONITOR_CONFIG["interfaces"] = [x for x in [req.get('bcSlaveIf'), req.get('bcMasterIf')] if x]
    else:
        MONITOR_CONFIG["interfaces"] = [target_if] if target_if else []
    
    ts_mode = req.get('timeStamping', 'hardware')
    sync_mode = req.get('syncMode')
    if sync_mode is None: sync_mode = 'slave' if req.get('syncSystem') is True else 'none'

    log_level = safe_int(req.get('logLevel'), 6)
    if ts_mode not in ['hardware', 'software', 'legacy', 'onestep']: ts_mode = 'hardware'
    
    if os.path.exists(CONFIG_FILE): shutil.copy(CONFIG_FILE, CONFIG_FILE + ".bak")
    
    is_master_mode = (sync_mode == 'master')
    clock_class = 13 if is_master_mode else 248
    time_source = "0x40" if is_master_mode else "0xA0"

    try:
        cfg = f"[global]\nnetwork_transport UDPv4\ntime_stamping {ts_mode}\ndelay_mechanism E2E\ndomainNumber {safe_int(req.get('domain'))}\npriority1 {safe_int(req.get('priority1'), 128)}\npriority2 {safe_int(req.get('priority2'), 128)}\nclockClass {clock_class}\ntimeSource {time_source}\nlogAnnounceInterval {safe_int(req.get('logAnnounceInterval'), 1)}\nlogSyncInterval {safe_int(req.get('logSyncInterval'))}\nlogMinDelayReqInterval {safe_int(req.get('logMinDelayReqInterval'))}\nannounceReceiptTimeout {safe_int(req.get('announceReceiptTimeout'), 3)}\nlogging_level {log_level}\nuse_syslog 1\nverbose 1\n"
        final_target_if = ""
        if mode == 'BC':
            cfg += "boundary_clock_jbod 1\n\n"
            slave_if = req.get('bcSlaveIf'); master_if = req.get('bcMasterIf')
            cfg += f"[{slave_if}]\n\n[{master_if}]\nserverOnly 1\n"
            final_target_if = slave_if 
        else:
            cfg += "\n"; target_if = req.get('interface'); cfg += f"[{target_if}]\n"; final_target_if = target_if

        tmp_conf = CONFIG_FILE + ".tmp"
        with open(tmp_conf, 'w') as f: f.write(cfg)
        os.rename(tmp_conf, CONFIG_FILE)

        should_enable_phc = (sync_mode != 'none' and final_target_if)
        if should_enable_phc: create_phc2sys_service(final_target_if, sync_mode, log_level)

        domain_val = safe_int(req.get('domain'), 0)
        restart_services_async(should_enable_phc, is_master_mode, domain_val)
        return jsonify({"status": "success"})
    except Exception as e: return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/status')
def get_status():
    global STATUS_CACHE
    now = time.time()
    if STATUS_CACHE['data'] and (now - STATUS_CACHE['time'] < 1.0): return jsonify(STATUS_CACHE['data'])

    data = { "ptp4l": "STOPPED", "phc2sys": "STOPPED", "port": "Offline", "offset": 0, "path_delay": 0, "steps_removed": -1, "gm": "Scanning...", "ptp_time": "--", "is_self": False }
    iface = get_current_interface()
    if iface:
        t = get_ptp_time(iface)
        if t: data["ptp_time"] = t
    if run_cmd_safe(["pgrep", "-x", "ptp4l"]): data["ptp4l"] = "RUNNING"
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
            data["offset"] = 0; data["path_delay"] = 0; data["steps_removed"] = 0; data["is_self"] = True
            
    STATUS_CACHE = { "time": now, "data": data }
    return jsonify(data)

@app.route('/api/clients')
def get_clients():
    with CLIENTS_LOCK:
        clients_list = []
        for ip, info in CLIENTS.items():
            clients_list.append({ "ip": ip, "mac": info["mac"], "last_seen": info["last_seen"], "iface": info.get("iface", "?"), "is_self": info.get("is_self", False) })
        return jsonify(clients_list)

@app.route('/api/logs')
def get_logs():
    return jsonify({"logs": run_cmd_safe(["journalctl", "-u", "ptp4l", "-u", "phc2sys-custom", "-n", "30", "--no-pager", "--output", "cat"])})

@app.route('/api/stop', methods=['POST'])
def stop_service():
    subprocess.run(["systemctl", "stop", "ptp4l"], check=False)
    subprocess.run(["systemctl", "stop", "phc2sys-custom"], check=False)
    return jsonify({"status": "success"})

@app.route('/api/bmca')
def get_bmca_api():
    return jsonify(get_bmca_info())


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)