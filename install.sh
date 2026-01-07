#!/bin/bash
set -e

# ================================================================
#   PTP4L Web Controller Installer (v4.0 Stable Edition)
#   Optimized for: Broadcast Engineer (ST 2110 / AES67)
#   Fixes:
#     - Client Monitor Flickering (Increased TTL)
#     - Log Reading Performance (Reduced I/O load)
#   Key Features:
#     - PTP Client Radar (Stable)
#     - Smart Injection & Traceable Flags
#     - Atomic Writes & Security Hardening
# ================================================================

# --- 1. Root 权限检查 ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 root 用户运行此脚本"
  exit 1
fi

echo "🚀 开始部署 PTP4L Web Controller (v4.0 Stable)..."
# --- 1.1 网络环境检测 ---
echo "[0/8] 检测网络连接..."
IS_ONLINE=false
if timeout 2 ping -c 1 -W 1 223.5.5.5 &> /dev/null || timeout 2 curl --head --silent --fail http://www.baidu.com &> /dev/null; then
  IS_ONLINE=true
  echo "   ✅ 网络连接正常 (Online Mode)"
else
  echo "   ⚠️ 无互联网连接 (Offline Mode)"
fi


# --- 2. 时间校准 ---
echo "[1/8] 检查系统时间..."
IS_LXC=false
if command -v systemd-detect-virt &> /dev/null; then
    VIRT=$(systemd-detect-virt || true)
    if [ "$VIRT" == "lxc" ]; then IS_LXC=true; fi
elif [ -f /proc/1/environ ]; then
    if grep -qa "container=lxc" /proc/1/environ; then IS_LXC=true; fi
fi

if [ "$IS_LXC" = true ]; then
    echo "   ⚠️ 检测到 LXC 容器环境，跳过时间校准。"
elif [ "$IS_ONLINE" = false ]; then
    echo "   ⚠️ 离线模式，跳过网络时间校准。"
else
    if command -v curl &> /dev/null; then
        NET_TIME=$(curl -I --insecure --connect-timeout 3 http://www.baidu.com 2>/dev/null | grep ^Date: | sed 's/Date: //g')
        if [ -n "$NET_TIME" ]; then
            date -s "$NET_TIME" >/dev/null
            echo "   ✅ 时间已校准为: $(date)"
        else
            echo "   ⚠️ 无法获取网络时间，跳过校准"
        fi
    fi
fi

# --- 3. 基础环境准备 ---
echo "[2/8] 清理旧服务与文件..."
systemctl stop ptp-web ptp4l phc2sys phc2sys-custom 2>/dev/null || true
systemctl disable phc2sys phc2sys-custom 2>/dev/null || true
rm -f /etc/systemd/system/phc2sys.service
rm -f /etc/systemd/system/phc2sys-custom.service
rm -f /usr/local/bin/ptp-safe-wrapper.sh
systemctl daemon-reload

# 基础依赖安装 (包含 tcpdump)
# 基础依赖安装 (包含 tcpdump)
if [ -f /etc/os-release ]; then . /etc/os-release; fi
COMMON_PKGS="ptp4l ethtool python3 tcpdump"
MISSING_PKGS=""

# 检查缺失的包
for pkg in $COMMON_PKGS; do
    # 映射包名到二进制名
    bin_name=$pkg
    if [ "$pkg" == "linuxptp" ] || [ "$pkg" == "ptp4l" ]; then bin_name="ptp4l"; fi
    if [ "$pkg" == "python3" ]; then bin_name="python3"; fi
    
    if ! command -v $bin_name &> /dev/null; then
         MISSING_PKGS="$MISSING_PKGS $pkg"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    if [ "$IS_ONLINE" = false ]; then
        echo "❌ 错误：离线模式下检测到缺失依赖: $MISSING_PKGS"
        echo "   请先手动挂载 ISO 镜像或安装 .rpm/.deb 包，然后重试。"
        exit 1
    else
        echo "   📥 正在下载并安装依赖: $MISSING_PKGS ..."
        INSTALL_PKGS="linuxptp ethtool python3 tcpdump" 
        if [[ "$ID" =~ (fedora|rhel|centos) ]]; then
            dnf install -y $INSTALL_PKGS python3-pip curl
        elif [[ "$ID" =~ (debian|ubuntu) ]]; then
            export DEBIAN_FRONTEND=noninteractive
            apt update && apt install -y $INSTALL_PKGS python3-venv python3-pip curl
        fi
    fi
else
    echo "   ✅ 基础依赖检查通过，跳过安装。"
fi

# --- 4. 建立目录结构 ---
INSTALL_DIR="/opt/ptp-web"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/templates"
mkdir -p /etc/linuxptp

# --- 5. 生成优化的 PTP 注入脚本 ---
echo "[3/8] 生成 PTP 注入工具..."

cat << 'EOF' > /usr/local/bin/ptp-inject
#!/bin/bash
# PTP4L 状态强制注入工具 (v6.2 Robust)
# Usage: ptp-inject <domain_number>

DOMAIN=${1:-0}
LOG_TAG="ptp-inject"

# 构造指令：包含 clockClass 13 (Master) 以及 ST 2110 必需的 Traceable 标志
CMD="SET GRANDMASTER_SETTINGS_NP clockClass 13 clockAccuracy 0x27 offsetScaledLogVariance 0xFFFF currentUtcOffset 37 leap61 0 leap59 0 currentUtcOffsetValid 1 ptpTimescale 1 timeTraceable 1 frequencyTraceable 1 timeSource 0x50"

echo "Starting injection loop on Domain $DOMAIN..." | logger -t $LOG_TAG

# 循环尝试注入 (持续 20 秒)，确保覆盖 ptp4l 的 LISTENING -> MASTER 状态转换期
# 只要成功一次，并不代表状态会一直保持，所以我们在这个窗口期内多次确认
SUCCESS_COUNT=0

for i in {1..20}; do
    # 运行 PMC 命令
    OUT=$(pmc -u -b 0 -d "$DOMAIN" "$CMD" 2>&1)
    
    # 检查结果：必须包含 RESPONSE 且不能包含 ERROR
    if echo "$OUT" | grep -q "RESPONSE" && ! echo "$OUT" | grep -q "ERROR"; then
        echo "✅ Injection attempt $i: SUCCESS" | logger -t $LOG_TAG
        SUCCESS_COUNT=$((SUCCESS_COUNT+1))
        
        # 即使成功了，我们也建议稍微多试几次或者在初期保持覆盖
        # 但为了效率，如果连续成功2次，我们就认为稳定了
        if [ "$SUCCESS_COUNT" -ge 2 ]; then
            echo "🚀 Injection Stabilized on Domain $DOMAIN" | logger -t $LOG_TAG
            exit 0
        fi
    else
        echo "⚠️ Injection attempt $i failed/ignored. Retrying..." | logger -t $LOG_TAG
        SUCCESS_COUNT=0 # 如果中间失败了，重置计数
    fi
    
    sleep 1
done

echo "❌ Injection timed out (Process might not be Master or ready)" | logger -t $LOG_TAG
exit 1
EOF

chmod +x /usr/local/bin/ptp-inject

# --- 6. 写入 Python 核心代码 ---
echo "[4/8] 写入应用程序核心 (app.py)..."

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
EOF

# --- 7. 前端 UI (保持 Client Monitor 功能) ---
echo "[5/8] 写入前端UI..."

cat << 'EOF' > "$INSTALL_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PTP Controller</title>
    <title>PTP Controller</title>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
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
        <h3 class="mb-0">⏱️ PTP4L Controller by Vega Sun <small class="text-muted fs-6">v4.0 Stable</small></h3>
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
                <div class="ptp-time-display"><small class="d-block text-white-50" style="font-size:0.7rem">PTP HARDWARE TIME</small><span id="ptpTimeVal">--</span></div>
            </div>
        </div>
        <div class="col-md-4">
            <div class="card h-100 p-3 shadow-sm">
                <div class="d-flex h-100 align-items-center">
                    <div class="w-50 text-center border-end">
                        <div class="metric-label">Offset</div><div id="offsetVal" class="metric-value text-primary">--</div><small class="text-muted">ns</small>
                    </div>
                    <div class="w-50 text-center">
                        <div class="metric-label">Path Delay</div><div id="pathDelayVal" class="metric-value text-info">--</div><small class="text-muted">ns</small>
                    </div>
                </div>
            </div>
        </div>
        <div class="col-md-4">
            <div class="card h-100 p-3 shadow-sm justify-content-center">
                <div class="d-flex justify-content-between align-items-center mb-2"><small class="text-muted fw-bold">Grandmaster ID</small><span id="stepsBadge" class="badge bg-secondary">Hops: --</span></div>
                <div id="gmId" class="h6 mb-0 text-break font-monospace text-center bg-light p-2 rounded">Scanning...</div>
            </div>
        </div>
    </div>

    <div class="row g-3 mb-3">
        <!-- BMCA Visualizer -->
        <div class="col-12">
            <div class="card shadow-sm">
                <div class="card-header bg-white d-flex justify-content-between align-items-center" style="cursor: pointer;" data-bs-toggle="collapse" data-bs-target="#bmcaBody">
                    <span class="fw-bold small text-muted">🕸️ BMCA Decision Analyzer</span>
                    <span class="badge bg-light text-dark border" id="bmcaSummary">Loading...</span>
                </div>
                <div id="bmcaBody" class="collapse show">
                    <div class="card-body">
                        <div class="row">
                            <div class="col-md-8">
                                <div class="table-responsive">
                                    <table class="table table-sm table-bordered text-center align-middle" style="font-size: 0.85rem;">
                                        <thead class="table-light">
                                            <tr>
                                                <th style="width:20%">Check</th>
                                                <th style="width:30%" class="text-primary">Local (Me)</th>
                                                <th style="width:10%">Vs</th>
                                                <th style="width:30%" class="text-danger">Current GM</th>
                                                <th style="width:10%">Result</th>
                                            </tr>
                                        </thead>
                                        <tbody id="bmcaTable"></tbody>
                                    </table>
                                </div>
                            </div>
                            <div class="col-md-4">
                                <div class="p-2 border rounded bg-light h-100">
                                    <h6 class="small fw-bold text-muted mb-2">ST 2059-2 Flags</h6>
                                    <div id="ptpFlags" class="d-flex flex-wrap gap-2"></div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <div class="row g-3 mb-3">
        <div class="col-lg-8">
            <div class="card shadow-sm h-100">
                <div class="card-header d-flex justify-content-between py-1 bg-white align-items-center">
                    <span class="fw-bold small text-muted">📈 Offset Stability</span>
                    <span class="badge bg-light text-dark border">RMS: <span id="rmsVal">--</span></span>
                </div>
                <div class="card-body p-2"><div class="chart-container"><canvas id="offsetChart"></canvas></div></div>
            </div>
        </div>
        <div class="col-lg-4">
            <div class="card shadow-sm h-100">
                <div class="card-header fw-bold small text-muted d-flex justify-content-between align-items-center">
                    <span>📡 PTP Client Radar</span>
                    <span class="badge bg-primary" id="clientCount">0</span>
                </div>
                <div class="card-body p-0">
                    <div style="height: 250px; overflow-y: auto;">
                        <table class="table table-sm table-striped mb-0" style="font-size: 0.8rem;">
                            <thead class="table-light sticky-top"><tr><th>IP Address</th><th>MAC</th><th>Iface</th><th>Last Seen</th></tr></thead>
                            <tbody id="clientTableBody"><tr><td colspan="4" class="text-center text-muted">Waiting for data...</td></tr></tbody>
                        </table>
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
                                    <option value="OC" selected>Ordinary Clock (OC)</option>
                                    <option value="BC">Boundary Clock (BC)</option>
                                </select>
                            </div>
                            <div class="col-4">
                                <label class="form-label fw-bold small text-uppercase text-secondary">Monitor</label>
                                <select class="form-select" id="monitorMode">
                                    <option value="disabled">OFF</option>
                                    <option value="periodic" selected>Scan</option>
                                    <option value="realtime">Real-Time</option>
                                </select>
                            </div>
                        </div>

                        <div id="ocPanel" class="mb-3">
                            <label class="small text-muted">Network Interface</label>
                            <select class="form-select" id="interface"><option value="" disabled selected>-- Select --</option>{% for nic in nics %}<option value="{{ nic }}">{{ nic }}</option>{% endfor %}</select>
                        </div>
                        <div id="bcPanel" class="mb-3 border p-2 rounded bg-white" style="display:none;">
                            <label class="small fw-bold text-primary mb-2 d-block">Boundary Clock Topology</label>
                            <div class="mb-2"><label class="small text-muted">⬇️ Upstream (Slave)</label><select class="form-select form-select-sm" id="bcSlaveIf"><option value="" disabled selected>-- Select --</option>{% for nic in nics %}<option value="{{ nic }}">{{ nic }}</option>{% endfor %}</select></div>
                            <div class="mb-2"><label class="small text-muted">⬆️ Downstream (Master)</label><select class="form-select form-select-sm" id="bcMasterIf"><option value="" disabled selected>-- Select --</option>{% for nic in nics %}<option value="{{ nic }}">{{ nic }}</option>{% endfor %}</select></div>
                        </div>
                        
                        <div class="row g-2 mb-3 bg-light p-2 rounded border mx-0">
                            <div class="col-6">
                                <label class="small fw-bold text-muted">Clock Sync</label>
                                <select class="form-select form-select-sm" id="syncMode">
                                    <option value="none">Disabled</option>
                                    <option value="slave" selected>Slave (PHC➔SYS)</option>
                                    <option value="master">Master (SYS➔PHC)</option>
                                </select>
                            </div>
                            <div class="col-6">
                                <label class="small fw-bold text-muted">Timestamping</label>
                                <select class="form-select form-select-sm" id="timeStamping"><option value="hardware">Hardware</option><option value="software">Software</option></select>
                            </div>
                        </div>

                        <hr>
                        <div class="mb-2">
                            <label class="small text-muted">Profile Manager</label>
                            <div class="input-group input-group-sm">
                                <select class="form-select" id="profileSelect" onchange="onUserSelectProfile()"></select>
                                <button type="button" class="btn btn-outline-success" onclick="saveProfile()" title="Save">💾</button>
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
                        
                        <div class="row g-2 mb-3">
                            <div class="col-12">
                                <label class="small text-muted">Log Verbosity</label>
                                <select class="form-select form-select-sm" id="logLevel">
                                    <option value="3">Error Only (3)</option>
                                    <option value="4">Warning (4)</option>
                                    <option value="5">Notice (5)</option>
                                    <option value="6" selected>Info (6) - Default</option>
                                    <option value="7">Debug (7) - High Load</option>
                                </select>
                            </div>
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
    const EXT_FIELDS=['profileSelect','clockMode','interface','bcSlaveIf','bcMasterIf', 'monitorMode']; 
    let offsetChart = null;
    let isUserInteractingLogs = false;

    function init(){ initChart(); fetchProfiles(); setInterval(updateStatus, 1000); setInterval(updateLogs, 2500); setInterval(updateClients, 3000); setInterval(updateBmca, 2000); }

    function updateBmca() {
         fetch('/api/bmca').then(r=>r.json()).then(d => {
             // 1. Update Decision Table
             const tbody = document.getElementById('bmcaTable');
             let html = "";
             
             if (d.decision.length === 0) {
                 html = '<tr><td colspan="5" class="text-center text-muted">Waiting for PMC data...</td></tr>';
                 document.getElementById('bmcaSummary').innerText = "Analyzing...";
                 document.getElementById('bmcaSummary').className = "badge bg-secondary text-white";
             } else {
                 d.decision.forEach(step => {
                    let lVal = (step.l !== undefined && step.l !== null) ? step.l : "--";
                    let rVal = (step.r !== undefined && step.r !== null) ? step.r : "--";
                    let rowClass = "";
                    let resBadge = "";
                    
                    if (step.result === "win") {
                        rowClass = "table-success";
                        resBadge = '<span class="badge bg-success">WIN</span>';
                    } else if (step.result === "lose") {
                        rowClass = "table-danger";
                        resBadge = '<span class="badge bg-danger">LOSE</span>';
                    } else if (step.result === "tie") {
                        resBadge = '<span class="badge bg-light text-dark border">TIE</span>';
                    }
                    
                    // Special case for Identity win by default
                    if (step.step === "Identity" && step.result === "win" && step.reason) {
                         html += `<tr class="table-success"><td class="fw-bold">Identity</td><td colspan="3" class="small">${step.reason}</td><td><span class="badge bg-success">GM</span></td></tr>`;
                    } else {
                         html += `<tr class="${rowClass}"><td class="fw-bold small">${step.step}</td><td>${lVal}</td><td class="text-muted small">vs</td><td>${rVal}</td><td>${resBadge}</td></tr>`;
                    }
                 });
                 
                 // Summary Badge
                 const sumBad = document.getElementById('bmcaSummary');
                 if (d.winner === 'local') {
                     sumBad.innerText = "Local is Master"; sumBad.className = "badge bg-success text-white";
                 } else if (d.winner === 'remote') {
                     sumBad.innerText = "Remote is Master"; sumBad.className = "badge bg-primary text-white";
                 } else {
                     sumBad.innerText = "Unknown";
                 }
             }
             tbody.innerHTML = html;

             // 2. Update Flags (ST 2059-2 Critical)
             const flagsDiv = document.getElementById('ptpFlags');
             const f = d.flags;
             // Define flags to show: (key, label, expected_val)
             const flagMap = [
                 {k: 'ptpTimescale', l: 'PTP Scale', good: 1}, 
                 {k: 'timeTraceable', l: 'Time Trc', good: 1},
                 {k: 'frequencyTraceable', l: 'Freq Trc', good: 1},
                 {k: 'currentUtcOffsetValid', l: 'UTC Valid', good: 1},
                 {k: 'leap59', l: 'Leap59', good: 0},
                 {k: 'leap61', l: 'Leap61', good: 0}
             ];
             
             let fHtml = "";
             flagMap.forEach(item => {
                 const val = f[item.k];
                 let color = "bg-secondary";
                 if (val !== undefined && val !== null) {
                     // ST2059: PTP=1, TT=1, FT=1, UTCV=1 are good. Leaps are usually 0.
                     if (item.good === 1) color = (val == 1) ? "bg-success" : "bg-danger";
                     else color = (val == 1) ? "bg-warning text-dark" : "bg-success"; 
                     
                     fHtml += `<span class="badge ${color}" title="${item.k}">${item.l}: ${val}</span>`;
                 }
             });
             // Add UTC Offset manually
             if(f.currentUtcOffset !== undefined) fHtml += `<span class="badge bg-info text-dark">Offset: ${f.currentUtcOffset}s</span>`;
             
             flagsDiv.innerHTML = fHtml;
             
         }).catch(()=>{});
    }

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
        // Manually add monitorMode
        d['monitorMode'] = document.getElementById('monitorMode').value;
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

    function updateClients(){
        fetch('/api/clients').then(r=>r.json()).then(d=>{
            const tbody = document.getElementById('clientTableBody');
            document.getElementById('clientCount').innerText = d.length;
                if(d.length === 0) {
                    tbody.innerHTML = '<tr><td colspan="4" class="text-center text-muted">No clients detected</td></tr>';
                } else {
                    let html = '';
                    const now = Date.now() / 1000;
                    d.forEach(c => {
                        const ago = Math.round(now - c.last_seen);
                        let ipHtml = c.ip;
                        let rowClass = "";
                        if (c.is_self) {
                             ipHtml += ' <span class="badge bg-info text-dark" style="font-size: 0.7em;">ME</span>';
                             rowClass = "table-info";
                        }
                        html += `<tr class="${rowClass}"><td>${ipHtml}</td><td class="text-muted small">${c.mac}</td><td><span class="badge bg-secondary">${c.iface}</span></td><td><span class="badge bg-success">${ago}s ago</span></td></tr>`;
                    });
                    tbody.innerHTML = html;
                }
        }).catch(()=>{});
    }

   function updateLogs(){ 
    const w = document.getElementById('logWindow');
    if(!w) return;

    // 1. 检测用户是否正在选中文本，如果是，则跳过本次更新（防打扰）
    if (window.getSelection().toString().length > 0) return;

    // 2. 检测用户是否已经手动滚动到了上方
    // 允许 10px 的误差
    const isAtBottom = (w.scrollHeight - w.scrollTop - w.clientHeight) < 20;

    fetch('/api/logs').then(r=>r.json()).then(d=>{ 
        // 只有内容变了才更新，减少DOM操作（可选，但简单起见直接赋值）
        if (w.innerText !== d.logs) {
            w.innerText = d.logs; 
            // 3. 只有当用户原本就在底部时，才自动滚动到底部
            if(isAtBottom) {
                w.scrollTop = w.scrollHeight; 
            }
        }
    }).catch(()=>{}); 
}

    function saveProfile() {
        let n = prompt("Name:");
        if (n) {
            let c = {};
            FIELDS.forEach(f => {
                let el = document.getElementById(f);
                c[f] = (el.type === 'checkbox') ? el.checked : el.value;
            });
            fetch('/api/profiles', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({name: n, config: c})
            })
            .then(response => {
                if (!response.ok) {
                    throw new Error('Network response was not ok');
                }
                return response.json();
            })
            .then(() => fetchProfiles())
            .catch(error => {
                console.error('Error saving profile:', error);
                alert('Failed to save profile: ' + error.message);
            });
        }
    }

    function stopService() {
        if (confirm("Stop?")) {
            fetch('/api/stop', {
                method: 'POST'
            })
            .then(response => {
                if (!response.ok) {
                    throw new Error('Network response was not ok');
                }
                return response.json();
            })
            .then(() => {
                alert('Service stopped successfully');
            })
            .catch(error => {
                console.error('Error stopping service:', error);
                alert('Failed to stop service: ' + error.message);
            });
        }
    }
    
    init();
</script>
</body>
</html>
EOF

# --- 8. Python 环境 ---
echo "[6/8] 配置 Python 环境..."
cd "$INSTALL_DIR"

if [ "$IS_ONLINE" = true ]; then
    # 在线模式：强制重建环境以确保最新
    rm -rf .venv
    python3 -m venv .venv
    ./.venv/bin/pip install --upgrade pip
    ./.venv/bin/pip install -r requirements.txt
else
    # 离线模式：检查现有的 venv
    if [ -f ".venv/bin/python" ] && ./.venv/bin/python -c "import flask, gunicorn" &> /dev/null; then
        echo "   ✅ 离线模式：检测到有效的 Python 环境，跳过安装。"
    else
        echo "   ⚠️ 离线模式：尝试使用系统 Python 环境..."
        # 如果没有 venv，尝试创建一个使用 --system-site-packages 的 venv (假设已预装)
        rm -rf .venv
        python3 -m venv --system-site-packages .venv
        
        if ./.venv/bin/python -c "import flask" &> /dev/null; then
             echo "   ✅ 使用系统 Python 库成功。"
        else
             echo "❌ 错误：离线模式下无法建立 Python 运行时。"
             echo "   系统未检测到 .venv 目录，且系统 Python 未安装 Flask/Gunicorn。"
             echo "   解决方案："
             echo "   1. 找一台联网机器运行此脚本生成 .venv 目录，然后打包 .venv 拷贝到此服务器。"
             echo "   2. 或者手动安装 python3-flask, python3-gunicorn 的 rpm/deb 包。"
             exit 1
        fi
    fi
fi

# --- 9. 系统服务 ---
echo "[7/8] 注册 Systemd 服务..."
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
ExecStart=/opt/ptp-web/.venv/bin/gunicorn --workers 1 --threads 4 --bind 0.0.0.0:8080 app:app
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# --- 10. 防火墙 ---
echo "[8/8] 配置防火墙..."
if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=8080/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=319/udp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=320/udp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# --- 11. 启动 ---
echo "启动服务..."
systemctl daemon-reload
systemctl enable ptp4l ptp-web
systemctl restart ptp-web

if command -v hostname &> /dev/null; then
    IP=$(hostname -I | awk '{print $1}')
else
    IP=$(ip route get 1 | awk '{print $7;exit}')
fi

echo "=========================================================="
echo "   ✅ PTP4L 控制台 (v4.0 Stable) 已部署完毕！"
echo "   👉 访问: http://$IP:8080"
echo "   👉 重要: 请在网页点击【Apply & Restart】以初始化配置"
echo "=========================================================="
