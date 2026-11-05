running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# failures are collected instead of being hidden by "|| echo"; commands print a summary and return non-zero
FAILED=()
fail() { echo "!!! $*" >&2; FAILED+=("$*"); }
report_failures() {
  [ "${#FAILED[@]}" -eq 0 ] && return 0
  echo
  echo "!!! ${#FAILED[@]} step(s) failed:"
  local f
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "Full log: $LOG_FILE"
  return 1
}

# the IP this machine uses to reach the outside (not just the first NIC listed by hostname -I)
my_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
  [ -n "$ip" ] || ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
}

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; }
ufw_allow() { ufw_active || return 0; local p; for p in "$@"; do ufw allow "${p}/tcp"; done; }

# warn (never block) when the machine differs from what the script was written for
check_env() {
  local arch id ver
  arch=$(dpkg --print-architecture 2>/dev/null)
  [ "$arch" = "amd64" ] || echo "!! Architecture is '${arch:-unknown}', this script was written for amd64"
  id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}"); ver=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")
  { [ "$id" = "ubuntu" ] && [ "$ver" = "22.04" ]; } || echo "!! OS is '${id:-unknown} ${ver}', this script was written for Ubuntu 22.04"
}

# bundle checksums: SHA256SUMS at the bundle root covers iot.sh, images, the apt index and frontend/ backend/ (all files, any depth)
bundle_sums() {
  local B=/srv/iot-bundle
  ( cd "$B" || exit 1
    mkdir -p frontend backend
    { find iot.sh images debs -maxdepth 1 \( -name iot.sh -o -name '*.tar' -o -name Release -o -name Packages -o -name Packages.gz \) -type f -print0
      find frontend backend -type f -print0
    } | sort -z | xargs -0 sha256sum > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS )
}

# verify_sum <file> <path as listed in SHA256SUMS> <sums file> : 0 ok, 1 mismatch, 2 not listed
verify_sum() {
  local want got
  want=$(awk -v p="$2" '{n=$2; sub(/^\*/,"",n)} n==p {print $1}' "$3")
  [ -n "$want" ] || return 2
  got=$(sha256sum "$1" | awk '{print $1}')
  [ "$want" = "$got" ]
}

# share $BUNDLE over HTTP on $BPORT as a systemd service (used by bundle and by Insider mode)
serve_bundle() {
  cat > /etc/systemd/system/iot-bundle.service <<EOF_SVC
[Unit]
Description=IoT bundle file server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server $BPORT --directory $BUNDLE
Restart=always

[Install]
WantedBy=multi-user.target
EOF_SVC
  systemctl daemon-reload
  systemctl enable iot-bundle
  systemctl restart iot-bundle
}
