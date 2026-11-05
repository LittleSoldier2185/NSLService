# =====================================================================
#  setup  (new machine setup: time + IP + network + base packages + firewall)
#  every network change backs up the old file, checks the gateway and rolls back automatically if it fails
# =====================================================================
SETUP_LOG=/var/log/iot-setup.log
NETPLAN_FILE=/etc/netplan/50-cloud-init.yaml
IF_FILE=${IF_FILE:-/etc/network/interfaces}
PORTS=${PORTS:-"80 443 2222 5000 8080 9443"}   # ports opened in the firewall (configurable: PORTS="80 443" sudo -E bash iot.sh setup)
UPGRADE=0   # setup --upgrade: also run apt-get upgrade (may change the kernel and other packages)
LOGGING=0
IF_BACKUP=""
CHECK_GW=""

# values collected from the prompts
IFACE="" ; NET_MODE="static" ; IP="" ; GW="" ; DNS="8.8.8.8, 1.1.1.1"
VID="" ; TIMEZONE="Asia/Bangkok"

die() { echo "Error: $*" >&2; exit 1; }

has_internet() { ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; }

# same_subnet <ip/mask> <address> : 0 if address is in the ip/mask subnet, 2 if the format is invalid
same_subnet() {
  command -v python3 >/dev/null 2>&1 || return 0   # cannot check, treat as passed
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_interface(sys.argv[1]).network
    sys.exit(0 if ipaddress.ip_address(sys.argv[2]) in net else 1)
except ValueError:
    sys.exit(2)
PY
}

start_logging() {
  [ "$LOGGING" -eq 1 ] && return 0
  LOGGING=1
  # keep running even if SSH drops, and log everything
  trap '' HUP
  exec > >(tee --output-error=warn -a "$SETUP_LOG") 2>&1
  echo "---- setup started $(date) ----"
}

install_packages() {
  echo "==> Packages"
  apt-get update || { echo "apt update failed (no internet?)"; return 1; }
  if [ "$UPGRADE" -eq 1 ]; then
    apt-get upgrade -y
  else
    echo "Skipping apt-get upgrade (add --upgrade to upgrade all installed packages)"
  fi
  apt-get install -y openssh-server ufw qemu-guest-agent unattended-upgrades
  systemctl enable --now ssh || true
}

setup_firewall() {
  command -v ufw >/dev/null 2>&1 || { echo "ufw not installed, skipping the firewall"; return 0; }
  echo "==> Firewall (UFW)"
  ufw allow OpenSSH
  for p in $PORTS; do ufw allow "${p}/tcp"; done
  ufw --force enable
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local ok
  read -r -p "Continue? (y/n): " ok
  [ "$ok" = "y" ] || { echo "Cancelled"; exit 0; }
}

# ---------- prompts ----------
detect_defaults() {
  DEF_IFACE=$(ip -o -4 route show default | awk '{print $5}' | head -n1)
  if [ -z "$DEF_IFACE" ]; then
    DEF_IFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}' | cut -d@ -f1)
  fi
  DEF_GW=$(ip -o -4 route show default | awk '{print $3}' | head -n1)
}

ask_iface() {
  echo "Network interfaces on this machine:"
  ip -br a
  echo
  local in
  read -r -p "Network interface name [${DEF_IFACE}]: " in
  IFACE=${in:-$DEF_IFACE}
  [ -n "$IFACE" ] || die "A network interface name is required"
  ip link show "$IFACE" >/dev/null 2>&1 || die "Interface $IFACE not found (check with: ip -br a)"
}

ask_static() {   # ask_static [nodns]
  local in rc suggest
  read -r -p "Static IP with mask (e.g. 192.168.10.50/24): " IP
  [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
    || die "Invalid IP format, use e.g. 192.168.10.50/24"
  same_subnet "$IP" "${IP%/*}"; rc=$?
  [ "$rc" -eq 2 ] && die "Invalid IP: $IP"

  # suggest a gateway: the current one if it is in the same subnet, otherwise x.y.z.1
  suggest=$(echo "${IP%/*}" | awk -F. '{print $1"."$2"."$3".1"}')
  if [ -n "${DEF_GW:-}" ] && same_subnet "$IP" "$DEF_GW"; then
    suggest=$DEF_GW
  elif [ -n "${DEF_GW:-}" ]; then
    echo "Note: the current gateway ($DEF_GW) is not in the same subnet as $IP"
  fi
  read -r -p "Gateway [${suggest}]: " in
  GW=${in:-$suggest}
  same_subnet "$IP" "$GW" \
    || die "Gateway $GW is not in the subnet of $IP. Check the IP, mask and gateway (VLAN?)"

  [ "${1:-}" = "nodns" ] && return 0
  read -r -p "DNS, comma-separated [8.8.8.8, 1.1.1.1]: " in
  DNS=${in:-8.8.8.8, 1.1.1.1}
}

ask_vlan_id() {
  echo "Use only when Proxmox does not tag this interface (otherwise the tag would be doubled)"
  read -r -p "VLAN ID (1-4094): " VID
  [[ "$VID" =~ ^[0-9]+$ ]] && [ "$VID" -ge 1 ] && [ "$VID" -le 4094 ] || die "Invalid VLAN ID"
}

ask_timezone() {
  local in
  read -r -p "Timezone [Asia/Bangkok]: " in
  TIMEZONE=${in:-Asia/Bangkok}
}

# ---------- netplan (Ubuntu) ----------
