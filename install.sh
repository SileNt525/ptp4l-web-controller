#!/bin/bash
set -e

# ================================================================
#   PTP4L Web Controller Installer (v3.23 Ultimate Edition)
#   Fix: 优化 clockAccuracy 为 0x27 (100μs)，配合 Class 13 实现高优先级
#   Target: Root User
# ================================================================

# --- 1. Root 权限检查 ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 root 用户运行此脚本"
  exit 1
fi

echo "🚀 开始部署 PTP4L Web Controller (v3.23 Ultimate)..."

# --- 2. 紧急时间校准 (LXC 智能跳过) ---
echo "[1/9] 检查并校准系统时间..."

# 检测 LXC 环境
IS_LXC=false
if command -v systemd-detect-virt &> /dev/null; then
    VIRT=$(systemd-detect-virt || true)
    if [ "$VIRT" == "lxc" ]; then IS_LXC=true; fi
elif [ -f /proc/1/environ ]; then
    if grep -qa "container=lxc" /proc/1/environ; then IS_LXC=true; fi
fi

if [ "$IS_LXC" = true ]; then
    echo "   ⚠️ 检测到 LXC 容器环境 (测试模式)，跳过时间校准步骤以避免权限错误。"
else
    if command -v curl &> /dev/null; then
        NET_TIME=$(curl -I --insecure http://www.baidu.com 2>/dev/null | grep ^Date: | sed 's/Date: //g')
        if [ -n "$NET_TIME" ]; then
            date -s "$NET_TIME" >/dev/null
            echo "   ✅ 时间已校准为: $(date)"
        else
            echo "   ⚠️ 无法获取网络时间，跳过校准"
        fi
    else
        echo "   ⚠️ 未找到 curl，跳过时间校准"
    fi
fi


# --- 3. 基础环境准备 ---
echo "[2/9] 清理旧服务与文件..."
systemctl stop ptp-web ptp4l phc2sys phc2sys-custom 2>/dev/null || true
systemctl disable phc2sys phc2sys-custom 2>/dev/null || true
rm -f /usr/local/bin/ptp-inject.sh
rm -f /etc/systemd/system/phc2sys.service
rm -f /etc/systemd/system/phc2sys-custom.service
rm -f /usr/local/bin/ptp-safe-wrapper.sh
systemctl daemon-reload

# 基础依赖安装
if [ -f /etc/os-release ]; then . /etc/os-release; fi
COMMON_PKGS="linuxptp ethtool python3"
if [[ "$ID" =~ (fedora|rhel|centos) ]]; then
    dnf install -y $COMMON_PKGS python3-pip curl
elif [[ "$ID" =~ (debian|ubuntu) ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y $COMMON_PKGS python3-venv python3-pip curl
fi

# --- 4. 建立目录结构 ---
INSTALL_DIR="/opt/ptp-web"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/templates"
mkdir -p /etc/linuxptp

# --- 5. 生成关键 Shell 脚本 (优化 Accuracy) ---
echo "[3/9] 生成 PTP 注入脚本..."

# 生成 /usr/local/bin/ptp-inject
cat << 'EOF' > /usr/local/bin/ptp-inject
#!/bin/bash
# PTP4L 状态强制注入工具
# Usage: ptp-inject <domain_number>

DOMAIN=${1:-0}
LOG_TAG="ptp-inject"

# 等待 ptp4l 启动就绪
for i in {1..10}; do
    if pgrep -x "ptp4l" > /dev/null; then
        break
    fi
    sleep 1
done
sleep 5 # 额外等待端口初始化

# 构造并发送指令
# clockClass 13: 应用级最高优先级
# clockAccuracy 0x27: < 100μs (NTP 精度)
# timeTraceable 1: 声明时间可追溯
CMD="SET GRANDMASTER_SETTINGS_NP clockClass 13 clockAccuracy 0x27 offsetScaledLogVariance 0xFFFF currentUtcOffset 37 leap61 0 leap59 0 currentUtcOffsetValid 1 ptpTimescale 1 timeTraceable 1 frequencyTraceable 1 timeSource 0x50"

echo "Running injection on Domain $DOMAIN..." | logger -t $LOG_TAG

# 尝试注入 3 次
for i in {1..3}; do
    OUT=$(pmc -u -b 0 -d "$DOMAIN" "$CMD" 2>&1)
    
    if echo "$OUT" | grep -q "RESPONSE"; then
        echo "✅ Injection SUCCESS on Domain $DOMAIN" | logger -t $LOG_TAG
        exit 0
    else
        echo "⚠️ Injection attempt $i failed: $OUT" | logger -t $LOG_TAG
        sleep 2
    fi
done

echo "❌ Injection FAILED after retries" | logger -t $LOG_TAG
exit 1
EOF

chmod +x /usr/local/bin/ptp-inject

# --- 6. 写入 Python 代码 ---
echo "[4/9] 写入应用程序..."

cat << 'EOF' > "$INSTALL_DIR/requirements.txt"
blinker==1.9.0
click==8.3.1
Flask==3.1.2
gunicorn==23.0.0
itsdangerous==2.2.0
Jinja2==3.1.6
MarkupSafe==3.0.3
packaging==25.0
Werkzeug==3.1.4
EOF

cat << 'EOF' > "$INSTALL_DIR/app.py"
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
SAFE_WRAPPER_SCRIPT = "/usr/local/bin/ptp-safe-wrapper.sh"
INJECT_SCRIPT = "/usr/local/bin/ptp-inject"
USER_PROFILES_FILE = os.path.join(BASE_DIR, "user_profiles.json")

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
        result = subprocess.check_output(cmd_list, stderr=subprocess.STDOUT, timeout=2, env=env)
        return result.decode('utf-8', errors='ignore')
    except:
        return ""

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
        elif all(s == 'LISTENING' for s in states): data['port_state'] = 'LISTENING'
        else: data['port_state'] = states[0]

    if run_cmd_safe(["pgrep", "-f", "phc2sys"]): data["phc2sys_state"] = "RUNNING"
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
    with open(SAFE_WRAPPER_SCRIPT, 'w') as f: f.write(content)
    os.chmod(SAFE_WRAPPER_SCRIPT, 0o755)

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
    with open(PHC2SYS_SERVICE_FILE, 'w') as f: f.write(service_content)
    subprocess.run(["systemctl", "daemon-reload"], check=False)

def call_inject_script(domain):
    """Calls the external shell script to handle PMC injection safely."""
    try:
        subprocess.run([INJECT_SCRIPT, str(domain)], check=False)
    except Exception as e:
        print(f"Injection call failed: {e}")

def restart_services_async(enable_phc2sys, master_mode=False, domain=0):
    def _restart():
        time.sleep(0.5)
        subprocess.run(["systemctl", "restart", "ptp4l"], check=False)
        if enable_phc2sys:
            subprocess.run(["systemctl", "enable", "--now", "phc2sys-custom"], check=False)
            subprocess.run(["systemctl", "restart", "phc2sys-custom"], check=False)
        else:
            subprocess.run(["systemctl", "stop", "phc2sys-custom"], check=False)
            subprocess.run(["systemctl", "disable", "phc2sys-custom"], check=False)
        
        # === INJECTION ===
        if master_mode:
            call_inject_script(domain)
            
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
    sync_mode = req.get('syncMode')
    if sync_mode is None:
        if req.get('syncSystem') is True: sync_mode = 'slave'
        else: sync_mode = 'none'

    log_level = safe_int(req.get('logLevel'), 6)
    if ts_mode not in ['hardware', 'software', 'legacy', 'onestep']: ts_mode = 'hardware'
    if os.path.exists(CONFIG_FILE): shutil.copy(CONFIG_FILE, CONFIG_FILE + ".bak")
    
    # --- MASTER CONFIG ---
    is_master_mode = (sync_mode == 'master')
    
    if is_master_mode:
        clock_class = 13       # Consistent with injected value
        time_source = "0x40"   # NTP
    else:
        clock_class = 248
        time_source = "0xA0"   # Internal Osc

    try:
        cfg = f"""[global]
network_transport       UDPv4
time_stamping           {ts_mode}
delay_mechanism         E2E
domainNumber            {safe_int(req.get('domain'))}
priority1               {safe_int(req.get('priority1'), 128)}
priority2               {safe_int(req.get('priority2'), 128)}
clockClass              {clock_class}
timeSource              {time_source}
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

        should_enable_phc = (sync_mode != 'none' and target_if)
        if should_enable_phc:
            create_phc2sys_service(target_if, sync_mode, log_level)

        domain_val = safe_int(req.get('domain'), 0)
        restart_services_async(should_enable_phc, is_master_mode, domain_val)
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/status')
def get_status():
    data = { "ptp4l": "STOPPED", "phc2sys": "STOPPED", "port": "Offline", "offset": 0, "path_delay": 0, "steps_removed": -1, "gm": "Scanning...", "ptp_time": "--", "is_self": False }
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
EOF

# 7 生成 INDEX.HTML

echo "[5/9] 写入前端UI..."

cat << 'EOF' > "$INSTALL_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PTP Controller v3.23 Ultimate by Vega Sun</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        .status-box { padding: 15px; border-radius: 8px; color: white; height: 100%; display: flex; flex-direction: column; justify-content: center; transition: background-color 0.3s; }
        .bg-running { background-color: #198754; } 
        .bg-stopped { background-color: #dc3545; }
        .bg-slave { background-color: #0d6efd; }
        .bg-master { background-color: #6610f2; }
        .bg-syncing { background-color: #fd7e14; }
        .bg-passive { background-color: #6c757d; }
        #logWindow { background-color: #212529; color: #0f0; height: 350px; overflow-y: auto; padding: 10px; font-family: monospace; font-size: 0.8rem; }
        .metric-label { font-size: 0.75rem; text-transform: uppercase; color: #6c757d; font-weight: bold; }
        .metric-value { font-size: 1.5rem; font-weight: bold; }
        .chart-container { position: relative; height: 250px; width: 100%; }
        .ptp-time-display { background: rgba(0,0,0,0.2); padding: 5px; border-radius: 4px; margin-top: 10px; font-family: monospace; font-size: 0.9rem; text-align: center;}
    </style>
</head>
<body class="bg-light">
<div class="container-fluid p-4">
    <div class="d-flex justify-content-between align-items-center mb-3">
        <h3 class="mb-0">⏱️ PTP4L Controller by Vega Sun<small class="text-muted fs-6">v3.23 Ultimate</small></h3>
        <span class="badge bg-secondary">{{ hostname }}</span>
    </div>
    
    <div class="row g-3 mb-3">
        <div class="col-md-4">
            <div id="ptpCard" class="status-box bg-stopped shadow-sm">
                <div class="d-flex justify-content-between">
                    <small>PTP4L State</small>
                    <span id="phcBadge" class="badge bg-dark border border-secondary" style="opacity: 0.3">SYNC OFF</span>
                </div>
                <div id="ptpState" class="h3 mb-0">STOPPED</div>
                <small id="serviceStateDetail" class="opacity-75">Service Inactive</small>
                
                <div class="ptp-time-display">
                    <small class="d-block text-white-50" style="font-size:0.7rem">PTP HARDWARE TIME</small>
                    <span id="ptpTimeVal">--</span>
                </div>
            </div>
        </div>

        <div class="col-md-4">
            <div class="card h-100 p-3 shadow-sm">
                <div class="d-flex h-100 align-items-center">
                    <div class="w-50 text-center border-end">
                        <div class="metric-label">Offset</div>
                        <div id="offsetVal" class="metric-value text-primary">--</div>
                        <small class="text-muted">ns</small>
                    </div>
                    <div class="w-50 text-center">
                        <div class="metric-label">Path Delay</div>
                        <div id="pathDelayVal" class="metric-value text-info">--</div>
                        <small class="text-muted">ns</small>
                    </div>
                </div>
            </div>
        </div>

        <div class="col-md-4">
            <div class="card h-100 p-3 shadow-sm justify-content-center">
                <div class="d-flex justify-content-between align-items-center mb-2">
                    <small class="text-muted fw-bold">Grandmaster ID</small>
                    <span id="stepsBadge" class="badge bg-secondary">Hops: --</span>
                </div>
                <div id="gmId" class="h6 mb-0 text-break font-monospace text-center bg-light p-2 rounded">Scanning...</div>
            </div>
        </div>
    </div>

    <div class="row g-3 mb-3">
        <div class="col-12">
            <div class="card shadow-sm">
                <div class="card-header d-flex justify-content-between py-1 bg-white align-items-center">
                    <span class="fw-bold small text-muted">📈 Offset Stability (Last 60s)</span>
                    <span class="badge bg-light text-dark border">RMS: <span id="rmsVal">--</span></span>
                </div>
                <div class="card-body p-2">
                    <div class="chart-container">
                        <canvas id="offsetChart"></canvas>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <div class="row g-3">
        <div class="col-lg-4">
            <div class="card shadow-sm">
                <div class="card-header fw-bold">⚙️ Configuration</div>
                <div class="card-body">
                    <form id="configForm">
                        <div class="row g-2 mb-3">
                            <div class="col-8">
                                <label class="form-label fw-bold small text-uppercase text-secondary">Clock Mode</label>
                                <select class="form-select" id="clockMode" onchange="toggleMode()">
                                    <option value="OC" selected>Ordinary Clock (Single Port)</option>
                                    <option value="BC">Boundary Clock (Dual Port)</option>
                                </select>
                            </div>
                            <div class="col-4">
                                <label class="form-label fw-bold small text-uppercase text-secondary">Time Mode</label>
                                <select class="form-select" id="timeStamping">
                                    <option value="hardware" selected>Hardware</option>
                                    <option value="software">Software</option>
                                </select>
                            </div>
                        </div>

                        <div id="ocPanel" class="mb-3">
                            <label class="small text-muted">Network Interface</label>
                            <select class="form-select" id="interface">
                                <option value="" disabled selected>-- Select --</option>
                                {% for nic in nics %}<option value="{{ nic }}">{{ nic }}</option>{% endfor %}
                            </select>
                        </div>
                        <div id="bcPanel" class="mb-3 border p-2 rounded bg-white" style="display:none;">
                            <label class="small fw-bold text-primary mb-2 d-block">Boundary Clock Topology</label>
                            <div class="mb-2"><label class="small text-muted">⬇️ Upstream (Slave/In)</label><select class="form-select form-select-sm" id="bcSlaveIf"><option value="" disabled selected>-- Select --</option>{% for nic in nics %}<option value="{{ nic }}">{{ nic }}</option>{% endfor %}</select></div>
                            <div class="mb-2"><label class="small text-muted">⬆️ Downstream (Master/Out)</label><select class="form-select form-select-sm" id="bcMasterIf"><option value="" disabled selected>-- Select --</option>{% for nic in nics %}<option value="{{ nic }}">{{ nic }}</option>{% endfor %}</select></div>
                        </div>
                        
                        <div class="row g-2 mb-3 bg-light p-2 rounded border mx-0">
                            <div class="col-8">
                                <label class="small fw-bold text-muted">Clock Sync</label>
                                <select class="form-select form-select-sm" id="syncMode">
                                    <option value="none">None (Disabled)</option>
                                    <option value="slave" selected>Follow PTP (Slave: PHC ➔ SYS)</option>
                                    <option value="master">Force Master (Master: SYS ➔ PHC)</option>
                                </select>
                            </div>
                            <div class="col-4">
                                <label class="small fw-bold text-muted">Log Level</label>
                                <select class="form-select form-select-sm" id="logLevel" title="Log Level">
                                    <option value="6" selected>Info</option>
                                    <option value="5">Notice</option>
                                    <option value="4">Warn</option>
                                    <option value="3">Error</option>
                                </select>
                            </div>
                        </div>

                        <hr>
                        <div class="mb-2">
                            <label class="small text-muted">Profile Manager</label>
                            <div class="input-group input-group-sm">
                                <select class="form-select" id="profileSelect" onchange="onUserSelectProfile()"></select>
                                <button type="button" class="btn btn-outline-success" onclick="saveProfile()" title="Save as New">💾</button>
                                <button type="button" class="btn btn-outline-warning" id="btnRename" onclick="renameProfile()" disabled title="Rename">✏️</button>
                                <button type="button" class="btn btn-outline-danger" id="btnDelete" onclick="deleteProfile()" disabled title="Delete">🗑️</button>
                            </div>
                        </div>

                        <div class="row g-2 mb-2">
                            <div class="col-4"><label class="small text-muted">Domain</label><input type="number" class="form-control form-control-sm" id="domain"></div>
                            <div class="col-4"><label class="small text-muted">Prio 1</label><input type="number" class="form-control form-control-sm" id="priority1"></div>
                            <div class="col-4"><label class="small text-muted">Prio 2</label><input type="number" class="form-control form-control-sm" id="priority2"></div>
                        </div>
                        <div class="row g-2 mb-2">
                            <div class="col-6"><label class="small text-muted">Sync Int</label><input type="number" class="form-control form-control-sm" id="logSyncInterval"></div>
                            <div class="col-6"><label class="small text-muted">Announce Int</label><input type="number" class="form-control form-control-sm" id="logAnnounceInterval"></div>
                        </div>
                        <div class="row g-2 mb-3">
                            <div class="col-6"><label class="small text-muted">Delay Req</label><input type="number" class="form-control form-control-sm" id="logMinDelayReqInterval"></div>
                            <div class="col-6"><label class="small text-muted">Receipt T/O</label><input type="number" class="form-control form-control-sm" id="announceReceiptTimeout"></div>
                        </div>
                        <div class="d-grid gap-2"><button type="button" onclick="applyConfig()" class="btn btn-primary btn-sm fw-bold">Apply & Restart</button><button type="button" onclick="stopService()" class="btn btn-danger btn-sm">Stop</button></div>
                    </form>
                </div>
            </div>
        </div>
        <div class="col-lg-8">
            <div class="card shadow-sm h-100">
                <div class="card-header d-flex justify-content-between py-2"><span class="fw-bold small">PTP4L Logs</span><span class="badge bg-secondary" id="logTime">--:--:--</span></div>
                <div class="card-body p-0"><div id="logWindow">Connecting...</div></div>
            </div>
        </div>
    </div>
</div>
<script>
    let profiles={}; 
    const FIELDS=['timeStamping','domain','priority1','priority2','logSyncInterval','logAnnounceInterval','logMinDelayReqInterval','announceReceiptTimeout', 'syncMode', 'logLevel'];
    const EXT_FIELDS=['profileSelect','clockMode','interface','bcSlaveIf','bcMasterIf']; 
    let offsetChart = null;

    function init(){ initChart(); fetchProfiles(); setInterval(updateStatus, 1000); setInterval(updateLogs, 2500); }

    function saveConfigCache() {
        let cache = {};
        FIELDS.forEach(f => { const el=document.getElementById(f); if(el) cache[f] = (el.type === 'checkbox') ? el.checked : el.value; });
        EXT_FIELDS.forEach(f => { const el=document.getElementById(f); if(el) cache[f]=el.value; });
        localStorage.setItem('ptp4l_last_config', JSON.stringify(cache));
    }

    function loadConfigCache() {
        const cacheStr = localStorage.getItem('ptp4l_last_config');
        if(!cacheStr) return;
        try {
            const cache = JSON.parse(cacheStr);
            [...FIELDS, ...EXT_FIELDS].forEach(f => {
                const el = document.getElementById(f);
                if(el && cache[f] !== undefined) {
                    if(el.type === 'checkbox') el.checked = cache[f];
                    else if(cache[f] !== "") el.value = cache[f];
                }
            });
            toggleMode(); 
            onProfileChange(); 
        } catch(e) {}
    }

    function fetchProfiles(){ 
        fetch('/api/profiles').then(r=>r.json()).then(d=>{ 
            profiles=d; 
            const s=document.getElementById('profileSelect'); 
            s.innerHTML='<option value="" disabled selected>-- Select --</option>'; 
            for(let i in d){ let o=document.createElement('option'); o.value=i; o.text=d[i].name+(d[i].is_builtin?"*":""); s.add(o); }
            loadConfigCache();
        });
    }

    function onUserSelectProfile() { loadProfileData(); onProfileChange(); }
    function onProfileChange() {
        const pid = document.getElementById('profileSelect').value;
        const isUser = pid && pid.startsWith('user_');
        document.getElementById('btnRename').disabled = !isUser;
        document.getElementById('btnDelete').disabled = !isUser;
    }

    function renameProfile() {
        const pid = document.getElementById('profileSelect').value;
        if(!pid || !profiles[pid]) return;
        const newName = prompt("Rename Profile:", profiles[pid].name);
        if(!newName) return;
        let cleanConfig = {};
        FIELDS.forEach(f => { const el = document.getElementById(f); if(el) cleanConfig[f] = (el.type === 'checkbox') ? el.checked : el.value; else cleanConfig[f] = profiles[pid][f]; });
        fetch('/api/profiles', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({name: newName, config: cleanConfig}) })
        .then(r=>r.json()).then(d => { if(d.status === 'success') { fetch('/api/profiles/' + pid, { method:'DELETE' }).then(() => { alert("Renamed!"); fetchProfiles(); }); } });
    }

    function deleteProfile() {
        const pid = document.getElementById('profileSelect').value;
        if(!confirm("Delete?")) return;
        fetch('/api/profiles/' + pid, { method:'DELETE' }).then(r=>r.json()).then(d => { if(d.status==='success') { alert("Deleted!"); fetchProfiles(); } });
    }
    
    function initChart(){
        const ctx = document.getElementById('offsetChart');
        if(!ctx) return;
        offsetChart = new Chart(ctx.getContext('2d'), {
            type: 'line',
            data: { labels: [], datasets: [{ label: 'Offset (ns)', data: [], borderColor: '#0d6efd', backgroundColor: 'rgba(13, 110, 253, 0.1)', borderWidth: 2, pointRadius: 0, fill: true, tension: 0.3 }] },
            options: { responsive: true, maintainAspectRatio: false, animation: false, plugins: { legend: { display: false } }, scales: { x: { display: false }, y: { beginAtZero: false, grid: { color: 'rgba(0,0,0,0.05)' } } } }
        });
    }

    function updateChartData(offset){
        if(!offsetChart) return;
        offsetChart.data.labels.push("");
        offsetChart.data.datasets[0].data.push(offset);
        if(offsetChart.data.labels.length > 60){ offsetChart.data.labels.shift(); offsetChart.data.datasets[0].data.shift(); }
        offsetChart.update();
        const data = offsetChart.data.datasets[0].data;
        if(data.length > 0) {
            const sumSq = data.reduce((a, b) => a + (b * b), 0);
            document.getElementById('rmsVal').innerText = Math.round(Math.sqrt(sumSq / data.length)) + " ns";
        }
    }

    function toggleMode(){ const m=document.getElementById('clockMode').value; document.getElementById('ocPanel').style.display=(m==='OC'?'block':'none'); document.getElementById('bcPanel').style.display=(m==='BC'?'block':'none'); }
    
    function loadProfileData(){ 
        const p=document.getElementById('profileSelect').value; 
        if(profiles[p]) FIELDS.forEach(f=>{ 
            let el=document.getElementById(f);
            if(el) {
                if(el.type === 'checkbox') el.checked = profiles[p][f] === true;
                else if (f === 'syncMode' && profiles[p][f] === undefined) { if (profiles[p]['syncSystem'] === true) el.value = 'slave'; else el.value = 'none'; }
                else el.value = (profiles[p][f] !== undefined) ? profiles[p][f] : (f==='logLevel'?6:0);
            }
        }); 
    }
    
    function applyConfig(){
        const m=document.getElementById('clockMode').value; const d={clockMode:m};
        if(m==='BC'){ d.bcSlaveIf=document.getElementById('bcSlaveIf').value; d.bcMasterIf=document.getElementById('bcMasterIf').value; if(!d.bcSlaveIf||!d.bcMasterIf||d.bcSlaveIf===d.bcMasterIf){ alert("Invalid BC Config"); return; } }
        else{ d.interface=document.getElementById('interface').value; if(!d.interface){ alert("Select Interface"); return; } }
        if(!confirm("Apply & Restart?")) return;
        FIELDS.forEach(f=>{ let el=document.getElementById(f); d[f] = (el.type === 'checkbox') ? el.checked : el.value; });
        saveConfigCache(); 
        fetch('/api/apply',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(r=>r.json()).then(r=>{ if(r.status==='success') alert("✅ Success!"); else alert("❌ "+r.message); }).catch(e=>alert("Error:"+e));
    }

    function updateStatus(){ 
        fetch('/api/status').then(r=>r.json()).then(d=>{
            const c=document.getElementById('ptpCard'), t=document.getElementById('ptpState');
            const ptpTimeEl = document.getElementById('ptpTimeVal');
            if(d.ptp_time && d.ptp_time !== "--") {
                ptpTimeEl.innerText = d.ptp_time;
                const year = parseInt(d.ptp_time.split('-')[0]);
                if(year < 2023) { ptpTimeEl.style.color = "#ff6b6b"; ptpTimeEl.innerHTML = "⚠️ " + d.ptp_time; } else { ptpTimeEl.style.color = "#51cf66"; }
            } else { ptpTimeEl.innerText = "--"; ptpTimeEl.style.color = "white"; }

            if(d.ptp4l==='RUNNING'){
                t.innerText=d.port||"UNKNOWN"; 
                document.getElementById('serviceStateDetail').innerText="Running";
                c.className='status-box shadow-sm ';
                
                const p = d.port;
                if(p==='MASTER'||p==='GRAND_MASTER') c.className += 'bg-master';
                else if(p==='SLAVE') c.className += 'bg-slave';
                else if(p==='UNCALIBRATED'||p==='LISTENING'||p==='INITIALIZING') c.className += 'bg-syncing';
                else if(p==='FAULTY'||p==='DISABLED'||p==='UNKNOWN') c.className += 'bg-stopped';
                else if(p==='PASSIVE') c.className += 'bg-passive';
                else c.className += 'bg-running';
                
                const phcEl = document.getElementById('phcBadge');
                if(phcEl) {
                    if(d.phc2sys === 'RUNNING') {
                        phcEl.className = "badge bg-success border border-light";
                        phcEl.style.opacity = "1.0";
                        phcEl.innerText = "SYNC ON";
                    } else {
                        phcEl.className = "badge bg-dark border border-secondary";
                        phcEl.style.opacity = "0.3";
                        phcEl.innerText = "SYNC OFF";
                    }
                }
                if(d.port !== 'UNKNOWN') updateChartData(Math.round(d.offset));
            } else { 
                c.className='status-box bg-stopped shadow-sm'; t.innerText="STOPPED"; 
                document.getElementById('serviceStateDetail').innerText="Inactive"; 
            }
            document.getElementById('offsetVal').innerText = Math.round(d.offset); 
            const delayEl = document.getElementById('pathDelayVal');
            if(delayEl) delayEl.innerText = (d.port !== 'MASTER' && d.port !== 'GRAND_MASTER' && d.path_delay === 0) ? "--" : Math.round(d.path_delay);
            document.getElementById('gmId').innerText = d.gm || "N/A";
            const stepsEl = document.getElementById('stepsBadge');
            if(stepsEl) stepsEl.innerText = (d.steps_removed !== -1) ? "Hops: " + d.steps_removed : "Hops: --";
            document.getElementById('logTime').innerText = new Date().toLocaleTimeString();
        }).catch(()=>{}); 
    }

    function updateLogs(){ fetch('/api/logs').then(r=>r.json()).then(d=>{ const w=document.getElementById('logWindow'); if(w){ w.innerText=d.logs; w.scrollTop=w.scrollHeight; } }).catch(()=>{}); }
    function saveProfile(){ let n=prompt("Name:"); if(n){ let c={}; FIELDS.forEach(f=>{ let el=document.getElementById(f); c[f]=(el.type==='checkbox')?el.checked:el.value; }); fetch('/api/profiles',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,config:c})}).then(()=>fetchProfiles()); } }
    function stopService(){ if(confirm("Stop?")) fetch('/api/stop',{method:'POST'}); }
    
    init();
</script>
</body>
</html>
EOF

# --- 8. Python 环境 ---
echo "[6/9] 配置环境..."
cd "$INSTALL_DIR"
rm -rf .venv
python3 -m venv .venv
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install -r requirements.txt

# --- 9. 系统服务 ---
echo "[7/9] 注册服务..."
cat << 'EOF' > /etc/systemd/system/ptp4l.service
[Unit]
Description=Precision Time Protocol (PTP) service
After=network.target
[Service]
Type=simple
ExecStart=/usr/sbin/ptp4l -f /etc/linuxptp/ptp4l.conf
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > /etc/systemd/system/ptp-web.service
[Unit]
Description=PTP Web Controller UI
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/ptp-web
ExecStart=/opt/ptp-web/.venv/bin/gunicorn --workers 4 --bind 0.0.0.0:8080 app:app
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# --- 10. 防火墙 ---
echo "[8/9] 防火墙放行..."
if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=8080/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=319/udp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=320/udp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# --- 11. 启动 ---
echo "[9/9] 启动..."
systemctl daemon-reload
systemctl enable ptp4l ptp-web
systemctl restart ptp-web

if command -v hostname &> /dev/null; then
    IP=$(hostname -I | awk '{print $1}')
else
    IP=$(ip route get 1 | awk '{print $7;exit}')
fi

echo "=========================================================="
echo "   ✅ PTP4L 控制台 (v3.23 Ultimate) 已就绪！"
echo "   👉 请在网页端重新点击【Apply & Restart】"
echo "   👉 访问: http://$IP:8080"
echo "=========================================================="
