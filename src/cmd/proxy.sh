# =====================================================================
#  proxy  (run on the main server that has internet)
# =====================================================================
cmd_proxy() {
  EXTRA="$*"
  if [ -z "$EXTRA" ]; then
    read -r -p "Dev/IoT subnets (e.g. 192.168.20.0/24, separated by spaces): " EXTRA
  fi

  apt-get update -y || { echo "!! apt-get update failed"; return 1; }
  apt-get install -y tinyproxy curl || { echo "!! Could not install tinyproxy"; return 1; }

  # this machine's own subnet (e.g. 192.168.10.0/24) is allowed automatically
  DEV=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
  OWN=$(ip -o -4 route show dev "$DEV" scope link 2>/dev/null | awk '{print $1}' | head -n 1)
  SUBNETS="$OWN $EXTRA"
  if [ -z "$(echo $SUBNETS)" ]; then
    echo "!! No subnet to allow (could not find this machine's subnet and none was given) -> the proxy would reject every machine"
    return 1
  fi
  for s in $SUBNETS; do
    echo "$s" | grep -Eq '^[0-9a-fA-F:.]+(/[0-9]+)?$' || { echo "Invalid subnet format: $s"; return 1; }
  done
  echo "Allowed subnets: $SUBNETS"

  CONF=/etc/tinyproxy/tinyproxy.conf
  cp -n "$CONF" "$CONF.bak"
  if grep -Eq '^#?\s*Port ' "$CONF"; then
    sed -i -E "s/^#?\s*Port .*/Port $PORT/" "$CONF"
  else
    echo "Port $PORT" >> "$CONF"
  fi
  for s in $SUBNETS; do
    grep -qxF "Allow $s" "$CONF" || echo "Allow $s" >> "$CONF"
  done
  # restrict CONNECT destination ports so the server cannot be used to reach other ports
  for p in 80 443; do
    grep -qxF "ConnectPort $p" "$CONF" || echo "ConnectPort $p" >> "$CONF"
  done

  systemctl enable tinyproxy
  systemctl restart tinyproxy

  if ufw_active; then
    for s in $SUBNETS; do
      ufw allow from "$s" to any port "$PORT" proto tcp
    done
  fi

  IP=$(my_ip)
  echo
  echo "Testing this machine's proxy:"
  curl -sS -m 8 -x "http://127.0.0.1:$PORT" -o /dev/null -w "  https://deb.nodesource.com -> HTTP %{http_code}\n" https://deb.nodesource.com
  echo
  echo "================================================"
  echo "Proxy ready at http://$IP:$PORT"
  echo "On the dev machine, first test that the port is reachable:"
  echo "  curl -x http://$IP:$PORT -I https://deb.nodesource.com"
  echo "Then run: sudo bash iot.sh install --proxy $IP"
  echo "================================================"
}

# keep a copy of the git repo in the bundle (so GitLab on an offline network can set up a pull mirror from this machine)
mirror_repo() {
  command -v git >/dev/null 2>&1 || apt-get install -y git || return 1
  R=/srv/iot-bundle/repo.git
  if [ -d "$R" ]; then
    git -C "$R" remote update --prune || return 1
  else
    git clone --mirror "$REPO_URL" "$R" || return 1
  fi
  git -C "$R" update-server-info
}

