#!/bin/bash
set -e

# ================================================================
#   PTP4L Web Controller (v3.2 All-in-One Installer)
#   Author: Vega Sun & Expert Assistant
#   Target: Fresh Linux Install (CentOS/RHEL/Ubuntu/Debian)
#   Features: 
#     - Auto Time Sync (Fix SSL issues)
#     - Auto Firewall Config (Port 8080)
#     - Gunicorn + Systemd Production Setup
#     - Full Source Code Embedded
# ================================================================

# --- 1. Root 权限检查 ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 root 用户运行此脚本"
  exit 1
fi

echo "🚀 开始全自动部署 (v3.2)..."

# --- 2. 紧急时间校准 (关键步骤) ---
# 全新系统时间经常不准，这会导致 pip 安装时的 SSL 证书错误
echo "[1/8] 检查并校准系统时间..."
if command -v curl &> /dev/null; then
    # 尝试从百度抓取 HTTP 头时间 (无需 SSL)
    NET_TIME=$(curl -I --insecure http://www.baidu.com 2>/dev/null | grep ^Date: | sed 's/Date: //g')
    if [ -n "$NET_TIME" ]; then
        date -s "$NET_TIME" >/dev/null
        echo "   ✅ 时间已校准为: $(date)"
    else
        echo "   ⚠️ 无法获取网络时间，跳过校准 (请确保时间大致正确)"
    fi
else
    echo "   ⚠️ 未找到 curl，跳过时间校准"
fi

# --- 3. 清理旧环境 ---
echo "[2/8] 清理旧服务..."
systemctl stop ptp-web ptp4l phc2sys 2>/dev/null || true
systemctl disable phc2sys 2>/dev/null || true
rm -f /etc/systemd/system/phc2sys.service
rm -f /etc/linuxptp/phc2sys.env
systemctl daemon-reload

# --- 4. 安装系统级依赖 ---
echo "[3/8] 安装系统基础依赖..."
if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else OS="unknown"; fi
COMMON_PKGS="linuxptp ethtool python3 python3-pip curl"

if [[ "$OS" =~ (fedora|rhel|centos|rocky|almalinux) ]]; then
    # RHEL 系
    echo "   检测到 RHEL/CentOS 系系统..."
    dnf install -y $COMMON_PKGS
elif [[ "$OS" =~ (debian|ubuntu|kali|linuxmint) ]]; then
    # Debian 系 (需额外安装 venv)
    echo "   检测到 Debian/Ubuntu 系系统..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y $COMMON_PKGS python3-venv
else
    echo "⚠️ 未知系统 ($OS)，尝试继续..."
fi

# --- 5. 初始化目录 ---
echo "[4/8] 建立目录结构..."
INSTALL_DIR="/opt/ptp-web"
mkdir -p "$INSTALL_DIR/templates"
mkdir -p /etc/linuxptp

# --- 6. 写入核心文件 (Embed) ---
echo "[5/8] 释放核心代码..."

# 6.1 Requirements
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

# 6.2 APP.PY (v3.1 Final Logic)
cat << 'EOF' > "$INSTALL_DIR/app.py"
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

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = "/etc/linuxptp/ptp4l.conf"
USER_PROFILES_FILE = os.path.join(BASE_DIR, "user_profiles.json")

BUILTIN_PROFILES = {
    "default": { "name": "Default (IEEE 1588)", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": 0, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3 },
    "aes67": { "name": "AES67 (Media)", "domain": 0, "priority1": 128, "priority2": 128, "logAnnounceInterval": 1, "logSyncInterval": -3, "logMinDelayReqInterval": 0, "announceReceiptTimeout": 3 },
    "st2059": { "name": "SMPTE ST 2059-2 (Broadcast)", "domain": 127, "priority1": 128, "priority2": 128, "logAnnounceInterval": -2, "logSyncInterval": -3, "logMinDelayReqInterval": -2, "announceReceiptTimeout": 3 }
}

def run_cmd_safe(cmd_list):
    try:
        result = subprocess.check_output(cmd_list, stderr=subprocess.STDOUT, timeout=1)
        return result.decode('utf-8', errors='ignore')
    except:
        return ""

def get_pmc_dict():
    cmd = ["pmc", "-u", "-b", "0", "-d", "0", "GET PORT_DATA_SET", "GET PARENT_DATA_SET", "GET DEFAULT_DATA_SET", "GET CURRENT_DATA_SET"]
    output = run_cmd_safe(cmd)
    data = {}
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
            
    m = re.search(r'grandmasterIdentity\s+([0-9a-fA-F\.]+)', output)
    if m: data['gm_id'] = m.group(1)
    
    m = re.search(r'clockIdentity\s+([0-9a-fA-F\.]+)', output)
    if m: data['clock_id'] = m.group(1)
    
    m = re.search(r'offsetFromMaster\s+([0-9\.\-]+)', output)
    if m: data['offset'] = m.group(1)
    
    return data

def load_user_profiles():
    if os.path.exists(USER_PROFILES_FILE):
        try: 
            with open(USER_PROFILES_FILE, 'r') as f: 
                return json.load(f)
        except: 
            return {}
    return {}

def save_user_profiles(p):
    with open(USER_PROFILES_FILE, 'w') as f: 
        json.dump(p, f, indent=4)

def restart_ptp_async():
    def _restart():
        time.sleep(0.5)
        subprocess.run(["systemctl", "restart", "ptp4l"], check=False)
    threading.Thread(target=_restart).start()

def safe_int(v, d=0):
    try: 
        return int(v)
    except: 
        return d

@app.route('/')
def index():
    nics = []
    try: 
        nics = sorted([n for n in os.listdir('/sys/class/net/') if not n.startswith('lo')])
    except: 
        pass
    return render_template('index.html', nics=nics, hostname=socket.gethostname())

@app.route('/api/profiles', methods=['GET', 'POST'])
def handle_profiles():
    if request.method == 'GET':
        u = load_user_profiles()
        c = {k: {**v, 'is_builtin': True, 'id': k} for k, v in BUILTIN_PROFILES.items()}
        for k, v in u.items(): 
            c[k] = {**v, 'is_builtin': False, 'id': k}
        return jsonify(c)
    
    req = request.json
    name = req.get('name', 'Untitled')
    pid = "user_" + re.sub(r'\W+', '_', name).lower()
    p = load_user_profiles()
    p[pid] = req['config']
    p[pid]['name'] = name
    save_user_profiles(p)
    return jsonify({"status": "success", "id": pid})

@app.route('/api/profiles/<pid>', methods=['DELETE'])
def delete_profile(pid):
    p = load_user_profiles()
    if pid in p: 
        del p[pid]
        save_user_profiles(p)
        return jsonify({"status": "success"})
    return jsonify({"status": "error"}), 404

@app.route('/api/apply', methods=['POST'])
def apply_config():
    req = request.json
    mode = req.get('clockMode', 'OC')
    
    if os.path.exists(CONFIG_FILE): 
        shutil.copy(CONFIG_FILE, CONFIG_FILE + ".bak")
        
    try:
        cfg = f"[global]\nnetwork_transport UDPv4\ntime_stamping hardware\ndelay_mechanism E2E\n"
        cfg += f"domainNumber {safe_int(req.get('domain'))}\npriority1 {safe_int(req.get('priority1'),128)}\n"
        cfg += f"priority2 {safe_int(req.get('priority2'),128)}\nlogAnnounceInterval {safe_int(req.get('logAnnounceInterval'),1)}\n"
        cfg += f"logSyncInterval {safe_int(req.get('logSyncInterval'))}\nlogMinDelayReqInterval {safe_int(req.get('logMinDelayReqInterval'))}\n"
        cfg += f"announceReceiptTimeout {safe_int(req.get('announceReceiptTimeout'),3)}\n"
        cfg += f"logging_level 6\nuse_syslog 1\nverbose 1\n"
        
        if mode == 'BC': 
            cfg += "boundary_clock_jbod 1\n\n"
        else: 
            cfg += "\n"

        if mode == 'BC':
            s, m = req.get('bcSlaveIf'), req.get('bcMasterIf')
            if not s or not m: 
                return jsonify({"status":"error", "message":"BC needs 2 interfaces"}), 400
            cfg += f"[{s}]\n\n[{m}]\nmasterOnly 1\n"
        else:
            i = req.get('interface')
            if not i: 
                return jsonify({"status":"error", "message":"Interface missing"}), 400
            cfg += f"[{i}]\n"
            
        with open(CONFIG_FILE, 'w') as f: 
            f.write(cfg)
            
        restart_ptp_async()
        return jsonify({"status": "success"})
    except Exception as e: 
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/status')
def get_status():
    d = {"ptp4l":"STOPPED","port":"Offline","offset":"0","gm":"Scanning...","is_self":False}
    if run_cmd_safe(["pgrep","-x","ptp4l"]): 
        d["ptp4l"]="RUNNING"
        
    if d["ptp4l"]=="RUNNING":
        p = get_pmc_dict()
        if 'port_state' in p: d["port"]=p['port_state']
        if 'offset' in p: d["offset"]=p['offset']
        if 'gm_id' in p:
            d["gm"]=p['gm_id']
            if 'clock_id' in p and p['gm_id']==p['clock_id']: 
                d["is_self"]=True
                d["gm"]+=" (Self)"
        if d["port"] in ["MASTER","GRAND_MASTER"]: 
            d["offset"]="0"
            d["is_self"]=True
            
    return jsonify(d)

@app.route('/api/logs')
def get_logs(): 
    return jsonify({"logs": run_cmd_safe(["journalctl","-u","ptp4l","-n","50","--no-pager","--output","cat"])})

@app.route('/api/stop', methods=['POST'])
def stop_service():
    subprocess.run(["systemctl","stop","ptp4l"], check=False)
    return jsonify({"status":"success"})
EOF

# 6.3 INDEX.HTML
cat << 'EOF' > "$INSTALL_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PTP Controller v3.2 by Vega Sun</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        .status-box { padding: 15px; border-radius: 8px; color: white; height: 100%; display: flex; flex-direction: column; justify-content: center; }
        .bg-running { background-color: #198754; } 
        .bg-stopped { background-color: #dc3545; }
        .bg-slave { background-color: #0d6efd; }
        .bg-master { background-color: #6610f2; }
        .bg-init { background-color: #ffc107; color: black; }
        #logWindow { background-color: #212529; color: #0f0; height: 450px; overflow-y: auto; padding: 10px; font-family: monospace; font-size: 0.8rem; }
    </style>
</head>
<body class="bg-light">
<div class="container-fluid p-4">
    <div class="d-flex justify-content-between align-items-center mb-3">
        <h3 class="mb-0">⏱️ PTP4L Controller by Vega Sun <small class="text-muted fs-6">v3.2</small></h3>
        <span class="badge bg-secondary">{{ hostname }}</span>
    </div>
    <div class="row g-3 mb-3">
        <div class="col-md-4">
            <div id="ptpCard" class="status-box bg-stopped shadow-sm">
                <small>Device State</small>
                <div id="ptpState" class="h3 mb-0">STOPPED</div>
                <small id="serviceStateDetail" class="opacity-75">Service Inactive</small>
            </div>
        </div>
        <div class="col-md-4">
            <div class="card h-100 p-3 shadow-sm justify-content-center">
                <small class="text-muted">Offset</small>
                <div id="offsetVal" class="h3 mb-0 text-primary">--</div>
                <small>ns</small>
            </div>
        </div>
        <div class="col-md-4">
            <div class="card h-100 p-3 shadow-sm justify-content-center">
                <small class="text-muted">Grandmaster ID</small>
                <div id="gmId" class="h6 mb-0 text-break font-monospace">Scanning...</div>
            </div>
        </div>
    </div>
    <div class="row g-3">
        <div class="col-lg-4">
            <div class="card shadow-sm">
                <div class="card-header fw-bold">⚙️ Configuration</div>
                <div class="card-body">
                    <form id="configForm">
                        <div class="mb-3">
                            <label class="form-label fw-bold small text-uppercase text-secondary">Clock Mode</label>
                            <select class="form-select" id="clockMode" onchange="toggleMode()">
                                <option value="OC" selected>Ordinary Clock (Single Port)</option>
                                <option value="BC">Boundary Clock (Dual Port)</option>
                            </select>
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
                        <hr>
                        <div class="mb-2"><label class="small text-muted">Profile</label><div class="input-group input-group-sm"><select class="form-select" id="profileSelect" onchange="loadProfileData()"></select><button type="button" class="btn btn-outline-secondary" onclick="saveProfile()">Save</button></div></div>
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
    let profiles={}; const FIELDS=['domain','priority1','priority2','logSyncInterval','logAnnounceInterval','logMinDelayReqInterval','announceReceiptTimeout'];
    function init(){ fetchProfiles(); setInterval(updateStatus,1500); setInterval(updateLogs,3000); }
    function toggleMode(){ const m=document.getElementById('clockMode').value; document.getElementById('ocPanel').style.display=(m==='OC'?'block':'none'); document.getElementById('bcPanel').style.display=(m==='BC'?'block':'none'); }
    function fetchProfiles(){ fetch('/api/profiles').then(r=>r.json()).then(d=>{ profiles=d; const s=document.getElementById('profileSelect'); s.innerHTML='<option disabled selected>-- Select --</option>'; for(let i in d){ let o=document.createElement('option'); o.value=i; o.text=d[i].name+(d[i].is_builtin?"*":""); s.add(o); } }); }
    function loadProfileData(){ const p=document.getElementById('profileSelect').value; if(profiles[p]) FIELDS.forEach(f=>{ let el=document.getElementById(f); if(el) el.value=profiles[p][f]||0; }); }
    function applyConfig(){
        const m=document.getElementById('clockMode').value; const d={clockMode:m};
        if(m==='BC'){ d.bcSlaveIf=document.getElementById('bcSlaveIf').value; d.bcMasterIf=document.getElementById('bcMasterIf').value; if(!d.bcSlaveIf||!d.bcMasterIf||d.bcSlaveIf===d.bcMasterIf){ alert("Invalid BC Interface Config"); return; } }
        else{ d.interface=document.getElementById('interface').value; if(!d.interface){ alert("Select Interface"); return; } }
        if(!confirm("Apply & Restart?")) return;
        FIELDS.forEach(f=>{ let el=document.getElementById(f); d[f]=el?el.value:0; });
        fetch('/api/apply',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(r=>r.json()).then(r=>{ if(r.status==='success') alert("✅ Success!"); else alert("❌ "+r.message); }).catch(e=>alert("Error:"+e));
    }
    function updateStatus(){ fetch('/api/status').then(r=>r.json()).then(d=>{
        const c=document.getElementById('ptpCard'), t=document.getElementById('ptpState');
        if(d.ptp4l==='RUNNING'){
            t.innerText=d.port||"UNKNOWN"; document.getElementById('serviceStateDetail').innerText="Running";
            if(d.port==='SLAVE') c.className='status-box bg-slave shadow-sm'; else if(d.port==='MASTER'||d.port==='GRAND_MASTER') c.className='status-box bg-master shadow-sm'; else c.className='status-box bg-running shadow-sm';
        } else { c.className='status-box bg-stopped shadow-sm'; t.innerText="STOPPED"; document.getElementById('serviceStateDetail').innerText="Inactive"; }
        document.getElementById('offsetVal').innerText=d.offset; document.getElementById('gmId').innerText=d.gm||"N/A";
    }).catch(()=>{}); }
    function updateLogs(){ fetch('/api/logs').then(r=>r.json()).then(d=>{ const w=document.getElementById('logWindow'); if(w){ w.innerText=d.logs; w.scrollTop=w.scrollHeight; } }).catch(()=>{}); }
    function saveProfile(){ let n=prompt("Name:"); if(n){ let c={}; FIELDS.forEach(f=>c[f]=document.getElementById(f).value); fetch('/api/profiles',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,config:c})}).then(()=>fetchProfiles()); } }
    function stopService(){ if(confirm("Stop?")) fetch('/api/stop',{method:'POST'}); }
    init();
</script>
</body>
</html>
EOF

# --- 7. 配置 Python 环境 ---
echo "[6/8] 配置 Python 虚拟环境..."
cd "$INSTALL_DIR"
# 即使有旧的也删除，确保依赖纯净
rm -rf .venv
python3 -m venv .venv
./.venv/bin/pip install --upgrade pip
# 安装锁定的依赖
./.venv/bin/pip install -r requirements.txt

# --- 8. 配置 Systemd & Firewall ---
echo "[7/8] 配置服务与防火墙..."

# 8.1 防火墙配置 (放行 8080)
if command -v firewall-cmd &> /dev/null; then
    echo "   正在配置 firewalld (CentOS/RHEL)..."
    firewall-cmd --permanent --add-port=8080/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v ufw &> /dev/null; then
    echo "   正在配置 ufw (Ubuntu/Debian)..."
    ufw allow 8080/tcp >/dev/null 2>&1 || true
fi

# 8.2 Systemd 服务
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

# --- 9. 启动 ---
echo "[8/8] 启动服务..."
systemctl daemon-reload
systemctl enable ptp4l ptp-web
systemctl restart ptp-web

# 获取 IP (兼容精简版系统)
if command -v hostname &> /dev/null; then
    IP=$(hostname -I | awk '{print $1}')
else
    IP=$(ip route get 1 | awk '{print $7;exit}')
fi

echo "=========================================================="
echo "   ✅ PTP4L 控制台安装完成 (v3.2)！"
echo "   👉 访问地址: http://$IP:8080"
echo "   👉 功能: 监控 + BC 模式 + 无 PHC 干扰"
echo "=========================================================="
