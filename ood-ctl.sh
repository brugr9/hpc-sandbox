#!/usr/bin/env bash
set -e

SANDBOX_DIR="$PWD/ood-sandbox"
INSTANCE_NAME="HPC Sandbox Cluster"

# Hier beliebige Host-Pfade -> Container-Pfade eintragen (kommagetrennt)
BIND_MOUNTS="$SANDBOX_DIR/hpc-projects:/home/hpcuser/projects,/usr/lib/wsl:/usr/lib/wsl,/dev/dxg:/dev/dxg"

case "$1" in
  start)
    echo "Starting Apptainer instance '$INSTANCE_NAME'..."
    sudo apptainer instance start --writable --boot --keep-privs --bind "$BIND_MOUNTS" "$SANDBOX_DIR" "$INSTANCE_NAME"
    sleep 3

    # SUID und Hostname sofort sicherstellen
    sudo apptainer exec --pwd /root "instance://$INSTANCE_NAME" mount -o remount,suid /
    sudo apptainer exec --pwd /root "instance://$INSTANCE_NAME" bash -c 'grep -q "ood-cluster" /etc/hosts || echo "127.0.0.1 ood-cluster" >> /etc/hosts'

    # Container-Bridge-IP ermitteln und Port 443 weiterleiten
    CONTAINER_IP=$(sudo apptainer exec --pwd /root "instance://$INSTANCE_NAME" grep -B1 "32 host LOCAL" /proc/net/fib_trie | awk '/10\.22\./ {print $2}' | head -n1)
    if [ -z "$CONTAINER_IP" ]; then
      echo "Error: Could not detect container 10.22.x.x IP."
      exit 1
    fi

    sudo pkill socat 2>/dev/null || true
    sudo nohup socat TCP-LISTEN:443,fork,reuseaddr TCP:${CONTAINER_IP}:443 >/dev/null 2>&1 &

    echo "Open OnDemand is live at https://localhost (Container IP: $CONTAINER_IP)"
    echo "Mounted Host Directory: $BIND_MOUNTS"
    ;;

  stop)
    echo "Stopping port forwarding and Apptainer instance '$INSTANCE_NAME'..."
    sudo pkill socat 2>/dev/null || true
    sudo apptainer instance stop "$INSTANCE_NAME"
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
