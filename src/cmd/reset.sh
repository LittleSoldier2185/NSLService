# =====================================================================
#  reset
# =====================================================================
cmd_reset() {
  LEVEL="${1:-}"
  if [ -z "$LEVEL" ]; then
    echo "Choose the reset level"
    echo "  1) containers + volumes + images (keep Docker and Node.js)  ** data in volumes is lost permanently **"
    echo "  2) Remove everything, including uninstalling Docker and Node.js"
    read -r -p "Choose (1/2): " LEVEL
  fi
  case "$LEVEL" in 1|2) ;; *) echo "Cancelled"; return 1 ;; esac

  if [ "$ASSUME_YES" -eq 1 ]; then
    OK=yes
  else
    read -r -p "Confirm reset level $LEVEL? Type yes to proceed: " OK
  fi
  [ "$OK" = "yes" ] || { echo "Cancelled"; return 1; }

  if command -v docker >/dev/null 2>&1; then
    # dump MySQL/MariaDB first: reset deletes the volumes permanently
    for old in mysql mariadb; do
      if running "$old"; then
        BK="/root/iot-${old}-backup-$(date +%Y%m%d-%H%M%S).sql"
        if docker exec -e MYSQL_PWD="$DB_PASS" "$old" mysqldump -uroot --all-databases > "$BK" 2>/dev/null; then
          echo ">> Backed up $old to $BK"
        else
          rm -f "$BK"
          echo "!! Could not back up $old (wrong password?)"
          if [ "$ASSUME_YES" -ne 1 ]; then
            read -r -p "Continue without a backup? Type yes: " OK2
            [ "$OK2" = "yes" ] || { echo "Cancelled, nothing was removed"; return 1; }
          fi
        fi
      fi
    done
    echo ">> Removing containers, volumes, images"
    # remove only what this installer created; other containers/images are untouched
    docker rm -f emqx mariadb phpmyadmin mysql nodered 2>/dev/null
    docker volume rm emqx_data emqx_log mariadb_data mysql_data nodered_data 2>/dev/null
    docker network rm iot-net 2>/dev/null
    docker rmi -f "$EMQX_IMAGE" "$MYSQL_IMAGE" "$PMA_IMAGE" "$NODERED_IMAGE" nodered-iot:latest mariadb 2>/dev/null
    docker rmi -f $(docker images -q 'emqx/emqx' 'nodered/node-red' 'nodered-iot' 'mysql' 'mariadb' 'phpmyadmin') 2>/dev/null
  fi

  # proxy settings written by install --proxy: remove them at every level, otherwise apt breaks after moving networks
  echo ">> Removing proxy settings"
  rm -f /etc/apt/apt.conf.d/95proxy
  if [ -f /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
    rm -f /etc/systemd/system/docker.service.d/http-proxy.conf
    systemctl daemon-reload
    systemctl is-active --quiet docker && systemctl restart docker
  fi
  if command -v npm >/dev/null 2>&1; then
    npm config delete proxy 2>/dev/null
    npm config delete https-proxy 2>/dev/null
  fi

  if [ "$LEVEL" = "2" ]; then
    echo ">> Uninstalling Docker"
    systemctl stop docker docker.socket 2>/dev/null
    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io 2>/dev/null
    if dpkg -l 2>/dev/null | grep -Eq '^ii +(docker-ce|docker\.io|containerd\.io) '; then
      echo "!! Docker uninstall failed; /var/lib/docker is kept to avoid data loss (see the error with: apt-get purge docker-ce)"
    else
      rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    fi
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
    rm -rf /etc/systemd/system/docker.service.d
    systemctl daemon-reload

    echo ">> Uninstalling Apache"
    apt-get purge -y apache2 apache2-utils 2>/dev/null

    echo ">> Uninstalling Node.js"
    apt-get purge -y nodejs 2>/dev/null
    rm -f /etc/apt/sources.list.d/nodesource.list
    rm -rf /usr/local/lib/nodejs /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx

    echo ">> Removing proxy settings and files created earlier"
    rm -f /etc/apt/apt.conf.d/95proxy /etc/apt/sources.list.d/iot-bundle.list "$BUNDLE_URL_FILE"
    npm config delete proxy 2>/dev/null
    npm config delete https-proxy 2>/dev/null
    rm -f /root/.npmrc
    rm -rf /opt/iot-stack /root/iot-stack /root/bundle /root/bundle.tar.gz

    apt-get autoremove -y
  fi

  echo
  echo "Reset complete (level $LEVEL)"
  command -v docker >/dev/null 2>&1 && docker ps -a || echo "Docker: no longer on this machine"
  command -v node >/dev/null 2>&1 && node -v || echo "Node.js: no longer on this machine"
}

