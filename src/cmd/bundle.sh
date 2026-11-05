# =====================================================================
#  bundle  (run on the main server that has internet: download everything and share it over HTTP)
# =====================================================================
cmd_bundle() {
  SELF=$(readlink -f "${BASH_SOURCE[0]}")   # real path of the script (before cd elsewhere)
  BUNDLE=/srv/iot-bundle
  BPORT=8000
  REPO_OK=""
  FAILED=()
  check_env
  mkdir -p "$BUNDLE/images"

  # Docker + the Docker/NodeSource repos must exist on this machine first
  if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker on this machine first..."
    (cmd_install docker) || return 1
  fi
  apt-get update -y || { echo "!! apt-get update failed"; return 1; }
  apt-get install -y curl ca-certificates gnupg apt-utils python3 || { echo "!! Could not install the bundle prerequisites"; return 1; }
  # set the repo up fresh each time so an older Node repo version does not linger
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - || { echo "!! NodeSource repo setup failed"; return 1; }

  echo "===== Downloading apt packages (Docker, Node.js) ====="
  # download into debs.new and swap at the end, so machines installing right now never see an empty or partial repo
  rm -rf "$BUNDLE/debs.new"; mkdir -p "$BUNDLE/debs.new"
  ( cd "$BUNDLE/debs.new" || exit 1
    PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nodejs apache2 git"
    # include all dependencies (even ones already installed here) so the target machine can pick only what it lacks
    DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances $PKGS \
      | grep '^\w' | sort -u)
    apt-get download $DEPS || echo "!! Some packages failed to download (safe to ignore if they are virtual packages)"
    ls ./*.deb >/dev/null 2>&1 || exit 1
    apt-ftparchive packages . > Packages
    gzip -kf Packages
    apt-ftparchive release . > Release
  ) || { echo "!! Building the apt repo failed, the existing debs/ was left untouched"; rm -rf "$BUNDLE/debs.new"; return 1; }
  rm -rf "$BUNDLE/debs.old"
  [ -d "$BUNDLE/debs" ] && mv "$BUNDLE/debs" "$BUNDLE/debs.old"
  mv "$BUNDLE/debs.new" "$BUNDLE/debs"
  rm -rf "$BUNDLE/debs.old"

  echo "===== Downloading Docker images ====="
  cd "$BUNDLE/images" || return 1
  # Node-RED: bake node-red-node-mysql into the image so the target machine does not need npm
  BD=$(mktemp -d)
  printf 'FROM %s\nRUN npm install --no-fund --no-audit node-red-node-mysql\n' "$NODERED_IMAGE" > "$BD/Dockerfile"
  docker pull "$NODERED_IMAGE" && docker build -t nodered-iot:latest "$BD" || fail "Building the Node-RED image failed"
  rm -rf "$BD"
  for pair in "emqx|$EMQX_IMAGE" "mysql|$MYSQL_IMAGE" "phpmyadmin|$PMA_IMAGE" "nodered|nodered-iot:latest"; do
    name=${pair%%|*}; img=${pair#*|}
    if [ "$name" != nodered ] && ! docker pull "$img"; then fail "pull $img failed"; continue; fi
    docker save "$img" -o "$name.tar.new" && mv "$name.tar.new" "$name.tar" || fail "save $img failed"
  done

  bundle_projects

  cp -f "$SELF" "$BUNDLE/iot.sh" || { echo "!! Failed to copy iot.sh into the bundle"; return 1; }
  bundle_sums || fail "Could not write $BUNDLE/SHA256SUMS (machines using --from will refuse to install)"
  mirror_repo && REPO_OK=1 || echo "!! Failed to store the git repo (safe to ignore, does not affect installation)"

  echo "===== Sharing over HTTP on port $BPORT ====="
  serve_bundle
  ufw_allow "$BPORT"

  IP=$(my_ip)
  echo
  du -sh "$BUNDLE"/* 2>/dev/null
  echo
  echo "================================================"
  echo "Bundle ready at http://$IP:$BPORT"
  echo "On the other machine (no internet needed):"
  echo "  curl -fO http://$IP:$BPORT/iot.sh"
  echo "  sudo bash iot.sh install --from http://$IP:$BPORT"
  echo "Dev machine (frontend, no root needed):"
  echo "  bash iot.sh frontend --from http://$IP:$BPORT   /   bash iot.sh backend --from http://$IP:$BPORT"
  echo "npm registry mirror: http://$IP:$REGISTRY_PORT"
  [ -n "$REPO_OK" ] && echo "GitLab pull mirror URL: http://$IP:$BPORT/repo.git"
  echo "================================================"
  report_failures
}

