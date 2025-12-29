#!/bin/bash
set -e

# ==========================================
#   PTP4L Web Controller 一键部署脚本 (Final Fix)
#   Author: Vega Sun
#   支持: Fedora/CentOS/RHEL & Debian/Ubuntu
# ==========================================

# 1. Root 权限检查
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 root 用户运行此脚本 (例如: sudo ./install.sh)"
  exit 1
fi

# 2. 安装确认
echo "========================================================"
echo "   正在准备安装 PTP4L Web 控制台"
echo "   此操作将执行以下内容："
echo "   1. 安装 linuxptp, ethtool, python3 等依赖"
echo "   2. 创建并注册 Systemd 服务 (修复 Debian 缺失服务问题)"
echo "   3. 覆盖 /opt/ptp-web 目录下的旧文件"
echo "========================================================"
read -r -p "🤔 是否确认立即开始安装? [y/N] " response
if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "🚫 操作已取消。"
    exit 1
fi

echo "🚀 开始安装..."

# --- 3. 操作系统检测与依赖安装 ---
echo "[1/7] 检测操作系统并安装依赖..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法检测操作系统版本 (/etc/os-release 缺失)"
    exit 1
fi

echo "   -> 检测到系统: $PRETTY_NAME ($OS)"

COMMON_PKGS="linuxptp ethtool python3 python3-pip"

if [[ "$OS" == "fedora" || "$OS" == "rhel" || "$OS" == "centos" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    echo "   -> 使用 dnf 安装依赖..."
    dnf install -y $COMMON_PKGS

elif [[ "$OS" == "debian" || "$OS" == "ubuntu" || "$OS" == "kali" || "$OS" == "linuxmint" ]]; then
    echo "   -> 更新 apt 缓存并安装依赖..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y $COMMON_PKGS python3-venv
else
    echo "❌ 不支持的操作系统: $OS"
    exit 1
fi

if ! command -v ptp4l &> /dev/null; then
    echo "❌ 错误: ptp4l 命令未找到，linuxptp 安装失败！"
    exit 1
fi
echo "   ✅ 依赖安装完成"

# --- 4. 创建项目目录 ---
echo "[2/7] 创建项目目录 /opt/ptp-web ..."
mkdir -p /opt/ptp-web/templates
mkdir -p /etc/linuxptp

# --- 5. 配置 Python 环境 ---
echo "[3/7] 配置 Python 虚拟环境..."
cd /opt/ptp-web
if [ -d ".venv" ]; then rm -rf .venv; fi
python3 -m venv .venv
./.venv/bin/pip install flask

# --- 6. 写入后端代码 (app.py) ---
echo "[4/7] 部署后端代码..."
cat << 'EOF' > /opt/ptp-web/app.py
import os
import subprocess
import re
import sys
import json
import socket
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)
CONFIG_FILE = "/etc/linuxptp/ptp4l.conf"
USER_PROFILES_FILE = "/opt/ptp-web/user_profiles.json"

last_known_state = { "gm_identity": "Scanning...", "port_state": "Initializing", "offset": "0", "is_self": False }

BUILTIN_PROFILES = {
    "default": { "name": "Default (IEEE 1588)", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": 0, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3 },
    "aes67": { "name": "AES67 (Media)", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": -3, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3 },
    "st2059": { "name": "SMPTE ST 2059-2 (Broadcast)", "domain": 127, "priority1": 128, "priority2": 128, "logAnnounceInterval": -2, "logSyncInterval": -3, "logMinDelayReqInterval": -2, "announceReceiptTimeout": 3 }
}

def run_cmd(cmd):
    try:
        result = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, timeout=2)
        return result.decode('utf-8', errors='ignore')
    except Exception: return ""

def load_user_profiles():
    if os.path.exists(USER_PROFILES_FILE):
        try: with open(USER_PROFILES_FILE, 'r') as f: return json.load(f)
        except: return {}
    return {}

def save_user_profiles(profiles):
    with open(USER_PROFILES_FILE, 'w') as f: json.dump(profiles, f, indent=4)

@app.route('/')
def index():
    nics = []
    try: nics = [n for n in os.listdir('/sys/class/net/') if 'en' in n or 'eth' in n]
    except: pass
    os_label = "Linux System"
    try:
        if os.path.exists("/etc/os-release"):
            with open("/etc/os-release") as f:
                info = {}
                for line in f:
                    if "=" in line: k, v = line.strip().split("=", 1); info[k] = v.strip('"')
                if "NAME" in info and "VERSION_ID" in info: os_label = f"{info['NAME']} {info['VERSION_ID']}"
                elif "PRETTY_NAME" in info: os_label = info["PRETTY_NAME"]
    except: pass
    return render_template('index.html', nics=nics, os_label=os_label, hostname=socket.gethostname())

@app.route('/api/profiles', methods=['GET'])
def get_profiles():
    user_profiles = load_user_profiles()
    combined = {}
    for k, v in BUILTIN_PROFILES.items(): v['is_builtin'] = True; v['id'] = k; combined[k] = v
    for k, v in user_profiles.items(): v['is_builtin'] = False; v['id'] = k; combined[k] = v
    return jsonify(combined)

@app.route('/api/profiles', methods=['POST'])
def save_profile():
    req = request.json
    name = req.get('name')
    if not name: return jsonify({"status": "error", "message": "Name required"}), 400
    profile_id = "user_" + re.sub(r'\W+', '_', name).lower()
    profiles = load_user_profiles()
    profiles[profile_id] = req['config']; profiles[profile_id]['name'] = name
    save_user_profiles(profiles)
    return jsonify({"status": "success", "id": profile_id})

@app.route('/api/profiles/<profile_id>', methods=['DELETE'])
def delete_profile(profile_id):
    profiles = load_user_profiles()
    if profile_id in profiles: del profiles[profile_id]; save_user_profiles(profiles)
        return jsonify({"status": "success"})
    return jsonify({"status": "error"}), 404

@app.route('/api/apply', methods=['POST'])
def apply_config():
    global last_known_state
    req = request.json
    if not req.get('interface'): return jsonify({"status": "error"}), 400
    content = f"[global]\nnetwork_transport UDPv4\ntime_stamping hardware\ndelay_mechanism E2E\n"
    content += f"domainNumber {req.get('domain', 0)}\npriority1 {req.get('priority1', 128)}\npriority2 {req.get('priority2', 128)}\n"
    content += f"logAnnounceInterval {req.get('logAnnounceInterval', 1)}\nlogSyncInterval {req.get('logSyncInterval', 0)}\n"
    content += f"logMinDelayReqInterval {req.get('logMinDelayReqInterval', 0)}\nannounceReceiptTimeout {req.get('announceReceiptTimeout', 3)}\n"
    content += f"logging_level 6\nuse_syslog 1\nverbose 1\ntx_timestamp_timeout 10\n\n[{req.get('interface')}]\n"
    try:
        with open(CONFIG_FILE, 'w') as f: f.write(content)
        last_known_state = {"gm_identity": "Scanning...", "port_state": "Initializing", "offset": "0", "is_self": False}
        run_cmd("systemctl restart ptp4l")
        return jsonify({"status": "success"})
    except Exception as e: return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/status')
def get_status():
    global last_known_state
    display_id = last_known_state["gm_identity"]
    if last_known_state["is_self"] and "Scanning" not in display_id and "(Self)" not in display_id:
        display_id = f"{display_id} (Self)"
    data = { "running": False, "gm_identity": display_id, "offset": last_known_state["offset"], "port_state": last_known_state["port_state"] }
    if not run_cmd("pgrep -x ptp4l").strip():
        data["port_state"] = "STOPPED"; last_known_state = {"gm_identity": "Scanning...", "port_state": "Offline", "offset": "0", "is_self": False}
        return jsonify(data)
    data["running"] = True
    log_output = run_cmd("journalctl -u ptp4l -n 300 --no-pager --output cat")
    if not log_output: return jsonify(data)
    m = list(re.finditer(r'port \d+ .*?: \w+ to (\w+)', log_output))
    if m: last_known_state["port_state"] = m[-1].group(1)
    if last_known_state["port_state"] == "GRAND_MASTER": last_known_state["offset"] = "0"
    else:
        candidates = []
        for x in re.finditer(r'master offset\s+([0-9-]+)', log_output): candidates.append((x.start(), x.group(1)))
        for x in re.finditer(r'rms\s+(\d+)\s+max', log_output): candidates.append((x.start(), x.group(1)))
        if candidates: candidates.sort(key=lambda x: x[0]); last_known_state["offset"] = candidates[-1][1]
    gm_m = list(re.finditer(r'selected best master clock ([0-9a-f\.]+)', log_output))
    self_m = list(re.finditer(r'assuming the grand master role', log_output))
    if gm_m:
        last_known_state["gm_identity"] = gm_m[-1].group(1); last_gm_idx = gm_m[-1].start()
        last_self_idx = self_m[-1].start() if self_m else -1
        last_known_state["is_self"] = (last_self_idx > last_gm_idx)
    return jsonify(data)

@app.route('/api/logs')
def get_logs(): return jsonify({"logs": run_cmd("journalctl -u ptp4l -n 50 --no-pager --output cat")})

@app.route('/api/stop', methods=['POST'])
def stop_service():
    global last_known_state
    run_cmd("systemctl stop ptp4l"); last_known_state = {"gm_identity": "Scanning...", "port_state": "Offline", "offset": "0", "is_self": False}
    return jsonify({"status": "success"})

if __name__ == '__main__': app.run(host='0.0.0.0', port=8080)
EOF

# --- 7. 写入前端代码 (index.html) ---
echo "[5/7] 部署前端代码..."
cat << 'EOF' > /opt/ptp-web/templates/index.html
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Fedora PTP GM Manager</title>
    <meta name="author" content="Vega Sun">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        .status-box { padding: 20px; border-radius: 10px; color: white; height: 100%; display: flex; flex-direction: column; justify-content: center; }
        .bg-running { background-color: #28a745; } .bg-stopped { background-color: #dc3545; }
        .metric-val { font-size: 2rem; font-weight: bold; }
        .info-card { height: 100%; border: none; box-shadow: 0 .125rem .25rem rgba(0,0,0,.075); }
        #logWindow { background-color: #1e1e1e; color: #00ff00; font-family: 'Courier New', monospace; height: 500px; overflow-y: scroll; padding: 10px; border-radius: 5px; font-size: 0.85rem; white-space: pre-wrap; }
        .param-group { background: #f8f9fa; padding: 15px; border-radius: 5px; margin-bottom: 15px; border: 1px solid #dee2e6; }
        .param-label { font-weight: 600; font-size: 0.9rem; color: #495057; }
    </style>
</head>
<body class="bg-light">
<div class="container-fluid p-4">
    <div class="d-flex justify-content-between align-items-center mb-4">
        <div class="d-flex align-items-baseline">
            <h2 class="mb-0 me-3">🎥 PTP4L 控制台 <small class="text-muted fs-5">Advanced Profile Manager</small></h2>
            <small class="text-muted" style="font-size: 0.85rem;">Designed & Developed by <strong>Vega Sun</strong></small>
        </div>
        <div>
            <span class="badge bg-dark">{{ os_label }}</span>
            <span class="badge bg-secondary">{{ hostname }}</span>
        </div>
    </div>
    <div class="row g-3 mb-4 align-items-stretch">
        <div class="col-md-3"><div id="statusCard" class="status-box bg-stopped shadow-sm"><h5>Systemd Service</h5><div id="serviceState" class="metric-val">STOPPED</div></div></div>
        <div class="col-md-3"><div class="card p-3 info-card d-flex flex-column justify-content-center"><small class="text-muted">PTP Port State</small><div id="portState" class="h3 mb-0">Offline</div></div></div>
        <div class="col-md-3"><div class="card p-3 info-card d-flex flex-column justify-content-center"><small class="text-muted">Offset from Master</small><div id="offsetVal" class="h3 mb-0">0 ns</div></div></div>
        <div class="col-md-3"><div class="card p-3 info-card d-flex flex-column justify-content-center"><small class="text-muted">Grandmaster ID</small><div id="gmId" class="h5 mb-0 text-primary text-break">Scanning...</div></div></div>
    </div>
    <div class="row g-3">
        <div class="col-xl-5 col-lg-6">
            <div class="card shadow-sm"><div class="card-header bg-white"><span class="fw-bold">🛠️ 配置中心 (Configuration)</span></div>
                <div class="card-body"><form id="configForm">
                        <div class="param-group border-primary border-opacity-25 bg-primary bg-opacity-10"><label class="form-label fw-bold text-primary">1. Profile 模板管理</label><div class="input-group mb-2"><select class="form-select" id="profileSelect" onchange="onProfileChange()"><option value="" disabled selected>加载配置模板...</option></select><button type="button" class="btn btn-outline-success" onclick="saveProfile()">💾 保存</button><button type="button" class="btn btn-outline-danger" onclick="deleteProfile()">🗑️ 删除</button></div><small class="text-muted">选择模板将自动填充下方的具体参数。</small></div>
                        <div class="param-group"><label class="form-label param-label">2. 基础设置 (Basic)</label><div class="mb-2"><label class="small text-muted">物理网卡 Interface</label><select class="form-select" id="interface">{% for nic in nics %}<option value="{{ nic }}">{{ nic }}</option>{% endfor %}</select></div></div>
                        <div class="param-group"><label class="form-label param-label">3. 核心参数 (PTP Parameters)</label>
                            <div class="row g-2 mb-2"><div class="col-md-4"><label class="small text-muted">Domain</label><input type="number" class="form-control" id="domain" value="0"></div><div class="col-md-4"><label class="small text-muted">Priority 1</label><input type="number" class="form-control" id="priority1" value="128"></div><div class="col-md-4"><label class="small text-muted">Priority 2</label><input type="number" class="form-control" id="priority2" value="128"></div></div>
                            <div class="row g-2 mb-2"><div class="col-md-6"><label class="small text-muted">Sync Interval</label><input type="number" class="form-control" id="logSyncInterval" value="0"></div><div class="col-md-6"><label class="small text-muted">Announce Interval</label><input type="number" class="form-control" id="logAnnounceInterval" value="1"></div></div>
                            <div class="row g-2"><div class="col-md-6"><label class="small text-muted">Delay Req Interval</label><input type="number" class="form-control" id="logMinDelayReqInterval" value="0"></div><div class="col-md-6"><label class="small text-muted">Receipt Timeout</label><input type="number" class="form-control" id="announceReceiptTimeout" value="3"></div></div>
                        </div>
                        <div class="d-grid gap-2"><button type="button" onclick="applyConfig()" class="btn btn-primary fw-bold">▶ APPLY & RESTART</button><button type="button" onclick="stopService()" class="btn btn-danger">■ STOP</button></div>
                    </form></div></div></div>
        <div class="col-xl-7 col-lg-6"><div class="card shadow-sm"><div class="card-header bg-white d-flex justify-content-between align-items-center"><span class="fw-bold">📜 实时日志</span><span class="badge bg-secondary" id="logTime">Updating...</span></div><div class="card-body"><div id="logWindow">Waiting for logs...</div></div></div></div>
    </div>
</div>
<script>
    let cachedProfiles = {};
    function init() { loadProfiles(); setInterval(updateStatus, 2000); setInterval(updateLogs, 3000); updateStatus(); updateLogs(); }
    function loadProfiles() {
        fetch('/api/profiles').then(r => r.json()).then(data => {
            cachedProfiles = data; const select = document.getElementById('profileSelect');
            select.innerHTML = '<option value="" disabled selected>-- 请选择模板加载 --</option>';
            const g1 = document.createElement('optgroup'); g1.label = "系统预设"; const g2 = document.createElement('optgroup'); g2.label = "用户自定义";
            for (const [k, p] of Object.entries(data)) { const opt = document.createElement('option'); opt.value = k; opt.innerText = p.name; (p.is_builtin ? g1 : g2).appendChild(opt); }
            select.appendChild(g1); select.appendChild(g2);
        });
    }
    function onProfileChange() {
        const p = cachedProfiles[document.getElementById('profileSelect').value]; if(!p) return;
        ['domain','priority1','priority2','logSyncInterval','logAnnounceInterval','logMinDelayReqInterval','announceReceiptTimeout'].forEach(k => document.getElementById(k).value = p[k]);
    }
    function saveProfile() {
        const name = prompt("Profile Name:"); if(!name) return;
        const config = {}; ['domain','priority1','priority2','logSyncInterval','logAnnounceInterval','logMinDelayReqInterval','announceReceiptTimeout'].forEach(k => config[k] = parseInt(document.getElementById(k).value));
        fetch('/api/profiles', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ name, config }) }).then(r => r.json()).then(res => { if(res.status === 'success') { alert("Saved!"); loadProfiles(); } else alert(res.message); });
    }
    function deleteProfile() {
        const key = document.getElementById('profileSelect').value; if(!key) return;
        if(cachedProfiles[key].is_builtin) { alert("Cannot delete built-in profile"); return; }
        if(confirm("Delete?")) fetch(`/api/profiles/${key}`, { method: 'DELETE' }).then(r => r.json()).then(res => { if(res.status==='success') { alert("Deleted"); loadProfiles(); } else alert(res.message); });
    }
    function applyConfig() {
        if(!confirm("Apply & Restart?")) return;
        const data = { interface: document.getElementById('interface').value };
        ['domain','priority1','priority2','logSyncInterval','logAnnounceInterval','logMinDelayReqInterval','announceReceiptTimeout'].forEach(k => data[k] = parseInt(document.getElementById(k).value));
        fetch('/api/apply', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(data) }).then(r => r.json()).then(res => { if(res.status==='success') setTimeout(updateStatus, 1000); else alert(res.message); });
    }
    function updateStatus() {
        fetch('/api/status').then(r => r.json()).then(data => {
            const card = document.getElementById('statusCard');
            if (data.port_state === "STOPPED") { card.className = 'status-box bg-stopped shadow-sm'; document.getElementById('serviceState').innerText = "STOPPED"; }
            else { card.className = 'status-box bg-running shadow-sm'; document.getElementById('serviceState').innerText = "RUNNING"; }
            document.getElementById('portState').innerText = data.port_state || "Offline";
            document.getElementById('gmId').innerText = data.gm_identity || "N/A";
            document.getElementById('offsetVal').innerText = (data.offset || "0") + " ns";
        });
    }
    function updateLogs() {
        fetch('/api/logs').then(r => r.json()).then(data => {
            const el = document.getElementById('logWindow'); const bottom = el.scrollHeight - el.clientHeight <= el.scrollTop + 50;
            el.innerText = data.logs; document.getElementById('logTime').innerText = new Date().toLocaleTimeString();
            if(bottom) el.scrollTop = el.scrollHeight;
        });
    }
    function stopService() { if(confirm("Stop Service?")) fetch('/api/stop', { method: 'POST' }).then(() => updateStatus()); }
    init();
</script>
</body>
</html>
EOF

# --- 8. 手动创建 Systemd 服务文件 (修复 Debian/Ubuntu 缺失) ---
echo "[6/7] 配置 PTP4L Systemd 服务..."
# 无论系统是否有默认服务，都直接创建/覆盖 /etc/systemd/system/ptp4l.service
# 这样既解决了 Debian 没服务的问题，也确保了 Fedora 读取正确的配置文件
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

# --- 9. 配置和启动 Web 服务 ---
echo "[7/7] 配置并启动 Web 服务..."
cat << 'EOF' > /etc/systemd/system/ptp-web.service
[Unit]
Description=PTP Web Controller UI
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ptp-web
ExecStart=/opt/ptp-web/.venv/bin/python /opt/ptp-web/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# --- 10. 服务激活与防火墙 ---
echo "重启 Systemd 并激活服务..."
systemctl daemon-reload
systemctl enable --now ptp-web
systemctl enable ptp4l

echo "配置防火墙端口 8080..."
# 检查 firewalld (Fedora/CentOS)
if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=8080/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    echo "   -> 已通过 firewall-cmd 放行"
# 检查 ufw (Debian/Ubuntu)
elif command -v ufw &> /dev/null; then
    ufw allow 8080/tcp >/dev/null 2>&1 || true
    echo "   -> 已通过 ufw 放行"
else
    echo "   ⚠️ 未检测到常用防火墙管理工具，请手动放行 TCP 8080"
fi

# 权限修正 (防止SELinux拦截)
if command -v chcon &> /dev/null; then
    chcon -R -t httpd_sys_content_t /opt/ptp-web >/dev/null 2>&1 || true
fi

# 获取 IP
IP=$(hostname -I | awk '{print $1}')
echo "========================================================"
echo "   ✅ 安装完成！ SUCCESS!"
echo "   请访问: http://$IP:8080"
echo "========================================================"
