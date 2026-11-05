if_backup() {
  [ -f "$IF_FILE" ] || { IF_BACKUP=""; return 0; }
  IF_BACKUP="${IF_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$IF_FILE" "$IF_BACKUP"
  echo "Backed up to: $IF_BACKUP"
}

if_reload() {
  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a
  else
    systemctl restart networking
  fi
}

if_rollback() {
  if [ -n "$IF_BACKUP" ] && [ -f "$IF_BACKUP" ]; then
    cp -a "$IF_BACKUP" "$IF_FILE"
    if_reload || true
    echo "Restored $IF_FILE from $IF_BACKUP"
  else
    echo "No backup file to restore"
  fi
}

# if_commit : reload the network, then check the gateway and roll back on failure
if_commit() {
  echo "Applying new settings (SSH will drop if the IP changes, but the script keeps running and writes its log to $SETUP_LOG)"
  if ! if_reload; then
    echo "reload failed, rolling back..."
    if_rollback
    return 1
  fi
  sleep 5
  if [ -z "$CHECK_GW" ]; then
    echo "No gateway to test (there was no default route before). Please check manually: ip -br a ; ip route"
    return 0
  fi
  if ping -c 3 -W 2 "$CHECK_GW" >/dev/null 2>&1; then
    echo "Gateway $CHECK_GW reachable, network OK"
    return 0
  fi
  echo "Gateway $CHECK_GW unreachable, rolling back..."
  if_rollback
  return 1
}

if_warn() {
  cat <<EOF_WN

Warning: this command changes the live network of this machine
 - Do it from a console (Proxmox: physical screen / IPMI), not over SSH
 - The old file is backed up first and restored automatically if the gateway does not answer
EOF_WN
}

if_show() {
  echo "==== $IF_FILE ===="
  if [ -s "$IF_FILE" ]; then
    cat "$IF_FILE"
  else
    echo "(file missing or empty)"
    command -v netplan >/dev/null 2>&1 && echo "This machine uses Netplan (Ubuntu); use menu option 2 instead, it does not use /etc/network/interfaces"
  fi
  echo "==== Backup files ===="
  ls -1t "${IF_FILE}".bak.* 2>/dev/null || echo "(none)"
}

if_restore() {
  local baks=() i=1 n
  mapfile -t baks < <(ls -1t "${IF_FILE}".bak.* 2>/dev/null)
  [ "${#baks[@]}" -gt 0 ] || { echo "No backup files found"; return 0; }
  for b in "${baks[@]}"; do echo "  $i) $b"; i=$((i+1)); done
  read -r -p "Restore which backup number? " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#baks[@]}" ] || die "Invalid number"
  CHECK_GW=$(ip -o -4 route show default | awk '{print $3}' | head -n1)
  if_warn
  echo "Will restore from: ${baks[$((n-1))]}"
  confirm
  start_logging
  if_backup                                   # also keep the current file
  local cur_backup=$IF_BACKUP
  cp -a "${baks[$((n-1))]}" "$IF_FILE"
  IF_BACKUP=$cur_backup
  if_commit || exit 1
  echo "Restore complete"
}

ask_nic() {
  echo "Physical network interfaces:"
  local n nics=""
  for n in /sys/class/net/*; do
    [ -e "$n/device" ] && nics="$nics $(basename "$n")"
  done
  echo " ${nics:- (none found)}"
  ip -br a
  echo
  local def=${nics# }; def=${def%% *}
  local in
  read -r -p "Physical network interface [${def}]: " in
  IFACE=${in:-$def}
  [ -n "$IFACE" ] || die "A network interface is required"
  ip link show "$IFACE" >/dev/null 2>&1 || die "Interface $IFACE not found"
}

print_if_diag() {
  cat <<EOF_DG

The network change did not work, so $IF_FILE was restored
Check the interface name (ip -br a), the gateway and the switch port / VLAN
Log: $SETUP_LOG
EOF_DG
}

if_static() {
  detect_defaults
  ask_iface
  ask_static nodns
  CHECK_GW=$GW
  echo
  echo "Will overwrite $IF_FILE with:"
  echo "  auto $IFACE / static $IP via $GW"
  if_warn
  confirm
  start_logging
  if_backup
  cat > "$IF_FILE" <<EOF_IF
auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet static
        address ${IP}
        gateway ${GW}
EOF_IF
  if_commit || { print_if_diag; exit 1; }
  echo "Done. Reconnect with: ssh ${SUDO_USER:-user}@${IP%/*}"
}

if_bridge() {
  detect_defaults
  ask_nic
  local br vids
  read -r -p "Bridge name [vmbr0]: " br; br=${br:-vmbr0}
  ask_static nodns
  read -r -p "Allowed VLAN IDs [2-4094]: " vids; vids=${vids:-2-4094}
  CHECK_GW=$GW
  echo
  echo "Will overwrite $IF_FILE with a VLAN-aware bridge:"
  echo "  interface $IFACE -> $br, address $IP, gateway $GW, VLAN $vids"
  echo "  (other bridges/interfaces in the old file are not kept, but remain in the backup)"
  if_warn
  confirm
  start_logging
  if_backup
  cat > "$IF_FILE" <<EOF_IF
auto lo
iface lo inet loopback

iface ${IFACE} inet manual

auto ${br}
iface ${br} inet static
        address ${IP}
        gateway ${GW}
        bridge-ports ${IFACE}
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids ${vids}
EOF_IF
  if_commit || { print_if_diag; exit 1; }
  echo "Done. In Proxmox set the VM's net0 -> VLAN Tag = your VLAN ID"
}

# bridge_set_vlan_aware <file> <bridge> <yes|no>  (edits the stanza in the existing file)
bridge_set_vlan_aware() {
  command -v python3 >/dev/null 2>&1 || die "This option requires python3"
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, br, val = sys.argv[1:4]
lines = open(path).read().split('\n')
start = next((i for i, l in enumerate(lines)
              if re.match(r'^iface\s+' + re.escape(br) + r'\s+inet', l)), None)
if start is None:
    sys.exit(3)
end = start + 1
while end < len(lines) and lines[end].startswith((' ', '\t')):
    end += 1
body = [l for l in lines[start + 1:end]
        if not re.match(r'\s*(bridge-vlan-aware|bridge-vids)\b', l)]
if val == 'yes':
    body += ['        bridge-vlan-aware yes', '        bridge-vids 2-4094']
lines[start + 1:end] = body
open(path, 'w').write('\n'.join(lines))
PY
}

if_vlan_toggle() {
  [ -s "$IF_FILE" ] || die "File $IF_FILE is missing or empty"
  echo "Bridges in $IF_FILE:"
  grep -E '^iface[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+inet' "$IF_FILE" | awk '{print "  " $2}'
  local br val
  read -r -p "Bridge name [vmbr0]: " br; br=${br:-vmbr0}
  read -r -p "VLAN-aware yes or no? [yes]: " val; val=${val:-yes}
  [ "$val" = "yes" ] || [ "$val" = "no" ] || die "Answer yes or no"
  CHECK_GW=$(ip -o -4 route show default | awk '{print $3}' | head -n1)
  echo
  echo "Will set bridge-vlan-aware=$val for $br in $IF_FILE"
  echo "Note: if VMs already use Proxmox VLAN tags, the bridge may need a reload; check the VMs after the change"
  if_warn
  confirm
  start_logging
  if_backup
  if ! bridge_set_vlan_aware "$IF_FILE" "$br" "$val"; then
    echo "Bridge $br not found in $IF_FILE, nothing changed"
    return 1
  fi
  echo "New stanza:"
  awk -v b="$br" '$0 ~ "^iface[ \t]+"b"[ \t]+inet"{p=1; print; next} p&&/^[ \t]/{print; next} {p=0}' "$IF_FILE"
  if_commit || { print_if_diag; exit 1; }
  echo "Done. Check with: bridge vlan show ; ip -br a"
}

# ---------- setup submenus ----------
