import os
import subprocess
import re
import sys
import json
import socket
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)
CONFIG_FILE = "/etc/linuxptp/ptp4l.conf"
USER_PROFILES_FILE = "/root/ptp-web/user_profiles.json"

# --- 全局状态缓存 (防止日志滚动导致状态丢失) ---
last_known_state = {
    "gm_identity": "Scanning...",
    "port_state": "Initializing",
    "offset": "0",
    "is_self": False
}

# --- 内置 Profile 模板 ---
BUILTIN_PROFILES = {
    "default": {
        "name": "Default (IEEE 1588)",
        "domain": 0,
        "priority1": 128,
        "priority2": 128,
        "logAnnounceInterval": 1,
        "logSyncInterval": 0,
        "logMinDelayReqInterval": 0,
        "announceReceiptTimeout": 3
    },
    "aes67": {
        "name": "AES67 (Media)",
        "domain": 0,
        "priority1": 128,
        "priority2": 128,
        "logAnnounceInterval": 1,
        "logSyncInterval": -3,
        "logMinDelayReqInterval": 0,
        "announceReceiptTimeout": 3
    },
    "st2059": {
        "name": "SMPTE ST 2059-2 (Broadcast)",
        "domain": 127,
        "priority1": 128,
        "priority2": 128,
        "logAnnounceInterval": -2,
        "logSyncInterval": -3,
        "logMinDelayReqInterval": -2,
        "announceReceiptTimeout": 3
    }
}

def run_cmd(cmd):
    """执行 Shell 命令并捕获输出，自带超时控制"""
    try:
        result = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, timeout=2)
        return result.decode('utf-8', errors='ignore')
    except Exception:
        return ""

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

@app.route('/')
def index():
    # 1. 获取网卡列表
    nics = []
    try:
        nics = [n for n in os.listdir('/sys/class/net/') if 'en' in n or 'eth' in n]
    except: pass

    # 2. 获取动态系统信息 (OS名称)
    os_label = "Linux System"
    try:
        if os.path.exists("/etc/os-release"):
            with open("/etc/os-release") as f:
                info = {}
                for line in f:
                    if "=" in line:
                        k, v = line.strip().split("=", 1)
                        info[k] = v.strip('"')
                if "NAME" in info and "VERSION_ID" in info:
                    os_label = f"{info['NAME']} {info['VERSION_ID']}"
                elif "PRETTY_NAME" in info:
                    os_label = info["PRETTY_NAME"]
    except: pass

    # 3. 获取主机名
    hostname = socket.gethostname()

    return render_template('index.html', nics=nics, os_label=os_label, hostname=hostname)

@app.route('/api/profiles', methods=['GET'])
def get_profiles():
    """获取所有 Profile (内置 + 用户自定义)"""
    user_profiles = load_user_profiles()
    combined = {}
    for k, v in BUILTIN_PROFILES.items():
        v['is_builtin'] = True
        v['id'] = k
        combined[k] = v
    for k, v in user_profiles.items():
        v['is_builtin'] = False
        v['id'] = k
        combined[k] = v
    return jsonify(combined)

@app.route('/api/profiles', methods=['POST'])
def save_profile():
    """保存用户自定义 Profile"""
    req = request.json
    name = req.get('name')
    if not name:
        return jsonify({"status": "error", "message": "Profile name is required"}), 400
    
    # 生成简单 ID
    profile_id = "user_" + re.sub(r'\W+', '_', name).lower()
    profiles = load_user_profiles()
    profiles[profile_id] = req['config']
    profiles[profile_id]['name'] = name
    
    save_user_profiles(profiles)
    return jsonify({"status": "success", "id": profile_id})

@app.route('/api/profiles/<profile_id>', methods=['DELETE'])
def delete_profile(profile_id):
    """删除用户自定义 Profile"""
    profiles = load_user_profiles()
    if profile_id in profiles:
        del profiles[profile_id]
        save_user_profiles(profiles)
        return jsonify({"status": "success"})
    return jsonify({"status": "error", "message": "Profile not found"}), 404

@app.route('/api/apply', methods=['POST'])
def apply_config():
    """生成配置文件并重启服务"""
    global last_known_state
    req = request.json
    
    interface = req.get('interface')
    if not interface:
        return jsonify({"status": "error", "message": "No interface selected"}), 400

    domain = req.get('domain', 0)
    p1 = req.get('priority1', 128)
    p2 = req.get('priority2', 128)
    announce_interval = req.get('logAnnounceInterval', 1)
    sync_interval = req.get('logSyncInterval', 0)
    delay_req_interval = req.get('logMinDelayReqInterval', 0)
    receipt_timeout = req.get('announceReceiptTimeout', 3)

    config_content = f"""[global]
# Interface: {interface}
network_transport       UDPv4
time_stamping           hardware
delay_mechanism         E2E

# PTP Domain & Priority
domainNumber            {domain}
priority1               {p1}
priority2               {p2}

# Time Intervals (2^x seconds)
logAnnounceInterval     {announce_interval}
logSyncInterval         {sync_interval}
logMinDelayReqInterval  {delay_req_interval}
announceReceiptTimeout  {receipt_timeout}

# System Settings
logging_level           6
use_syslog              1
verbose                 1
tx_timestamp_timeout    10
"""
    config_content += f"\n[{interface}]\n"

    try:
        with open(CONFIG_FILE, 'w') as f:
            f.write(config_content)
        
        # 重启前重置状态缓存
        last_known_state = {"gm_identity": "Scanning...", "port_state": "Initializing", "offset": "0", "is_self": False}
        run_cmd("systemctl restart ptp4l")
        return jsonify({"status": "success", "message": "Configuration Applied & Service Restarted"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/status')
def get_status():
    """获取 PTP 状态 (基于日志解析)"""
    global last_known_state
    
    # 构造 GM ID 显示字符串
    display_id = last_known_state["gm_identity"]
    if last_known_state["is_self"] and "Scanning" not in display_id:
        if "(Self)" not in display_id:
            display_id = f"{display_id} (Self)"

    data = {
        "running": False,
        "gm_identity": display_id,
        "offset": last_known_state["offset"],
        "port_state": last_known_state["port_state"]
    }

    # 1. 检查 Systemd 进程
    proc_check = run_cmd("pgrep -x ptp4l")
    if not proc_check.strip():
        data["port_state"] = "STOPPED"
        # 服务停止，清空缓存状态
        last_known_state = {"gm_identity": "Scanning...", "port_state": "Offline", "offset": "0", "is_self": False}
        return jsonify(data)
    
    data["running"] = True
    
    # 读取最近 300 行日志进行分析
    log_output = run_cmd("journalctl -u ptp4l -n 300 --no-pager --output cat")
    if not log_output: return jsonify(data)

    # 2. 提取 Port State
    state_matches = list(re.finditer(r'port \d+ .*?: \w+ to (\w+)', log_output))
    if state_matches: 
        current_state = state_matches[-1].group(1)
        last_known_state["port_state"] = current_state

    # 3. 提取 Offset
    # 逻辑: 如果是 GM，强制 Offset 为 0。否则从日志提取 (master offset 或 rms)
    if last_known_state["port_state"] == "GRAND_MASTER":
        last_known_state["offset"] = "0"
    else:
        offset_candidates = []
        # 匹配类型 A: "master offset 1234"
        for m in re.finditer(r'master offset\s+([0-9-]+)', log_output):
            offset_candidates.append((m.start(), m.group(1)))
        # 匹配类型 B: "rms 6676 max ..."
        for m in re.finditer(r'rms\s+(\d+)\s+max', log_output):
            offset_candidates.append((m.start(), m.group(1)))

        if offset_candidates:
            # 取日志中最新的一条
            offset_candidates.sort(key=lambda x: x[0])
            last_known_state["offset"] = offset_candidates[-1][1]

    # 4. 提取 GM ID
    gm_matches = list(re.finditer(r'selected best master clock ([0-9a-f\.]+)', log_output))
    self_matches = list(re.finditer(r'assuming the grand master role', log_output))

    if gm_matches:
        last_known_state["gm_identity"] = gm_matches[-1].group(1)
        last_gm_idx = gm_matches[-1].start()
        # 如果 "assuming master" 发生在 "selected best" 之后，说明是本机
        last_self_idx = self_matches[-1].start() if self_matches else -1
        last_known_state["is_self"] = (last_self_idx > last_gm_idx)

    return jsonify(data)

@app.route('/api/logs')
def get_logs():
    """获取实时日志供前端显示"""
    logs = run_cmd("journalctl -u ptp4l -n 50 --no-pager --output cat")
    return jsonify({"logs": logs})

@app.route('/api/stop', methods=['POST'])
def stop_service():
    """停止服务"""
    global last_known_state
    run_cmd("systemctl stop ptp4l")
    last_known_state = {"gm_identity": "Scanning...", "port_state": "Offline", "offset": "0", "is_self": False}
    return jsonify({"status": "success"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
