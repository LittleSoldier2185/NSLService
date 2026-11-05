render_netplan() {
  case "$NET_MODE" in
static)
cat <<EOF_NP
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses: [${IP}]
      routes:
        - to: default
          via: ${GW}
      nameservers:
        addresses: [${DNS}]
EOF_NP
;;
dhcp)
cat <<EOF_NP
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: true
EOF_NP
;;
vlan)
cat <<EOF_NP
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
  vlans:
    ${IFACE}.${VID}:
      id: ${VID}
      link: ${IFACE}
      addresses: [${IP}]
      routes:
        - to: default
          via: ${GW}
      nameservers:
        addresses: [${DNS}]
EOF_NP
;;
  esac
}

print_diagnostics() {
  if [ "$NET_MODE" = "dhcp" ]; then
    cat <<EOF_DG

Interface $IFACE got no IPv4 address from DHCP, so the previous settings were restored
Check: Proxmox net0 (bridge / VLAN tag / Disconnect), the switch port and the DHCP server
Log: $SETUP_LOG
EOF_DG
  else
    cat <<EOF_DG

Gateway $GW did not answer, so the previous network settings were restored
Check in this order:
  1. Gateway: is $GW really the gateway for this subnet/VLAN?
  2. Proxmox VM -> Hardware -> Network Device (net0): is the VLAN Tag correct?
     (e.g. 20 for VLAN 20). Without a tag, traffic leaves on the untagged VLAN
  3. The switch port connected to Proxmox must be a trunk that allows this VLAN
  4. Router / firewall: this VLAN must exist and be routed
Try from another machine:  ping $GW  to see whether the gateway is alive
Log: $SETUP_LOG
EOF_DG
  fi
}

apply_netplan() {
  echo "==> Applying network settings (mode: $NET_MODE)"
  mkdir -p /etc/netplan
  local backup=""
  if [ -f "$NETPLAN_FILE" ]; then
    backup="${NETPLAN_FILE}.bak.$(date +%s)"
    cp -a "$NETPLAN_FILE" "$backup"
    echo "Backed up to: $backup"
  fi

  # other netplan files may conflict with ours
  local other
  other=$(find /etc/netplan -maxdepth 1 -name '*.yaml' ! -name "$(basename "$NETPLAN_FILE")" 2>/dev/null)
  if [ -n "$other" ]; then
    echo "Warning: other Netplan files may conflict:"
    echo "$other"
  fi

  # stop cloud-init overwriting the network settings on reboot
  if [ -d /etc/cloud/cloud.cfg.d ]; then
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  fi

  render_netplan > "$NETPLAN_FILE"
  chmod 600 "$NETPLAN_FILE"

  rollback() {
    if [ -n "$backup" ]; then cp -a "$backup" "$NETPLAN_FILE"; else rm -f "$NETPLAN_FILE"; fi
    netplan apply || true
  }

  if ! netplan generate; then
    echo "Invalid Netplan file"
    rollback
    return 1
  fi

  echo "Applying new settings (SSH will drop if the IP changes, but the script keeps running and writes its log to $SETUP_LOG)"
  netplan apply

  if [ "$NET_MODE" = "dhcp" ]; then
    local i
    for i in $(seq 1 30); do
      if ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q inet; then
        echo "Got an IP from DHCP:"
        ip -4 -br a show dev "$IFACE"
        return 0
      fi
      sleep 1
    done
    echo "No IP from DHCP, rolling back..."
    rollback
    print_diagnostics
    return 1
  fi

  sleep 5
  if ping -c 3 -W 2 "$GW" >/dev/null 2>&1; then
    echo "Gateway $GW reachable, network OK"
    return 0
  fi

  echo "Gateway $GW unreachable, rolling back..."
  rollback
  print_diagnostics
  return 1
}

# ---------- /etc/network/interfaces (Proxmox host / Debian, ifupdown) ----------
