# 🎥 PTP4L Web Controller

一个轻量级、可视化的 Linux PTP (Precision Time Protocol) 管理面板。专为广电 IP 化 (SMPTE ST 2110) 及高精度时间同步场景设计。

Designed & Developed by Vega Sun

<img width="1564" height="969" alt="image" src="https://github.com/user-attachments/assets/32174b31-4d28-4e4c-ba1a-12e0d45cb654" />

BC模式运行，将位于10.1.3.0/24网段主时钟分发至192.168.42.0/24网段

<img width="1501" height="469" alt="image" src="https://github.com/user-attachments/assets/d0fa648f-9893-40fe-b438-4c2acc19edb1" />

位于192.168.42.0/24网段设备已锁定

<img width="1511" height="462" alt="image" src="https://github.com/user-attachments/assets/829439cb-1316-4c48-976d-caa6bc92d31e" />

位于10.1.3.0/24网段设备已锁定

<img width="595" height="238" alt="image" src="https://github.com/user-attachments/assets/c9491155-afbb-4500-a116-326b712f4cf3" />

主时钟设备


## 测试环境

Fedora43 Server，2 x Intel I226-V网卡

请确认网卡支持硬件PTP，可通过ethtool -T <网卡名> 来确认

### 示例：

<img width="570" height="318" alt="image" src="https://github.com/user-attachments/assets/55571e51-a04b-444b-b5f7-6b1d3d745bc8" />



# ✨ 功能特性

📊 实时状态监控：直观显示 PTP 端口状态、Master Offset (偏差值)、Grandmaster ID。

⚙️ Profile 模板管理：内置 Default (IEEE 1588)、AES67、SMPTE ST 2059-2 预设，支持自定义保存/加载配置。

📜 实时日志流：集成 Systemd 日志，实时查看 ptp4l 运行详情 (支持 Offset/RMS 自动抓取)。

🔧 一键部署：自动处理 Systemd 服务依赖、防火墙端口及 Python 环境。

💻 跨发行版支持：完美支持 Fedora 43+, CentOS Stream 9, Ubuntu 22.04+, Debian 12+。

# 🚀 快速开始 (Quick Start)

在服务器上运行以下命令即可完成安装：

## 下载并运行安装脚本

    curl -O https://raw.githubusercontent.com/SileNt525/ptp4l-web-controller/main/install.sh
    chmod +x install.sh
    bash ./install.sh

安装完成后，访问：http://<服务器IP>:8080

# 🛠️ 手动安装

如果你想手动部署或进行二次开发：

## 安装依赖：

### Fedora/CentOS

    dnf install linuxptp ethtool python3

### Debian/Ubuntu

    apt install linuxptp ethtool python3 python3-venv

## 克隆仓库：

    git clone https://github.com/SileNt525/ptp4l-web-controller.git
    cd ptp4l-web-controller/source

## 运行：

    python3 -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt
    python3 app.py

(注意：手动运行需要 root 权限以控制 systemctl)

# 📄 License
本项目基于 MIT License 开源。
