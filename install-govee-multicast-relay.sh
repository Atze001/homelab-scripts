#!/usr/bin/env bash
set -Eeuo pipefail

RELAY_REPO="https://github.com/marjohn56/udpbroadcastrelay.git"
RELAY_COMMIT="8ebaa9b2690eb61a236184f6f6bf7eb773da4fd9"
DEFAULT_HOSTNAME="multicast-relay"
DEFAULT_CORES="1"
DEFAULT_MEMORY="256"
DEFAULT_SWAP="256"
DEFAULT_DISK="2"
DEFAULT_PORT="4001"
DEFAULT_MULTICAST="239.255.255.250"
DEFAULT_STORAGE="local-lvm"
DEFAULT_TEMPLATE_STORAGE="local"

die() { echo "FEHLER: $*" >&2; exit 1; }
info() { echo "==> $*"; }
command -v pct >/dev/null || die "Dieses Script muss auf einem Proxmox-VE-Host ausgeführt werden."
[[ ${EUID} -eq 0 ]] || die "Bitte als root ausführen."

read_default() {
  local __var="$1" prompt="$2" def="$3" value
  read -r -p "$prompt [$def]: " value
  printf -v "$__var" '%s' "${value:-$def}"
}
read_optional() {
  local __var="$1" prompt="$2" value
  read -r -p "$prompt [leer = keines]: " value
  printf -v "$__var" '%s' "$value"
}
valid_cidr() {
  python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.ip_interface(sys.argv[1])
except ValueError: raise SystemExit(1)
PY
}
valid_ip() {
  python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.ip_address(sys.argv[1])
except ValueError: raise SystemExit(1)
PY
}
bridge_exists() { ip link show "$1" >/dev/null 2>&1; }
storage_exists() { pvesm status --storage "$1" >/dev/null 2>&1; }

echo
echo "================================================"
echo "       Govee Multicast Relay Installer"
echo "================================================"
echo

NEXT_ID="$(pvesh get /cluster/nextid 2>/dev/null || echo 101)"
read_default CTID "LXC-ID" "$NEXT_ID"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige LXC-ID."
pct status "$CTID" >/dev/null 2>&1 && die "LXC-ID $CTID ist bereits belegt."

read_default HOSTNAME "Hostname" "$DEFAULT_HOSTNAME"
read_default STORAGE "Rootfs-Storage" "$DEFAULT_STORAGE"
storage_exists "$STORAGE" || die "Storage '$STORAGE' existiert nicht."
read_default DISK "Disk-Größe in GB" "$DEFAULT_DISK"
read_default CORES "CPU-Cores" "$DEFAULT_CORES"
read_default MEMORY "RAM in MB" "$DEFAULT_MEMORY"
read_default SWAP "Swap in MB" "$DEFAULT_SWAP"

echo
echo "Vorhandene Linux-Bridges:"
ip -br link show type bridge 2>/dev/null | awk '{print "  - "$1}' || true
echo

read_default BRIDGE1 "Bridge für Netzwerk 1" "vmbr0"
bridge_exists "$BRIDGE1" || die "Bridge '$BRIDGE1' existiert nicht."
read_default IP1 "IPv4/CIDR für eth0" "10.1.110.102/24"
valid_cidr "$IP1" || die "Ungültige Adresse '$IP1'."
read_optional GW1 "Gateway für eth0"
[[ -z "$GW1" ]] || valid_ip "$GW1" || die "Ungültiges Gateway '$GW1'."

read_default BRIDGE2 "Bridge für Netzwerk 2" "vmbr120"
bridge_exists "$BRIDGE2" || die "Bridge '$BRIDGE2' existiert nicht."
read_default IP2 "IPv4/CIDR für eth1" "10.1.120.101/24"
valid_cidr "$IP2" || die "Ungültige Adresse '$IP2'."
read_optional GW2 "Gateway für eth1"
[[ -z "$GW2" ]] || valid_ip "$GW2" || die "Ungültiges Gateway '$GW2'."
[[ -z "$GW1" || -z "$GW2" ]] || die "Bitte nur auf einem Interface ein Default-Gateway konfigurieren."

read_default PORT "UDP-Port" "$DEFAULT_PORT"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "Ungültiger UDP-Port."
read_default MULTICAST "Multicast-Adresse" "$DEFAULT_MULTICAST"
valid_ip "$MULTICAST" || die "Ungültige Multicast-Adresse."

echo
echo "Template-Suche: Debian 13 amd64"
TEMPLATE="$(pveam list "$DEFAULT_TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-13-standard_.*_amd64\.tar\.zst/ {print $1}' | sort -V | tail -1)"
if [[ -z "$TEMPLATE" ]]; then
  info "Kein Debian-13-amd64-Template vorhanden. Aktualisiere Template-Liste..."
  pveam update
  AVAIL="$(pveam available --section system | awk '/debian-13-standard_.*_amd64\.tar\.zst/ {print $2}' | sort -V | tail -1)"
  [[ -n "$AVAIL" ]] || die "Kein Debian-13-amd64-Template gefunden."
  pveam download "$DEFAULT_TEMPLATE_STORAGE" "$AVAIL"
  TEMPLATE="$DEFAULT_TEMPLATE_STORAGE:vztmpl/$AVAIL"
fi

echo
echo "---------------- Zusammenfassung ----------------"
printf "LXC-ID:       %s\nHostname:     %s\nTemplate:     %s\nStorage:      %s (%sG)\nCPU/RAM/Swap: %s Core(s) / %s MB / %s MB\n" "$CTID" "$HOSTNAME" "$TEMPLATE" "$STORAGE" "$DISK" "$CORES" "$MEMORY" "$SWAP"
printf "eth0:         %s | %s | Gateway: %s\n" "$BRIDGE1" "$IP1" "${GW1:-keines}"
printf "eth1:         %s | %s | Gateway: %s\n" "$BRIDGE2" "$IP2" "${GW2:-keines}"
printf "Relay:        UDP %s | Multicast %s\n" "$PORT" "$MULTICAST"
echo "-------------------------------------------------"
read -r -p "Installation starten? [J/n]: " CONFIRM
[[ "${CONFIRM:-J}" =~ ^[JjYy]$ ]] || { echo "Abgebrochen."; exit 0; }

NET0="name=eth0,bridge=$BRIDGE1,ip=$IP1,type=veth"
NET1="name=eth1,bridge=$BRIDGE2,ip=$IP2,type=veth"
[[ -z "$GW1" ]] || NET0+=",gw=$GW1"
[[ -z "$GW2" ]] || NET1+=",gw=$GW2"

info "Erstelle LXC $CTID..."
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "$NET0" \
  --net1 "$NET1" \
  --onboot 1 \
  --startup order=2

pct start "$CTID"
info "Warte auf Container..."
for _ in {1..60}; do
  pct exec "$CTID" -- true >/dev/null 2>&1 && break
  sleep 1
done
pct exec "$CTID" -- true >/dev/null 2>&1 || die "Container wurde nicht rechtzeitig erreichbar."

info "Installiere Build-Abhängigkeiten..."
pct exec "$CTID" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends ca-certificates git build-essential && apt-get clean'

info "Baue udpbroadcastrelay aus festem Commit..."
pct exec "$CTID" -- bash -lc "rm -rf /opt/udpbroadcastrelay && git clone '$RELAY_REPO' /opt/udpbroadcastrelay && cd /opt/udpbroadcastrelay && git checkout '$RELAY_COMMIT' && make && install -m 0755 udpbroadcastrelay /usr/local/bin/udpbroadcastrelay"

info "Erstelle systemd-Service..."
UNIT="$(cat <<EOF
[Unit]
Description=Govee UDP Multicast Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 60); do ip -4 addr show dev eth0 | grep -Fq "$IP1" && ip -4 addr show dev eth1 | grep -Fq "$IP2" && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/local/bin/udpbroadcastrelay --id 1 --port $PORT --dev eth0 --dev eth1 --multicast $MULTICAST
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
)"
printf '%s\n' "$UNIT" | pct exec "$CTID" -- tee /etc/systemd/system/govee-multicast-relay.service >/dev/null
pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now govee-multicast-relay.service

# Avahi ist für UDP/4001 nicht erforderlich. Falls es durch ein Template/Dependency
# vorhanden sein sollte, verhindern wir Service- und Socket-Aktivierung.
pct exec "$CTID" -- bash -lc 'systemctl disable --now avahi-daemon.service avahi-daemon.socket 2>/dev/null || true'

info "Abschlussprüfung..."
pct exec "$CTID" -- systemctl is-active --quiet govee-multicast-relay.service || die "Relay-Service läuft nicht."

echo
echo "✓ LXC $CTID erstellt"
echo "✓ eth0: $BRIDGE1 / $IP1"
echo "✓ eth1: $BRIDGE2 / $IP2"
echo "✓ udpbroadcastrelay Commit $RELAY_COMMIT"
echo "✓ Govee Relay aktiv (UDP $PORT, $MULTICAST)"
echo "✓ Avahi nicht aktiv"
echo "✓ Autostart aktiviert"
echo
echo "Installation abgeschlossen."
echo "Status: pct exec $CTID -- systemctl status govee-multicast-relay.service --no-pager"
