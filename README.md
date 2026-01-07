# PTP4L Web Controller (v4.0 Stable)

专为广播电视工程师设计的 Linux PTP (Precision Time Protocol) 管理面板。针对 SMPTE ST 2110 和 AES67 场景进行了深度优化。

A lightweight PTP management dashboard designed for Broadcast Engineers. deeply optimized for SMPTE ST 2110 and AES67 workflows.

<img width="2498" height="1094" alt="image" src="https://github.com/user-attachments/assets/831805c6-df25-4d77-a1fa-e39eeeb8173c" />


## ✨ 核心特性 (Key Features)

*   **PTP Client Radar (Stable)**: 实时探测网络中的所有 PTP 客户端 (基于 `tcpdump` 监听端口 319)。
    *   *Real-time detection of all PTP clients on the network (based on `tcpdump` monitoring port 319).*
*   **BMCA Visualizer**: 可视化 Best Master Clock Algorithm 决策过程，直观展示为何锁定特定 Grandmaster。
    *   *Visualize the BMCA decision process to understand why a specific Grandmaster is selected.*
*   **Smart Injection & Traceable Flags**: 包含 `ptp-inject` 工具，可强制注入 ST 2110 所需的 `timeTraceable` 和 `frequencyTraceable` 标志。
    *   *Includes `ptp-inject` tool to enforce `timeTraceable` & `frequencyTraceable` flags required by ST 2110.*
*   **Profile Management**: 内置多种广播预设配置 (Built-in Broadcast Profiles):
    *   **Default**: IEEE 1588 Standard
    *   **AES67**: Media Profile (`logSyncInterval: -3`)
    *   **SMPTE ST 2059-2**: Broadcast Profile (`domain: 127`, `announceReceiptTimeout: 3`)
*   **System Integrity**:
    *   **Atomic Writes**: 安全的配置文件写入机制 (Safe configuration updates).
    *   **Safe Wrapper**: 独立的 `phc2sys-custom` 服务，防止系统时间突变 (Prevents system clock jumps).
*   **Systemd Integration**: 自动配置 `ptp4l` 和 `ptp-web` 系统服务，集成 `journalctl` 日志流。
    *   *Automatic setup of system services and log integration.*

## 🚀 安装指南 (Installation)

### 环境要求 (Prerequisites)
*   **OS**: Fedora / CentOS Stream / RHEL / Ubuntu / Debian
*   **User**: Root access required (`EUID 0`)
*   **Hardware**: Network card supporting hardware PTP / Timestamping (Recommended)

### 在线安装 (Online Installation)

直接运行安装脚本即可。脚本会自动检测网络、同步时间、安装依赖 (`linuxptp`, `ethtool`, `python3`, `tcpdump`) 并配置防火墙。

Simply run the script. It will automatically check connectivity, sync time, install dependencies, and configure the firewall.

```bash
# 赋予执行权限并运行
# Grant execution permission and run
chmod +x install.sh
bash ./install.sh
```

脚本将自动执行以下步骤 (The script performs the following):
1.  **[0/8]** 检测网络环境 (Checks Network Environment)
2.  **[1/8]** 校准系统时间 (Syncs System Time) - *Skips in LXC containers*
3.  **[2/8]** 清理旧服务与文件 (Cleans up old services)
4.  **[2/8]** 安装基础依赖 (Installs Dependencies: `ptp4l`, `ethtool`, `python3`, `tcpdump`)
5.  **[3/8]** 生成 `ptp-inject` 工具 (Generates Injection Tool)
6.  **[4/8]** 部署 Python 后端 `app.py` (Deploys Backend)
7.  **[5/8]** 部署 Web UI (Deploys Frontend)
8.  **[6/8]** 配置 Python 虚拟环境 (Configures Python Environment)
9.  **[7/8]** 注册 Systemd 服务 (Registers System Services)
10. **[8/8]** 配置防火墙端口 (Configures Firewall)

### 离线安装 (Offline Installation)

如果脚本检测到无法连接互联网，将进入离线模式。请确保满足以下条件：
If the script detects no internet connection, it enters offline mode. Please ensure:

1.  **依赖包 (Dependencies)**: 需手动预装 `linuxptp`, `ethtool`, `python3`, `tcpdump`。
    *   *Must be pre-installed manually (via ISO or rpm/deb).*
2.  **Python 环境 (Python Env)**:
    *   方法 A (推荐): 在联网机器运行脚本生成 `.venv` 目录，打包拷贝至本机的 `/opt/ptp-web/.venv`。
    *   *Method A (Rec): Generate `.venv` on an online machine and copy it to `/opt/ptp-web/.venv`.*
    *   方法 B: 确保系统预装了 `python3-flask` 和 `python3-gunicorn`。
    *   *Method B: Ensure system packages `python3-flask` and `python3-gunicorn` are installed.*

## 🖥️ 使用说明 (Usage)

安装完成后，服务将自动启动。
After installation, services start automatically.

*   **URL**: `http://<YOUR_SERVER_IP>:8080`
*   **First Run**: 请务必点击页面底部的 **Apply & Restart** 按钮以初始化 PTP 配置。
    *   *Make sure to click **Apply & Restart** on the web UI to initialize PTP configuration.*

### 系统服务 (System Services)

| Service Name | Description |
| :--- | :--- |
| `ptp-web` | Web 控制台 UI (Gunicorn/Flask) |
| `ptp4l` | PTP 主协议进程 (LinuxPTP) |
| `phc2sys-custom` | 自动生成的安全系统时钟同步服务 |

### 文件路径 (File Paths)

*   **App Directory**: `/opt/ptp-web`
*   **Config File**: `/etc/linuxptp/ptp4l.conf`
*   **Injector Tool**: `/usr/local/bin/ptp-inject`
*   **Profiles**: `/opt/ptp-web/user_profiles.json`

### 端口占用 (Ports)

*   **TCP 8080**: Web UI
*   **UDP 319**: PTP Event Message
*   **UDP 320**: PTP General Message


#### Designed by Vega Sun

#### Developed by Gemini3.0 Pro


<img width="1564" height="969" alt="image" src="https://github.com/user-attachments/assets/32174b31-4d28-4e4c-ba1a-12e0d45cb654" />

BC模式运行，将位于10.1.3.0/24网段主时钟分发至192.168.42.0/24网段

In BC mode operation, the master clock located in the 10.1.3.0/24 is distributed to the 192.168.42.0/24.

<img width="1501" height="469" alt="image" src="https://github.com/user-attachments/assets/d0fa648f-9893-40fe-b438-4c2acc19edb1" />

位于192.168.42.0/24网段设备已锁定

Device located in the 192.168.42.0/24 have been locked.

<img width="1511" height="462" alt="image" src="https://github.com/user-attachments/assets/829439cb-1316-4c48-976d-caa6bc92d31e" />

位于10.1.3.0/24网段设备已锁定

Device located in the 10.1.3.0/24 have been locked.

<img width="595" height="238" alt="image" src="https://github.com/user-attachments/assets/c9491155-afbb-4500-a116-326b712f4cf3" />

主时钟设备

GM device


## 测试环境

Fedora43 Server，2 x Intel I226-V网卡

请确认网卡支持硬件PTP，可通过ethtool -T <网卡名> 来确认

### 示例：

<img width="570" height="318" alt="image" src="https://github.com/user-attachments/assets/55571e51-a04b-444b-b5f7-6b1d3d745bc8" />



