setup_status() {
  echo "== Network interfaces ==";        ip -br a
  echo; echo "== Route ==";            ip route
  echo; echo "== Neighbors (ARP) =="; ip neigh show
  echo; echo "== Netplan files ==";     ls -l /etc/netplan/ 2>/dev/null
  local gw
  gw=$(ip -o -4 route show default | awk '{print $3}' | head -n1)
  echo; echo "== Connectivity =="
  if [ -z "$gw" ]; then
    echo "No default route: this machine does not know where to send traffic outside its subnet"
  else
    if ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then echo "Gateway $gw: reachable"; else echo "Gateway $gw: unreachable"; fi
    if has_internet; then echo "Internet (1.1.1.1): reachable"; else echo "Internet (1.1.1.1): unreachable"; fi
    if getent hosts google.com >/dev/null 2>&1; then echo "DNS (google.com): working"; else echo "DNS (google.com): not working"; fi
  fi
  if command -v ufw >/dev/null 2>&1; then echo; echo "== Firewall =="; ufw status | head -n 20; fi
}

setup_normal() {
  detect_defaults
  ask_iface
  NET_MODE=static
  ask_static
  ask_timezone

  echo
  echo "Will configure (new machine setup):"
  echo "  Interface: $IFACE"
  echo "  IP       : $IP"
  echo "  Gateway  : $GW"
  echo "  DNS      : $DNS"
  echo "  Timezone : $TIMEZONE"
  confirm
  start_logging

  echo "==> Timezone"
  timedatectl set-timezone "$TIMEZONE"

  local pkgs_done=0
  if has_internet; then
    install_packages && pkgs_done=1
    setup_firewall
  else
    echo "No internet right now; packages will be installed after the network is configured"
  fi

  apply_netplan || exit 1

  if [ "$pkgs_done" -eq 0 ]; then
    if has_internet; then
      install_packages
      setup_firewall
    else
      echo "Warning: the gateway works but there is no internet (check router NAT / VLAN routing)"
      echo "Run again later:  sudo bash iot.sh setup normal"
    fi
  fi

  echo
  echo "Done. Reconnect with: ssh ${SUDO_USER:-user}@${IP%/*}"
  echo "Check: ip -br a ; ip route ; sudo ufw status"
}

setup_interface() {
  detect_defaults
  echo "Configure the network interface:"
  echo "  1) Static IP"
  echo "  2) DHCP (obtain an IP automatically)"
  echo "  3) Static IP on a VLAN tag inside this VM (advanced)"
  echo "  4) Back / exit"
  local sub
  read -r -p "Choose [1]: " sub
  sub=${sub:-1}
  case "$sub" in
    1) NET_MODE=static ;;
    2) NET_MODE=dhcp ;;
    3) NET_MODE=vlan ;;
    *) echo "Cancelled"; exit 0 ;;
  esac

  ask_iface
  [ "$NET_MODE" = "vlan" ] && ask_vlan_id
  [ "$NET_MODE" != "dhcp" ] && ask_static

  echo
  echo "Will configure (network interface only):"
  echo "  Mode     : $NET_MODE"
  echo "  Interface: $IFACE${VID:+.$VID (VLAN $VID)}"
  if [ "$NET_MODE" != "dhcp" ]; then
    echo "  IP       : $IP"
    echo "  Gateway  : $GW"
    echo "  DNS      : $DNS"
  fi
  confirm
  start_logging

  apply_netplan || exit 1

  echo
  if [ "$NET_MODE" = "dhcp" ]; then
    echo "Done. See the new IP with: ip -br a"
  else
    echo "Done. Reconnect with: ssh ${SUDO_USER:-user}@${IP%/*}"
  fi
  echo "Check: ip -br a ; ip route"
}

setup_ifupdown() {
  echo "/etc/network/interfaces (Proxmox / Debian style):"
  echo "  1) Show the current file and backups"
  echo "  2) Back up now"
  echo "  3) Restore a backup"
  echo "  4) Static IP on a plain interface    (overwrites the file)"
  echo "  5) VLAN-aware bridge, e.g. vmbr0   (overwrites the file)"
  echo "  6) Toggle VLAN-aware on an existing bridge (edits the file in place)"
  echo "  7) Back / exit"
  local sub
  read -r -p "Choose [1]: " sub
  sub=${sub:-1}
  case "$sub" in
    1) if_show ;;
    2) if_backup ;;
    3) if_restore ;;
    4) if_static ;;
    5) if_bridge ;;
    6) if_vlan_toggle ;;
    *) echo "Cancelled"; exit 0 ;;
  esac
}

cmd_setup() {
  local pick=""
  for arg in "$@"; do
    case "$arg" in
      normal|--normal)                              pick=1 ;;
      interface|netplan|--interface|--network-only) pick=2 ;;
      ifupdown|--ifupdown)                          pick=3 ;;
      status|--status)                              pick=4 ;;
      --yes|-y)                                     ASSUME_YES=1 ;;
      --upgrade)                                    UPGRADE=1 ;;
      *) echo "Unknown option: $arg (valid: normal interface ifupdown status --yes --upgrade)"; exit 1 ;;
    esac
  done

  if [ -z "$pick" ]; then
    echo "Machine setup"
    echo "  1) New machine setup        (timezone + static IP + packages + firewall; Ubuntu)"
    echo "  2) Network interface via Netplan (static IP / DHCP / VLAN tag in a VM; Ubuntu)"
    echo "  3) /etc/network/interfaces  (show / back up / restore / static IP / VLAN-aware bridge; Proxmox, Debian)"
    echo "  4) Show network status"
    echo "  5) Exit"
    read -r -p "Choose [1]: " pick
    pick=${pick:-1}
  fi

  case "$pick" in
    1) setup_normal ;;
    2) setup_interface ;;
    3) setup_ifupdown ;;
    4) setup_status ;;
    *) echo "Cancelled"; exit 0 ;;
  esac
}

