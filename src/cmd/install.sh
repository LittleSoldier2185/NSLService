# =====================================================================
#  install
# =====================================================================
cmd_install() {
  PROXY=""
  FROM=""
  SERVER_IP=""
  FAILED=()
  SUMS=""
  while [ "${1:-}" = "--proxy" ] || [ "${1:-}" = "-p" ] || [ "${1:-}" = "--from" ]; do
    OPT="$1"; VAL="${2:-}"
    [ $# -ge 2 ] && shift 2 || shift
    if [ "$OPT" = "--from" ]; then
      if [ -z "$VAL" ] && [ -s "$BUNDLE_URL_FILE" ]; then
        VAL="$(cat "$BUNDLE_URL_FILE")"; echo "Using the saved bundle URL: $VAL"
      fi
      [ -z "$VAL" ] && read -r -p "Bundle URL (e.g. http://192.168.10.2:8000): " VAL
      echo "$VAL" | grep -Eq "^https?://[A-Za-z0-9.:-]+/?$" || { echo "Invalid URL: $VAL"; return 1; }
      FROM="${VAL%/}"
    else
      SERVER_IP="$VAL"
      [ -z "$SERVER_IP" ] && read -r -p "Main server IP (running the proxy): " SERVER_IP
      if ! echo "$SERVER_IP" | grep -Eq '^[A-Za-z0-9.-]+$'; then
        echo "Invalid server IP/name: $SERVER_IP"
        return 1
      fi
      PROXY="http://$SERVER_IP:$PORT"
      NOPROXY="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
    fi
  done

  # ---------- choose what to install (checked before touching the system) ----------
  SEL="$*"
  check_env
  if [ -z "$SEL" ]; then
    echo "Choose what to install (type numbers separated by spaces, e.g. 1 3 5)"
    echo "  1) Docker"
    echo "  2) Node.js $NODE_MAJOR"
    echo "  3) EMQX (MQTT)"
    echo "  4) MySQL + phpMyAdmin"
    echo "  5) Node-RED"
    echo "  6) Apache"
    echo "  7) Git"
    echo "  8) All"
    read -r -p "Choose: " CHOICE
    for n in $CHOICE; do
      case "$n" in
        1) SEL="$SEL docker" ;;
        2) SEL="$SEL node" ;;
        3) SEL="$SEL emqx" ;;
        4) SEL="$SEL mysql" ;;
        5) SEL="$SEL nodered" ;;
        6) SEL="$SEL apache" ;;
        7) SEL="$SEL git" ;;
        8) SEL="all" ;;
      esac
    done
  fi
  case " $SEL " in *" all "*) SEL="docker node emqx mysql nodered apache git" ;; esac
  for w in $SEL; do
    case "$w" in
      docker|node|emqx|mysql|nodered|apache|git) ;;
      *) echo "Unknown: $w (valid: docker node emqx mysql nodered apache git all)"; return 1 ;;
    esac
  done
  if [ -z "$(echo $SEL)" ]; then
    echo "Nothing selected"
    return 1
  fi

  want() { echo " $SEL " | grep -q " $1 "; }
  if want emqx || want mysql || want nodered; then
    want docker || SEL="$SEL docker"
  fi

  # ---------- proxy (only with --proxy) ----------
  PX_ENV=()
  if [ -n "$PROXY" ]; then
    echo "Testing proxy $PROXY ..."
    CODE=$(curl -sS -m 10 -x "$PROXY" -o /dev/null -w "%{http_code}" https://deb.nodesource.com 2>/dev/null)
    case "$CODE" in
      000|""|403|407|502|503|504)
        echo "!! Proxy unusable (HTTP ${CODE:-000}). Check: ping $SERVER_IP, whether 'iot.sh proxy' has been run on the main server, whether this subnet is allowed"
        return 1
        ;;
    esac
    echo "Proxy OK (HTTP $CODE)"

    export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
    export no_proxy="$NOPROXY" NO_PROXY="$NOPROXY"
    PX_ENV=(-e HTTP_PROXY="$PROXY" -e HTTPS_PROXY="$PROXY" -e NO_PROXY="$NOPROXY")

    # apt
    cat > /etc/apt/apt.conf.d/95proxy <<EOF_APT
Acquire::http::Proxy "$PROXY";
Acquire::https::Proxy "$PROXY";
EOF_APT

    # Docker daemon (used by docker pull)
    mkdir -p /etc/systemd/system/docker.service.d
    DK_CONF=/etc/systemd/system/docker.service.d/http-proxy.conf
    cat > "$DK_CONF.new" <<EOF_DK
[Service]
Environment="HTTP_PROXY=$PROXY"
Environment="HTTPS_PROXY=$PROXY"
Environment="NO_PROXY=$NOPROXY"
EOF_DK
    if ! cmp -s "$DK_CONF.new" "$DK_CONF"; then
      mv "$DK_CONF.new" "$DK_CONF"
      systemctl daemon-reload
      # restart only when the proxy setting really changed (avoids needlessly stopping running containers)
      systemctl is-active --quiet docker && systemctl restart docker
    else
      rm -f "$DK_CONF.new"
    fi
  fi

  if [ -n "$FROM" ]; then
    # bundle mode: use the apt repo shared by the main server, no internet
    command -v curl >/dev/null 2>&1 || { echo "curl is required on this machine"; return 1; }
    SUMS=$(mktemp)   # removed by the EXIT trap in main
    curl -fsS -m 10 -o /dev/null "$FROM/debs/Release" || { echo "!! Cannot fetch $FROM/debs/Release. Check that 'iot.sh bundle' has been run and that machine is reachable"; return 1; }
    curl -fsS -m 20 -o "$SUMS" "$FROM/SHA256SUMS" || { echo "!! Cannot fetch $FROM/SHA256SUMS (re-run 'iot.sh bundle' or 'iot.sh update' on the main server)"; return 1; }
    # the apt index is checked here; apt then checks every .deb against the hashes inside Packages
    for f in Release Packages Packages.gz; do
      curl -fsS -m 60 -o "$SUMS.$f" "$FROM/debs/$f" || { echo "!! Cannot fetch $FROM/debs/$f"; rm -f "$SUMS".*; return 1; }
      verify_sum "$SUMS.$f" "debs/$f" "$SUMS"; rc=$?
      rm -f "$SUMS.$f"
      [ "$rc" -eq 0 ] || { echo "!! Checksum of debs/$f does not match SHA256SUMS (bundle changing or corrupted?)"; return 1; }
    done
    BL=/etc/apt/sources.list.d/iot-bundle.list
    echo "$FROM" > "$BUNDLE_URL_FILE"
    echo "deb [trusted=yes] $FROM/debs ./" > $BL
    apt-get update -y -o Dir::Etc::sourcelist=$BL -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 || { echo "!! apt-get update from the bundle failed"; return 1; }
  else
    apt-get update -y || { echo "!! apt-get update failed (no internet? try --proxy or --from)"; return 1; }
    apt-get install -y curl ca-certificates gnupg || { echo "!! Could not install curl/ca-certificates/gnupg"; return 1; }
  fi

  if want docker; then
    echo "===== Docker ====="
    if ! command -v docker >/dev/null 2>&1; then
      if [ -n "$FROM" ]; then
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || fail "Docker install failed"
      else
        curl -fsSL https://get.docker.com | sh || fail "Docker install failed"
      fi
    fi
    systemctl enable --now docker
    docker --version || fail "Docker is not working after install"
  fi

  if want node; then
    echo "===== Node.js $NODE_MAJOR ====="
    if [ -z "$FROM" ]; then
      curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - || fail "NodeSource repo setup failed"
    fi
    apt-get install -y nodejs || fail "Node.js install failed"
    node -v
    npm -v
    if [ -n "$PROXY" ]; then
      npm config set proxy "$PROXY"
      npm config set https-proxy "$PROXY"
    fi
  fi

  if want apache; then
    echo "===== Apache ====="
    apt-get install -y apache2 || fail "Apache install failed"
    systemctl enable --now apache2
    apache2 -v | head -n 1
  fi

  if want git; then
    echo "===== Git ====="
    apt-get install -y git || fail "Git install failed"
    git --version
  fi

  # bundle mode: load images from the main server into Docker (no pull)
  NR_IMAGE="$NODERED_IMAGE"
  if [ -n "$FROM" ]; then
    NR_IMAGE=nodered-iot:latest
    for pair in emqx:emqx mysql:mysql mysql:phpmyadmin nodered:nodered; do
      want "${pair%%:*}" || continue
      img="${pair##*:}"
      echo "Loading image $img ..."
      # download first and verify the checksum, so a damaged file is never loaded into Docker
      TAR=$(mktemp /var/tmp/iot-img.XXXXXX)
      if curl -fsS "$FROM/images/$img.tar" -o "$TAR" && verify_sum "$TAR" "images/$img.tar" "$SUMS"; then
        docker load -i "$TAR" || fail "Failed to load image $img"
      else
        fail "Image $img could not be downloaded or its checksum does not match SHA256SUMS"
      fi
      rm -f "$TAR"
    done
  fi

  if want emqx; then
    echo "===== EMQX ====="
    docker rm -f emqx 2>/dev/null
    # Note: emqx/emqx:5 does not exist on Docker Hub; use a full version such as 5.8.0
    docker run -d --name emqx --restart always \
      -p 1883:1883 -p 8083:8083 -p 8084:8084 -p 8883:8883 -p 18083:18083 \
      -v emqx_data:/opt/emqx/data \
      "$EMQX_IMAGE" \
      || fail "EMQX install failed, see the error above"
  fi

  if want mysql; then
    DB_NAME=mysql; DB_IMAGE="$MYSQL_IMAGE"; DB_ENV=MYSQL; DB_OTHER=mariadb   # DB_OTHER = the older one that may be installed (clashes on port 3306)
    echo "===== $DB_NAME + phpMyAdmin ====="
    docker network create iot-net 2>/dev/null

    # check what already exists (mysql and mariadb containers/volumes, phpmyadmin)
    EXISTING=""
    KEEP=""
    for n in mysql mariadb phpmyadmin; do
      docker container inspect "$n" >/dev/null 2>&1 && EXISTING="$EXISTING container:$n"
    done
    for n in mysql mariadb; do
      docker container inspect "$n" >/dev/null 2>&1 && KEEP="${KEEP:-$n}"
      docker volume inspect "${n}_data" >/dev/null 2>&1 && EXISTING="$EXISTING volume:${n}_data"
    done
    [ -n "$KEEP" ] && docker container inspect "$DB_NAME" >/dev/null 2>&1 && KEEP="$DB_NAME"

    ANS=1
    if [ -n "$EXISTING" ]; then
      echo "Found existing:$EXISTING"
      echo "  1) Skip   — keep the existing database, install phpMyAdmin only"
      echo "  2) Wipe   — delete the existing one (including database data, permanently) and reinstall"
      if [ "$ASSUME_YES" -eq 1 ]; then
        ANS=1   # --yes never wipes data
      else
        read -r -p "Choose (1/2) [1]: " ANS </dev/tty 2>/dev/null || ANS=1
      fi
      case "$ANS" in 2) ;; *) ANS=1 ;; esac
    fi

    if [ "$ANS" = "2" ]; then
      # dump the databases before deleting them (only possible while the old container is running)
      for old in mysql mariadb; do
        if running "$old"; then
          BK="/root/iot-${old}-backup-$(date +%Y%m%d-%H%M%S).sql"
          if docker exec -e MYSQL_PWD="$DB_PASS" "$old" mysqldump -uroot --all-databases > "$BK" 2>/dev/null; then
            echo "Backed up $old to $BK"
          else
            rm -f "$BK"
            read -r -p "Could not back up $old (wrong password?). Wipe anyway? Type yes: " OKW </dev/tty 2>/dev/null || OKW=no
            [ "$OKW" = "yes" ] || { echo "Cancelled, nothing was removed"; return 1; }
          fi
        fi
      done
      echo "Removing existing..."
      docker rm -f mysql mariadb phpmyadmin 2>/dev/null
      docker volume rm mysql_data mariadb_data 2>/dev/null
      KEEP=""
    fi

    if [ -n "$KEEP" ]; then
      # use the existing database (its name may differ from the selection because port 3306 clashes)
      [ "$KEEP" != "$DB_NAME" ] && echo "Using existing $KEEP (not the selected $DB_NAME)"
      DB_NAME="$KEEP"
      docker start "$DB_NAME" >/dev/null 2>&1
      docker network connect iot-net "$DB_NAME" 2>/dev/null
      docker rm -f phpmyadmin 2>/dev/null
    else
      # the unselected one clashes on port 3306, so remove its container (the volume stays)
      docker rm -f "$DB_OTHER" "$DB_NAME" phpmyadmin 2>/dev/null
      docker run -d --name "$DB_NAME" --restart always \
        --network iot-net \
        -p 3306:3306 \
        -e ${DB_ENV}_ROOT_PASSWORD="$DB_PASS" \
        -e ${DB_ENV}_DATABASE=iotdb \
        -v ${DB_NAME}_data:/var/lib/mysql \
        "$DB_IMAGE" \
        || fail "$DB_NAME install failed, see the error above"
    fi
    docker run -d --name phpmyadmin --restart always \
      --network iot-net \
      -p 8080:80 \
      -e PMA_HOST="$DB_NAME" \
      "$PMA_IMAGE" \
      || fail "phpMyAdmin install failed, see the error above"
  fi

  if want nodered; then
    echo "===== Node-RED ====="
    docker rm -f nodered 2>/dev/null
    docker run -d --name nodered --restart always \
      -p 1880:1880 \
      -v nodered_data:/data \
      "$NR_IMAGE" \
      || fail "Node-RED install failed, see the error above"
    # wait for Node-RED to create settings.js first (instead of a fixed sleep)
    for i in $(seq 1 30); do
      docker exec nodered test -f /data/settings.js 2>/dev/null && break
      sleep 2
    done
    # the bundle image already includes node-red-node-mysql
    if [ -z "$FROM" ]; then
      docker exec "${PX_ENV[@]}" nodered npm install --prefix /data node-red-node-mysql \
        || fail "Failed to install node-red-node-mysql (Node-RED has no MySQL node yet)"
    fi

    if [ -n "$NODERED_PASS" ]; then
      echo "Setting Node-RED password..."
      if ! docker exec -e NR_USER="$NODERED_USER" -e NR_PASS="$NODERED_PASS" nodered node -e '
        const fs = require("fs"), bcrypt = require("bcryptjs");
        const f = "/data/settings.js";
        let s = fs.readFileSync(f, "utf8");
        s = s.replace(/^.*\/\* setup-online \*\/.*\n/m, "");
        if (/^\s*adminAuth\s*:/m.test(s)) { console.log("Your own adminAuth already exists, skipping (the password shown at the end of the script may not match)"); process.exit(0); }
        const hash = bcrypt.hashSync(process.env.NR_PASS, 8);
        const line = "\n    /* setup-online */ adminAuth: { type: \"credentials\", users: [{ username: " + JSON.stringify(process.env.NR_USER) + ", password: " + JSON.stringify(hash) + ", permissions: \"*\" }] },";
        const out = s.replace(/module\.exports\s*=\s*\{/, (m) => m + line);
        if (out === s) { console.error("module.exports not found in settings.js"); process.exit(1); }
        fs.writeFileSync(f, out);
        console.log("Node-RED password set");
      '; then
        fail "Failed to set the Node-RED password — Node-RED is running without a password"
        NODERED_PASS=""
      fi
    fi
    docker restart nodered
  fi

  # open only the ports of what was selected
  want apache && ufw_allow 80
  want nodered && ufw_allow 1880
  want emqx && ufw_allow 1883 8083 8084 8883 18083
  want mysql && ufw_allow 3306 8080

  echo
  command -v docker >/dev/null 2>&1 && docker ps
  IP=$(my_ip)
  echo
  # show addresses only for what is actually running
  if want nodered; then
    if running nodered; then
      if [ -n "$NODERED_PASS" ]; then
        echo "Node-RED : http://$IP:1880  ($NODERED_USER / $NODERED_PASS)"
      else
        echo "Node-RED : http://$IP:1880  (no password)"
      fi
    else
      echo "Node-RED : not running"
    fi
  fi
  if want emqx; then
    running emqx && echo "EMQX     : http://$IP:18083  (admin / public)  MQTT: $IP:1883" || echo "EMQX     : not running"
  fi
  if want mysql; then
    if running "$DB_NAME"; then
      echo "$DB_NAME : $IP:3306  (root / $DB_PASS)"
      running phpmyadmin && echo "phpMyAdmin: http://$IP:8080  (root / $DB_PASS)"
    else
      echo "$DB_NAME : not running"
    fi
  fi
  if want apache; then
    systemctl is-active --quiet apache2 && echo "Apache   : http://$IP:80" || echo "Apache   : not running"
  fi
  if want git; then
    command -v git >/dev/null 2>&1 && git --version || echo "Git      : install failed"
  fi
  report_failures
}

