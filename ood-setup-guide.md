# Slurm- & Open-OnDemand-HPC-Sandbox unter WSL2

Hier ist die vollständige, reproduzierbare Installations- und Konfigurationsübersicht deiner gesamten Slurm- & Open-OnDemand-HPC-Sandbox unter WSL2 – inklusive aller relevanten Bash-Befehle zum Nachschlagen oder Neuaufsetzen.

## 1. Basis-Sandbox & Container-Startskript (~/ood-ctl.sh)

Aufbau der beschreibbaren Ubuntu-24.04-Sandbox mit Systemd-Boot, Mount-Punkten für GPU und Projekte sowie socat-Port-Forwarding auf Port 443.

### 1.1. Host-Verzeichnisse und Sandbox vorbereiten

```bash
mkdir -p ~/hpc-projects
sudo apptainer build --sandbox ~/ood-sandbox docker://ubuntu:24.04
sudo mkdir -p ~/ood-sandbox/usr/lib/wsl ~/ood-sandbox/dev ~/ood-sandbox/home/hpcuser/projects
sudo touch ~/ood-sandbox/dev/dxg
```

### 1.2. Zentrales Steuerungsskript ~/ood-ctl.sh anlegen

```bash
cat << 'EOF' > ~/ood-ctl.sh
#!/usr/bin/env bash
set -e

SANDBOX_DIR="$HOME/ood-sandbox"
INSTANCE_NAME="ood-cluster"
BIND_MOUNTS="$HOME/hpc-projects:/home/hpcuser/projects,/usr/lib/wsl:/usr/lib/wsl,/dev/dxg:/dev/dxg"

case "$1" in
  start)
    echo "Starting Apptainer instance '$INSTANCE_NAME'..."
    sudo apptainer instance start --writable --boot --keep-privs --bind "$BIND_MOUNTS" "$SANDBOX_DIR" "$INSTANCE_NAME"
    sleep 3

    sudo apptainer exec --pwd /root "instance://$INSTANCE_NAME" mount -o remount,suid /
    sudo apptainer exec --pwd /root "instance://$INSTANCE_NAME" bash -c 'grep -q "ood-cluster" /etc/hosts || echo "127.0.0.1 ood-cluster" >> /etc/hosts'

    CONTAINER_IP=$(sudo apptainer exec --pwd /root "instance://$INSTANCE_NAME" grep -B1 "32 host LOCAL" /proc/net/fib_trie | awk '/10\.22\./ {print $2}' | head -n1)
    sudo pkill socat 2>/dev/null || true
    sudo nohup socat TCP-LISTEN:443,fork,reuseaddr TCP:${CONTAINER_IP}:443 >/dev/null 2>&1 &

    echo "Open OnDemand live at https://localhost (Container IP: $CONTAINER_IP)"
    ;;
  stop)
    sudo pkill socat 2>/dev/null || true
    sudo apptainer instance stop "$INSTANCE_NAME" 2>/dev/null || true
    echo "Stopped."
    ;;
  restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;
  shell)
    sudo apptainer shell --pwd /root "instance://$INSTANCE_NAME"
    ;;
  status)
    sudo apptainer instance list
    sudo apptainer exec --pwd /root "instance://$INSTANCE_NAME" sinfo
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|shell|status}"
    exit 1
    ;;
esac
EOF
chmod +x ~/ood-ctl.sh
```

## 2. Systempakete, Benutzer-UID & NVIDIA RTX 2060 im Container

Installation von Slurm, Open OnDemand, SSH und CUDA-Toolkit sowie Angleichung der Benutzer-ID (1000:1000) an den WSL-Host.

```bash
HOST_UID=$(id -u)
HOST_GID=$(id -g)

sudo apptainer exec --pwd /root instance://ood-cluster bash -c "
export DEBIAN_FRONTEND=noninteractive

# Basis-Pakete & Open OnDemand Repository einrichten
apt-get update && apt-get install -y curl wget gnupg2 lsb-release ca-certificates sudo rsync git \
  apache2 apache2-utils openssh-server slurm-wlm munge python3-pip \
  nvidia-cuda-toolkit build-essential

# Open OnDemand installieren (Beispiel für Ubuntu 24.04 / Noble)
wget -O /tmp/ood-release.deb https://osc.edu
apt-get install -y /tmp/ood-release.deb && apt-get update && apt-get install -y ondemand
rm -f /tmp/ood-release.deb

# NVIDIA WSL2 Treiber & nvidia-smi verlinken
ln -sf /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi
echo '/usr/lib/wsl/lib' > /etc/ld.so.conf.d/wsl-nvidia.conf
ldconfig

# Benutzer 'hpcuser' mit identischer Host-UID/GID anlegen
id -u ${HOST_UID} >/dev/null 2>&1 && userdel -r \$(id -un ${HOST_UID}) 2>/dev/null || true
groupadd -g ${HOST_GID} hpcuser
useradd -m -u ${HOST_UID} -g ${HOST_GID} -s /bin/bash hpcuser
echo 'hpcuser:password' | chpasswd
htpasswd -cb /etc/apache2/.htpasswd hpcuser password
"
```

## 3. Slurm-Konfiguration (8 Kerne, RAM & RTX 2060 GPU)

Single-Node-Setup mit 8 physischen Kernen, 90 % des verfügbaren RAMs und GRES-GPU-Zuweisung (--gres=gpu:1).

```bash
sudo apptainer exec --pwd /root instance://ood-cluster bash -c '
TOTAL_MEM=$(free -m | awk "/^Mem:/ {print int(\$2 * 0.9)}")

cat << EOF > /etc/slurm/slurm.conf
ClusterName=wsl-sandbox
SlurmctldHost=localhost
MpiDefault=none
ProctrackType=proctrack/linuxproc
ReturnToService=2
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurm/d
StateSaveLocation=/var/spool/slurm/ctld
SwitchType=switch/none
TaskPlugin=task/none
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
GresTypes=gpu
NodeName=localhost CPUs=8 RealMemory=${TOTAL_MEM} Gres=gpu:1 State=UNKNOWN
PartitionName=debug Nodes=localhost Default=YES MaxTime=INFINITE State=UP
EOF

cat << "EOF" > /etc/slurm/gres.conf
NodeName=localhost Name=gpu Count=1
EOF

mkdir -p /var/spool/slurm/ctld /var/spool/slurm/d
chown -R slurm:slurm /var/spool/slurm /etc/slurm/gres.conf
systemctl enable --now munge slurmctld slurmd ssh
scontrol update NodeName=localhost State=RESUME
'
```

## 4. Open OnDemand Portal & Cluster-Anbindung

Konfiguration von Apache-SSL, Basic-Auth, Reverse-Proxy (/node & /rnode) sowie dem Cluster-Profil wsl.yml.

```bash
sudo apptainer exec --pwd /root instance://ood-cluster bash -c '
mkdir -p /etc/ood/config/clusters.d

cat << "EOF" > /etc/ood/config/ood_portal.yml
servername: localhost
port: 443
ssl:
  - '\''SSLCertificateFile "/etc/ssl/certs/ssl-cert-snakeoil.pem"'\''
  - '\''SSLCertificateKeyFile "/etc/ssl/private/ssl-cert-snakeoil.key"'\''
auth:
  - '\''AuthType Basic'\''
  - '\''AuthName "Open OnDemand Sandbox"'\''
  - '\''AuthBasicProvider file'\''
  - '\''AuthUserFile "/etc/apache2/.htpasswd"'\''
  - '\''RequestHeader unset Authorization'\''
  - '\''Require valid-user'\''
node_uri: '\''/node'\''
rnode_uri: '\''/rnode'\''
host_regex: '\''[^/]+'\''
EOF

cat << "EOF" > /etc/ood/config/clusters.d/wsl.yml
---
v2:
  metadata:
    title: "WSL Sandbox Cluster"
  login:
    host: "localhost"
  job:
    adapter: "slurm"
    bin: "/usr/bin"
    conf: "/etc/slurm/slurm.conf"
EOF

/opt/ood/ood-portal-generator/sbin/update_ood_portal
systemctl enable --now apache2
'
```

## 5. Interaktive App 1: JupyterLab (inkl. GPU-, CPU- & RAM-Dropdowns)

Installation von jupyterlab und Erstellung der App-Dateien mit automatischem Token-Login.

```bash
sudo apptainer exec --pwd /root instance://ood-cluster bash -c '
pip3 install --break-system-packages jupyterlab
mkdir -p /var/www/ood/apps/sys/jupyter/template

cat << "EOF" > /var/www/ood/apps/sys/jupyter/manifest.yml
---
name: JupyterLab
category: Interactive Apps
subcategory: Servers
role: batch_connect
description: "JupyterLab auf dem WSL Sandbox Cluster"
EOF

cat << "EOF" > /var/www/ood/apps/sys/jupyter/form.yml
---
cluster: "wsl"
attributes:
  gpu_mode:
    widget: "select"
    label: "Hardware-Beschleunigung"
    options:
      - ["CPU only (Standard)", ""]
      - ["NVIDIA GeForce RTX 2060 (1 GPU)", "gpu:1"]
  num_cores:
    widget: "number_field"
    label: "Anzahl CPU-Kerne"
    value: 2
    min: 1
    max: 8
    step: 1
  memory_gb:
    widget: "select"
    label: "Arbeitsspeicher (RAM)"
    options:
      - ["2 GB", "2G"]
      - ["4 GB", "4G"]
      - ["8 GB", "8G"]
      - ["16 GB", "16G"]
  extra_jupyter_args: ""
  bc_num_hours:
    value: 1
form:
  - gpu_mode
  - num_cores
  - memory_gb
  - extra_jupyter_args
  - bc_num_hours
EOF

cat << "EOF" > /var/www/ood/apps/sys/jupyter/submit.yml.erb
---
batch_connect:
  template: "basic"
script:
  native:
    - "--cpus-per-task=<%= num_cores.blank? ? 1 : num_cores.to_i %>"
    - "--mem=<%= memory_gb.blank? ? "2G" : memory_gb %>"
    <%- unless gpu_mode.blank? -%>
    - "--gres=<%= gpu_mode %>"
    <%- end -%>
EOF

cat << '\''EOF'\'' > /var/www/ood/apps/sys/jupyter/template/before.sh.erb
[[ $(type -t module) == "function" ]] && export -f module
port=$(find_port)
password="$(create_passwd 16)"
export CONFIG_FILE="${PWD}/config.py"
(
umask 077
cat > "${CONFIG_FILE}" << EOL
c.ServerApp.ip = "*"
c.ServerApp.port = ${port}
c.ServerApp.port_retries = 0
c.ServerApp.allow_remote_access = True
c.ServerApp.base_url = "/node/${host}/${port}/"
c.ServerApp.open_browser = False
c.ServerApp.allow_origin = "*"
c.ServerApp.root_dir = "${HOME}"
c.ServerApp.disable_check_xsrf = True
EOL
)
EOF

cat << '\''EOF'\'' > /var/www/ood/apps/sys/jupyter/template/script.sh.erb
#!/usr/bin/env bash
cd "${HOME}"
TOKEN=$(awk '\''/^password:/ {print $2}'\'' "${PWD}/connection.yml" | tr -d '\''"'\'')
jupyter lab --config="${CONFIG_FILE}" --IdentityProvider.token="${TOKEN}" <%= context.extra_jupyter_args %>
EOF

cat << '\''EOF'\'' > /var/www/ood/apps/sys/jupyter/view.html.erb
<form action="/node/<%= host %>/<%= port %>/" method="get" target="_blank">
  <input type="hidden" name="token" value="<%= password %>">
  <button class="btn btn-primary" type="submit">
    <i class="fa fa-eye"></i> Connect to Jupyter
  </button>
</form>
EOF

chmod -R a+rX /var/www/ood/apps/sys/jupyter
chmod +x /var/www/ood/apps/sys/jupyter/template/script.sh.erb
'
```

## 6. Interaktive App 2: WSL Linux Desktop (XFCE + TigerVNC + noVNC)

Installation von XFCE4, TigerVNC und websockify inklusive Kompatibilitäts-Wrappern für Ubuntu 24.04.

```bash
sudo apptainer exec --pwd /root instance://ood-cluster bash -c '
export DEBIAN_FRONTEND=noninteractive
apt-get install -y xfce4 xfce4-terminal dbus-x11 tigervnc-standalone-server \
  websockify python3-numpy python3-setuptools python3-websockify x11-xserver-utils

mkdir -p /opt/websockify /opt/TurboVNC/bin /etc/ood/config/apps/bc_desktop
ln -sf /usr/bin/websockify /opt/websockify/run

# Xvnc-Wrapper (filtert -Log und setzt Prozessnamen "Xvnc" für pgrep)
[ ! -f /usr/bin/Xtigervnc.real ] && mv /usr/bin/Xtigervnc /usr/bin/Xtigervnc.real
cat << '\''EOF'\'' > /usr/bin/Xtigervnc
#!/usr/bin/env python3
import os, sys
args, skip = [], False
for a in sys.argv[1:]:
    if skip: skip = False; continue
    if a in ("-Log", "-log"): skip = True; continue
    if a.startswith("-Log") or a.startswith("-log"): continue
    args.append(a)
os.execv("/usr/bin/Xtigervnc.real", ["Xvnc"] + args)
EOF
chmod +x /usr/bin/Xtigervnc
ln -sf /usr/bin/Xtigervnc /usr/local/bin/Xvnc

# vncserver-Wrapper (schreibt vnc.log ins Job-Verzeichnis und meldet Display-Format)
cat << '\''EOF'\'' > /usr/local/bin/vncserver
#!/usr/bin/env bash
DISP_NUM=1
while [ -e "/tmp/.X${DISP_NUM}-lock" ] || [ -e "/tmp/.X11-unix/X${DISP_NUM}" ]; do
  DISP_NUM=$((DISP_NUM + 1))
done
ARGS=(); SKIP_NEXT=0
for arg in "$@"; do
  [ "$SKIP_NEXT" -eq 1 ] && { SKIP_NEXT=0; continue; }
  [[ "$arg" == "-Log" || "$arg" == "-log" || "$arg" == "-noxstartup" || "$arg" == "-nohttpd" ]] && { [[ "$arg" == "-Log" || "$arg" == "-log" ]] && SKIP_NEXT=1; continue; }
  ARGS+=("$arg")
done
touch "${PWD}/vnc.log"
/usr/local/bin/Xvnc ":${DISP_NUM}" "${ARGS[@]}" >> "${PWD}/vnc.log" 2>&1 &
sleep 1
HOST=$(hostname)
echo "Desktop '\''${HOST}:${DISP_NUM} (${USER})'\'' started on display ${HOST}:${DISP_NUM}"
EOF
chmod +x /usr/local/bin/vncserver
cp /usr/local/bin/vncserver /opt/TurboVNC/bin/vncserver

# Isolierte D-Bus-Session für XFCE
cat << '\''EOF'\'' > /var/www/ood/apps/sys/bc_desktop/template/desktops/xfce.sh
#!/usr/bin/env bash
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
mkdir -p "${HOME}/.config/autostart"
for app in light-locker xfce4-power-manager xiccd; do
  printf "[Desktop Entry]\nHidden=true\n" > "${HOME}/.config/autostart/${app}.desktop"
done
exec dbus-launch --exit-with-session xfce4-session
EOF
chmod +x /var/www/ood/apps/sys/bc_desktop/template/desktops/xfce.sh

# Desktop-Formular & Slurm-Parameter
cat << "EOF" > /etc/ood/config/apps/bc_desktop/wsl.yml
---
title: "WSL Linux Desktop"
cluster: "wsl"
attributes:
  desktop: "xfce"
  gpu_mode:
    widget: "select"
    label: "Hardware-Beschleunigung"
    options:
      - ["CPU only (Standard)", ""]
      - ["NVIDIA GeForce RTX 2060 (1 GPU)", "gpu:1"]
  num_cores:
    widget: "number_field"
    label: "Anzahl CPU-Kerne"
    value: 2
    min: 1
    max: 8
    step: 1
  memory_gb:
    widget: "select"
    label: "Arbeitsspeicher (RAM)"
    options:
      - ["2 GB", "2G"]
      - ["4 GB", "4G"]
      - ["8 GB", "8G"]
      - ["16 GB", "16G"]
  bc_num_hours:
    value: 1
form:
  - desktop
  - gpu_mode
  - num_cores
  - memory_gb
  - bc_num_hours
EOF

cat << '\''EOF'\'' > /var/www/ood/apps/sys/bc_desktop/submit.yml.erb
---
batch_connect:
  template: "vnc"
script:
  native:
    - "--cpus-per-task=<%= num_cores.blank? ? 1 : num_cores.to_i %>"
    - "--mem=<%= memory_gb.blank? ? "2G" : memory_gb %>"
    <%- unless gpu_mode.blank? -%>
    - "--gres=<%= gpu_mode %>"
    <%- end -%>
EOF
'
```

## 7. Python-Kernels: PyTorch CUDA, TensorFlow CUDA, ome-zarr & SciPy-Stack

Aufbau zweier getrennter Python-3.11-Environments via uv (unter Nutzung des Host-Speichers zur Vermeidung von tmpfs-Engpässen).

```bash
sudo apptainer exec --pwd /root instance://ood-cluster bash -c '
pip3 install --break-system-packages uv
mkdir -p /home/hpcuser/projects/.uv-tmp
export TMPDIR=/home/hpcuser/projects/.uv-tmp
export UV_CACHE_DIR=/home/hpcuser/projects/.uv-tmp

# 1. PyTorch CUDA + Scientific Stack
uv venv /opt/pytorch-venv --python 3.11
uv pip install --no-cache --python /opt/pytorch-venv/bin/python torch --torch-backend=auto
uv pip install --no-cache --python /opt/pytorch-venv/bin/python \
  ome-zarr zarr "dask[array]" scikit-image tifffile numpy scipy pandas scikit-learn matplotlib ipykernel
/opt/pytorch-venv/bin/python -m ipykernel install --prefix=/usr/local --name="pytorch-cuda" --display-name="Python 3.11 (PyTorch CUDA)"

# 2. TensorFlow CUDA + Scientific Stack
uv venv /opt/tf-venv --python 3.11
uv pip install --no-cache --python /opt/tf-venv/bin/python \
  "tensorflow[and-cuda]" ome-zarr zarr "dask[array]" scikit-image tifffile numpy scipy pandas scikit-learn matplotlib ipykernel
/opt/tf-venv/bin/python -m ipykernel install --prefix=/usr/local --name="tensorflow-cuda" --display-name="Python 3.11 (TensorFlow CUDA)"

rm -rf /home/hpcuser/projects/.uv-tmp
'
```

## 8. Gruppen-Budget & Speicher-Quota-Widget auf dem Dashboard

Automatisches Monitoring-Skript (/usr/local/sbin/update-ood-billing.py), Systemd-Timer (alle 5 Minuten) und Dashboard-Kachel.

```bash
sudo apptainer exec --pwd /root instance://ood-cluster bash -c '
mkdir -p /var/lib/ood/quotas /var/lib/ood/balances /etc/ood/config/apps/dashboard/views/widgets /etc/ood/config/ondemand.d

cat << '\''EOF'\'' > /usr/local/sbin/update-ood-billing.py
#!/usr/bin/env python3
import json, os, subprocess
from datetime import datetime, timezone

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def dir_size(p):
    return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs if os.path.exists(os.path.join(r, f)) and not os.path.islink(os.path.join(r, f))) if os.path.exists(p) else 0

quota_data = {
    "version": 1, "timestamp": now,
    "quotas": [
        {"type": "fileset", "user": "hpcuser", "path": "/home/hpcuser", "total_block_usage": max(dir_size("/home/hpcuser"), 52428800)//1024, "block_limit": (20*1024**3)//1024, "total_file_usage": 1250, "file_limit": 100000},
        {"type": "fileset", "group": "hpcuser", "path": "/home/hpcuser/projects", "total_block_usage": max(dir_size("/home/hpcuser/projects"), 125829120)//1024, "block_limit": (100*1024**3)//1024, "total_file_usage": 4800, "file_limit": 500000}
    ]
}

used_chf = 14.50
try:
    for line in subprocess.check_output(["squeue", "-u", "hpcuser", "-h", "-o", "%C|%b"], text=True).strip().splitlines():
        if line:
            c, g = line.split("|")
            used_chf += (int(c) if c.isdigit() else 1) * 0.05 + (1 if "gpu" in g else 0) * 0.85
except Exception:
    pass

balance_data = {
    "version": 1, "timestamp": now, "config": {"unit": "CHF", "project_type": "Gruppe"},
    "balances": [{"user": "hpcuser", "project": "hpcuser (RTX2060-Lab)", "value": round(max(500.0 - used_chf, 0.0), 2), "limit": 500.0}]
}

json.dump(quota_data, open("/var/lib/ood/quotas/quota.json", "w"), indent=2)
json.dump(balance_data, open("/var/lib/ood/balances/balance.json", "w"), indent=2)
EOF
chmod +x /usr/local/sbin/update-ood-billing.py
/usr/local/sbin/update-ood-billing.py

cat << '\''EOF'\'' > /etc/systemd/system/ood-billing.service
[Unit]
Description=Update OOD Group Quotas and Balances
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-ood-billing.py
EOF

cat << '\''EOF'\'' > /etc/systemd/system/ood-billing.timer
[Unit]
Description=Run OOD Billing Update every 5 minutes
[Timer]
OnBootSec=15s
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF

cat << '\''EOF'\'' > /etc/ood/config/apps/dashboard/views/widgets/_group_billing.html.erb
<%
  require "json"
  quotas = File.exist?("/var/lib/ood/quotas/quota.json") ? JSON.parse(File.read("/var/lib/ood/quotas/quota.json"))["quotas"] || [] : []
  balances = File.exist?("/var/lib/ood/balances/balance.json") ? JSON.parse(File.read("/var/lib/ood/balances/balance.json"))["balances"] || [] : []
%>
<div class="card mb-3 shadow-sm">
  <div class="card-header bg-primary text-white"><strong>Gruppen-Budget &amp; Speicher-Quotas (Slurm TRES)</strong></div>
  <div class="card-body"><div class="row">
    <div class="col-md-6">
      <% balances.each do |b| %>
        <% pct = ((b["value"].to_f / [b["limit"].to_f, 1.0].max) * 100).round(1) %>
        <div class="d-flex justify-content-between"><span><strong><%= b["project"] %></strong></span><span><strong><%= format("%.2f", b["value"]) %> CHF</strong> / <%= format("%.2f", b["limit"]) %> CHF</span></div>
        <div class="progress mb-2" style="height:18px;"><div class="progress-bar bg-success" style="width:<%= pct %>%"><%= pct %>%</div></div>
      <% end %>
    </div>
    <div class="col-md-6">
      <% quotas.each do |q| %>
        <% u = (q["total_block_usage"].to_f * 1024 / (1024**3)).round(2); l = (q["block_limit"].to_f * 1024 / (1024**3)).round(1) %>
        <div class="d-flex justify-content-between small"><span><%= q["group"] ? "Gruppe: #{q["group"]}" : "User: #{q["user"]}" %> (<%= q["path"] %>)</span><span><strong><%= u %> GB</strong> / <%= l %> GB</span></div>
        <div class="progress mb-2" style="height:14px;"><div class="progress-bar bg-info" style="width:<%= [(u/[l,0.1].max*100).round(1),100].min %>%"></div></div>
      <% end %>
    </div>
  </div></div>
</div>
EOF

cat << '\''EOF'\'' > /etc/ood/config/ondemand.d/billing.yml
---
quota_path: "/var/lib/ood/quotas/quota.json"
balance_path: "/var/lib/ood/balances/balance.json"
dashboard_layout:
  rows:
    - columns:
        - width: 12
          widgets:
            - group_billing
            - pinned_apps
            - motd
EOF

systemctl daemon-reload
systemctl enable --now ood-billing.timer
/opt/ood/nginx_stage/sbin/nginx_stage nginx_clean --force
'
```

## 9. Bereinigung & Finales Backup-Image (.sif) erstellen

### 9.1. Alte Session-Daten & Caches im Container bereinigen

```bash
sudo apptainer exec --pwd /root instance://ood-cluster bash -c '
rm -rf /home/hpcuser/ondemand/data/sys/dashboard/batch_connect/*/*/output/*
rm -rf /home/hpcuser/.vnc/*.log /home/hpcuser/.vnc/*.pid /tmp/.X*-lock /tmp/.X11-unix/X*
apt-get clean && rm -rf /var/lib/apt/lists/* /root/.cache/* /home/hpcuser/.cache/*
'
```

### 9.2. Container stoppen, komprimiertes SIF-Backup bauen und wieder starten

```bash
~/ood-ctl.sh stop
sudo apptainer build ~/ood-sandbox-final-$(date +%Y%m%d).sif ~/ood-sandbox/
~/ood-ctl.sh start
```
