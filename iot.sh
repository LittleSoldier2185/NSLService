#!/bin/bash
# One tool to configure the machine/network and manage the IoT stack (Docker, Node.js LTS, EMQX, MySQL + phpMyAdmin, Node-RED) on Ubuntu 22.04
#
# Usage:
#   sudo bash iot.sh                                   -> show the main menu
#   sudo bash iot.sh setup [normal|interface|ifupdown|status] [--yes]
#                                                      -> set up a new machine: timezone, IP/network (Netplan or /etc/network/interfaces), base packages, firewall
#   sudo bash iot.sh install [name...]                -> install (no name = show a selection menu)
#   sudo bash iot.sh install --proxy 192.168.10.2 ...  -> install through the main server's proxy (machine has no internet)
#   sudo bash iot.sh proxy [subnet...]                  -> set up a proxy on the main server (has internet)
#   sudo bash iot.sh bundle                            -> download files and share them over HTTP (main server)
#   sudo bash iot.sh install --from http://IP:8000 ... -> install from the bundle (no internet needed at all)
#   sudo bash iot.sh update [URL]                      -> update iot.sh itself (no URL: previous bundle, or GitHub)
#   sudo bash iot.sh status                            -> show status (exit 1 if anything is wrong)
#   sudo bash iot.sh reset [1|2]                       -> remove what was installed (MySQL is dumped to /root first)
#   bash iot.sh frontend|backend --from http://IP:8000 [dir]  -> dev machine: download the project files from the bundle (package.json, lock, .npmrc, frontend static libs); no root needed
#   sudo bash iot.sh --version
# Options for every command: --yes / -y (answer confirmations; never wipes data). setup also accepts --upgrade.
# Log of install/proxy/bundle/update/reset: /var/log/iot.log
# Names accepted by install: docker node emqx mysql nodered apache git all

set -uo pipefail   # -e is deliberately not used: many cleanup commands are expected to fail, so failures are tracked with fail() and reported at the end

VERSION="1.1.0"
PORT=8888
NODE_MAJOR=24   # Node.js LTS to install (26 = Current, not LTS yet)
# Docker images (pinned so two runs on different days give the same result; override with e.g. MYSQL_IMAGE=mysql:8.4 sudo -E bash iot.sh install mysql)
EMQX_IMAGE="${EMQX_IMAGE:-emqx/emqx:5.8.0}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8}"
PMA_IMAGE="${PMA_IMAGE:-phpmyadmin:5}"
NODERED_IMAGE="${NODERED_IMAGE:-nodered/node-red:latest}"   # TODO: pin to a tested version (e.g. nodered/node-red:4.x.y)
# Frontend (Vue) static libraries shared by the bundle: by default the exact versions npm resolved into the frontend
# package-lock.json (so the <script> builds match what `npm ci` installs). Set FE_VUE=3.5.13 etc. to force a version.
FE_VUE="${FE_VUE:-}"; FE_ROUTER="${FE_ROUTER:-}"; FE_VUETIFY="${FE_VUETIFY:-}"
FE_AXIOS="${FE_AXIOS:-}"; FE_HTML2PDF="${FE_HTML2PDF:-}"; FE_MDI="${FE_MDI:-}"
VERDACCIO_IMAGE="${VERDACCIO_IMAGE:-verdaccio/verdaccio:5}"
REGISTRY_PORT=4873   # npm registry mirror (Verdaccio) on the main server
LOG_FILE=/var/log/iot.log   # log of install/proxy/bundle/update/reset (setup has its own log)
ASSUME_YES=0
REPO_URL="https://github.com/LittleSoldier2185/quick-setup.git"
BUNDLE_URL_FILE=/etc/iot-bundle.url   # remember the bundle URL used by install --from, for update
DB_PASS="${DB_PASS:-1234}"
NODERED_USER="admin"
NODERED_PASS="1234"   # Node-RED login password (empty "" = no password)
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -ne 0 ] && [ -n "${1:-}" ] && [ "${1:-}" != "frontend" ] && [ "${1:-}" != "backend" ]; then   # `frontend`/`backend` only download files, a dev machine does not need root
  echo "Please run as root: sudo bash $0 $*"
  exit 1
fi

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
# =====================================================================
#  frontend / backend packages shared by the bundle
#   - frontend/static/  ready-made libraries for a plain <script> tag (Vue, Router, Vuetify, axios, html2pdf, mdi icons)
#   - npm registry mirror (Verdaccio, port $REGISTRY_PORT) pre-filled with every dependency of both projects
#   - frontend/ and backend/ each hold package.json + package-lock.json so a dev machine gets the same versions
#  Use your own package.json instead of the built-in ones: FRONTEND_PKG=/path/package.json BACKEND_PKG=/path/package.json
# =====================================================================
pkg_frontend() {
  cat <<'EOF_PKG'
{
  "name": "evaluation-web",
  "private": true,
  "version": "2569.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "@mdi/font": "^7.4.47",
    "axios": "^1.7.9",
    "html2pdf.js": "^0.10.3",
    "vue": "^3.5.13",
    "vue-router": "^4.5.0",
    "vuetify": "^3.7.6"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^5.2.1",
    "vite": "^6.0.7"
  }
}
EOF_PKG
}

pkg_backend() {
  cat <<'EOF_PKG'
{
  "name": "evaluation-api",
  "private": true,
  "version": "2569.0.0",
  "engines": { "node": ">=24" },
  "scripts": {
    "seed": "node seed.js",
    "start": "node server.js",
    "dev": "nodemon -L server.js",
    "test": "node --test tests/score.test.js",
    "test:api": "node --test tests/api.test.js"
  },
  "dependencies": {
    "bcryptjs": "^3.0.2",
    "cors": "^2.8.5",
    "express": "^5.1.0",
    "jsonwebtoken": "^9.0.2",
    "multer": "^2.0.2",
    "mysql2": "^3.14.0"
  },
  "devDependencies": {
    "nodemon": "^3.1.10"
  }
}
EOF_PKG
}

# version of an npm package as resolved in a package-lock.json (empty if unknown)
lock_version() {   # lock_version <package-lock.json> <package>
  [ -f "$1" ] && command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8"))["packages"]["node_modules/" + sys.argv[2]]["version"])
except Exception:
    pass
PY
}

# FV_* = version to download: FE_* (forced by the user) > version in the lock file > pinned fallback
fe_resolve() {   # fe_resolve <frontend package-lock.json>
  local L="$1"
  FV_VUE="${FE_VUE:-$(lock_version "$L" vue)}";               FV_VUE="${FV_VUE:-3.5.13}"
  FV_ROUTER="${FE_ROUTER:-$(lock_version "$L" vue-router)}";  FV_ROUTER="${FV_ROUTER:-4.5.0}"
  FV_VUETIFY="${FE_VUETIFY:-$(lock_version "$L" vuetify)}";   FV_VUETIFY="${FV_VUETIFY:-3.7.6}"
  FV_AXIOS="${FE_AXIOS:-$(lock_version "$L" axios)}";         FV_AXIOS="${FV_AXIOS:-1.7.9}"
  FV_HTML2PDF="${FE_HTML2PDF:-$(lock_version "$L" html2pdf.js)}"; FV_HTML2PDF="${FV_HTML2PDF:-0.10.3}"
  FV_MDI="${FE_MDI:-$(lock_version "$L" @mdi/font)}";         FV_MDI="${FV_MDI:-7.4.47}"
  echo "  static libraries: vue $FV_VUE, vue-router $FV_ROUTER, vuetify $FV_VUETIFY, axios $FV_AXIOS, html2pdf.js $FV_HTML2PDF, @mdi/font $FV_MDI"
}

# static libraries for the frontend: <path under frontend/static>|<jsdelivr path>   (call fe_resolve first)
fe_static_files() {
  local M="@mdi/font@$FV_MDI"
  cat <<EOF_LIST
vue.global.prod.js|vue@$FV_VUE/dist/vue.global.prod.js
vue-router.global.prod.js|vue-router@$FV_ROUTER/dist/vue-router.global.prod.js
vuetify.min.js|vuetify@$FV_VUETIFY/dist/vuetify.min.js
vuetify.min.css|vuetify@$FV_VUETIFY/dist/vuetify.min.css
axios.min.js|axios@$FV_AXIOS/dist/axios.min.js
html2pdf.bundle.min.js|html2pdf.js@$FV_HTML2PDF/dist/html2pdf.bundle.min.js
mdi/css/materialdesignicons.min.css|$M/css/materialdesignicons.min.css
mdi/fonts/materialdesignicons-webfont.woff2|$M/fonts/materialdesignicons-webfont.woff2
mdi/fonts/materialdesignicons-webfont.woff|$M/fonts/materialdesignicons-webfont.woff
mdi/fonts/materialdesignicons-webfont.ttf|$M/fonts/materialdesignicons-webfont.ttf
mdi/fonts/materialdesignicons-webfont.eot|$M/fonts/materialdesignicons-webfont.eot
EOF_LIST
}

fe_example_html() {
  cat <<'EOF_HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"><title>Frontend example</title>
  <link rel="stylesheet" href="mdi/css/materialdesignicons.min.css">
  <link rel="stylesheet" href="vuetify.min.css">
</head>
<body>
  <div id="app">
    <v-app>
      <v-main class="pa-6">
        <h2>{{ message }}</h2>
        <v-btn color="primary" prepend-icon="mdi-plus" @click="count++">Clicked {{ count }} times</v-btn>
      </v-main>
    </v-app>
  </div>
  <script src="vue.global.prod.js"></script>
  <script src="vuetify.min.js"></script>
  <script>
    Vue.createApp({
      data() { return { message: 'Hello from the local frontend bundle', count: 0 } }
    }).use(Vuetify.createVuetify()).mount('#app')
  </script>
</body>
</html>
EOF_HTML
}

# package.json of both projects -> <new dir>/frontend and <new dir>/backend
bundle_projects_pkgs() {
  local N="$1"
  mkdir -p "$N/frontend" "$N/backend"
  if [ -n "${FRONTEND_PKG:-}" ] && [ -f "$FRONTEND_PKG" ]; then cp "$FRONTEND_PKG" "$N/frontend/package.json"; else pkg_frontend > "$N/frontend/package.json"; fi
  if [ -n "${BACKEND_PKG:-}" ]  && [ -f "$BACKEND_PKG" ];  then cp "$BACKEND_PKG"  "$N/backend/package.json";  else pkg_backend  > "$N/backend/package.json";  fi
}

# frontend/static (needs the frontend package-lock.json from warm_registry for the versions)
bundle_projects_static() {
  local N="$1" rel src ok=1
  fe_resolve "$N/frontend/package-lock.json"
  mkdir -p "$N/frontend/static"
  while IFS='|' read -r rel src; do
    mkdir -p "$N/frontend/static/$(dirname "$rel")"
    curl -fsSL -m 120 -o "$N/frontend/static/$rel" "https://cdn.jsdelivr.net/npm/$src" || { fail "Downloading frontend/static/$rel failed"; ok=""; }
  done < <(fe_static_files)
  if [ -n "$ok" ]; then
    fe_example_html > "$N/frontend/static/example.html"
  elif [ -d "$BUNDLE/frontend/static" ]; then
    echo "!! Keeping the previous frontend/static"
    rm -rf "$N/frontend/static"; cp -a "$BUNDLE/frontend/static" "$N/frontend/static"
  fi
}

# npm registry mirror (Verdaccio) as a container: read-only for everyone (sign-up disabled, nobody can publish)
start_registry() {
  local R=/srv/npm-registry i
  mkdir -p "$R/conf" "$R/storage"
  cat > "$R/conf/config.yaml" <<'EOF_CFG'
storage: /verdaccio/storage
web:
  title: IoT npm mirror
auth:
  htpasswd:
    file: /verdaccio/storage/htpasswd
    max_users: -1
uplinks:
  npmjs:
    url: https://registry.npmjs.org/
packages:
  '@*/*':
    access: $all
    publish: $authenticated
    proxy: npmjs
  '**':
    access: $all
    publish: $authenticated
    proxy: npmjs
log: { type: stdout, format: pretty, level: warn }
EOF_CFG
  chown -R 10001:65533 "$R/conf" "$R/storage"   # the uid/gid Verdaccio runs as inside the container
  docker pull "$VERDACCIO_IMAGE" || { fail "pull $VERDACCIO_IMAGE failed"; return 1; }
  docker rm -f npm-registry >/dev/null 2>&1
  docker run -d --name npm-registry --restart unless-stopped -p "$REGISTRY_PORT:4873" \
    -v "$R/conf:/verdaccio/conf" -v "$R/storage:/verdaccio/storage" "$VERDACCIO_IMAGE" >/dev/null \
    || { fail "Starting the npm registry container failed"; return 1; }
  for i in $(seq 1 30); do
    curl -fsS -m 2 "http://127.0.0.1:$REGISTRY_PORT/-/ping" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS -m 2 "http://127.0.0.1:$REGISTRY_PORT/-/ping" >/dev/null 2>&1 || { fail "npm registry did not start (docker logs npm-registry)"; return 1; }
  ufw_allow "$REGISTRY_PORT"
}

# install both projects once through the registry so every package (incl. other platforms' binaries) is cached,
# and keep the resulting package-lock.json for the dev machines
warm_registry() {
  local N="$1" p d plat os cpu
  for p in frontend backend; do
    d=$(mktemp -d) || continue
    cp "$N/$p/package.json" "$d/"
    echo "  caching $p dependencies..."
    if docker run --rm --network host -v "$d:/w" -w /w "node:${NODE_MAJOR}-alpine" \
         npm install --registry "http://127.0.0.1:$REGISTRY_PORT" --ignore-scripts --no-fund --no-audit >/dev/null; then
      [ -f "$d/package-lock.json" ] && cp "$d/package-lock.json" "$N/$p/package-lock.json"
      # dev machines are often Windows/macOS: cache their platform-specific binaries (esbuild, rollup...) too
      for plat in win32:x64 darwin:arm64 darwin:x64 linux:arm64; do
        os=${plat%%:*}; cpu=${plat##*:}
        rm -rf "$d/node_modules"
        docker run --rm --network host -v "$d:/w" -w /w "node:${NODE_MAJOR}-alpine" \
          npm install --os="$os" --cpu="$cpu" --registry "http://127.0.0.1:$REGISTRY_PORT" --ignore-scripts --no-fund --no-audit >/dev/null 2>&1 \
          || echo "  (could not cache $os/$cpu binaries for $p; a dev machine on that platform needs internet once)"
      done
    else
      fail "Caching the $p dependencies failed (npm install through the registry)"
    fi
    rm -rf "$d"
  done
}

bundle_projects() {
  echo "===== Frontend / backend packages ====="
  local N="$BUNDLE/projects.new" p
  rm -rf "$N"; mkdir -p "$N"
  bundle_projects_pkgs "$N"
  if start_registry; then warm_registry "$N"; else echo "!! No registry: static libraries use the pinned fallback versions"; fi
  bundle_projects_static "$N"
  # swap in at the end so a machine downloading right now never sees a half-written folder
  for p in frontend backend; do
    rm -rf "$BUNDLE/$p.old"
    [ -d "$BUNDLE/$p" ] && mv "$BUNDLE/$p" "$BUNDLE/$p.old"
    mv "$N/$p" "$BUNDLE/$p" && rm -rf "$BUNDLE/$p.old"
  done
  rm -rf "$N"
}

# ---------------------------------------------------------------------
#  dev machine: iot.sh frontend|backend --from URL [dir]   (no root needed)
#  downloads package.json, package-lock.json (and static/ for the frontend), verifies checksums,
#  and writes a project-local .npmrc that points npm at the main server's registry
# ---------------------------------------------------------------------
fetch_project() {
  local P="$1"; shift
  local FROM="" DEST="" VAL
  SUMS=""
  FAILED=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) VAL="${2:-}"; [ $# -ge 2 ] && shift 2 || shift
              [ -z "$VAL" ] && [ -s "$BUNDLE_URL_FILE" ] && VAL="$(cat "$BUNDLE_URL_FILE")"
              [ -z "$VAL" ] && read -r -p "Bundle URL (e.g. http://192.168.10.2:8000): " VAL
              echo "$VAL" | grep -Eq "^https?://[A-Za-z0-9.:-]+/?$" || { echo "Invalid URL: $VAL"; return 1; }
              FROM="${VAL%/}" ;;
      -*)     echo "Unknown option: $1 (usage: iot.sh $P --from URL [dir])"; return 1 ;;
      *)      DEST="$1"; shift ;;
    esac
  done
  [ -n "$FROM" ] || { echo "Usage: iot.sh $P --from http://IP:8000 [dir]"; return 1; }
  DEST="${DEST:-./$P}"

  SUMS=$(mktemp)   # removed by the EXIT trap in main
  curl -fsS -m 20 -o "$SUMS" "$FROM/SHA256SUMS" || { echo "!! Cannot fetch $FROM/SHA256SUMS"; return 1; }
  local files f rel tmp target rc host
  files=$(awk -v p="$P/" '{n=$2; sub(/^\*/,"",n)} index(n,p)==1 {print n}' "$SUMS")
  [ -n "$files" ] || { echo "!! This bundle has no $P files (run 'iot.sh bundle' again on the main server)"; return 1; }
  mkdir -p "$DEST" || return 1
  for f in $files; do
    rel=${f#"$P"/}
    case "/$rel/" in *//*|*/.*) fail "Skipping suspicious file name in SHA256SUMS: $f"; continue ;; esac
    target="$DEST/$rel"
    # never overwrite a dev's own package.json / lock file: the server's copy goes next to it as *.new
    case "$rel" in
      static/*) ;;
      *) [ -e "$target" ] && target="$target.new" ;;
    esac
    mkdir -p "$(dirname "$target")"
    tmp=$(mktemp)
    if curl -fsS -m 120 -o "$tmp" "$FROM/$f"; then
      verify_sum "$tmp" "$f" "$SUMS"; rc=$?
      if [ "$rc" -eq 0 ]; then mv "$tmp" "$target" && chmod 644 "$target" && echo "  $target"
      else rm -f "$tmp"; fail "Checksum of $f does not match SHA256SUMS"; fi
    else
      rm -f "$tmp"; fail "Cannot fetch $FROM/$f"
    fi
  done
  report_failures || return 1

  host=${FROM#*://}; host=${host%%[:/]*}
  if [ -e "$DEST/.npmrc" ]; then
    echo "Kept your existing $DEST/.npmrc (it should contain: registry=http://$host:$REGISTRY_PORT/)"
  else
    printf 'registry=http://%s:%s/\n' "$host" "$REGISTRY_PORT" > "$DEST/.npmrc" && echo "  $DEST/.npmrc  (npm uses http://$host:$REGISTRY_PORT/ for this folder only)"
  fi
  echo
  echo "Next:"
  echo "  cd $DEST && npm ci        # same versions as the server (npm install also works)"
  [ "$P" = frontend ] && echo "  npm run dev               # or open $DEST/static/example.html (no npm needed)"
  [ "$P" = backend ] && echo "  npm run start"
  echo "Guide: docs/frontend-backend.md"
}

cmd_frontend() { fetch_project frontend "$@"; }
cmd_backend()  { fetch_project backend "$@"; }
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

# =====================================================================
#  update  (update iot.sh itself: offline machines pull from the bundle, online machines from GitHub)
# =====================================================================
cmd_update() {
  SELF=$(readlink -f "${BASH_SOURCE[0]}")
  URL="${1:-}"
  if [ -z "$URL" ]; then
    if [ -s "$BUNDLE_URL_FILE" ]; then
      URL="$(cat "$BUNDLE_URL_FILE")"            # install --from was used before -> reuse that bundle
    else
      URL="https://raw.githubusercontent.com/LittleSoldier2185/quick-setup/main/iot.sh"
    fi
  fi
  case "$URL" in *.sh) ;; *) URL="${URL%/}/iot.sh" ;; esac
  echo "Fetching $URL ..."

  TMP=$(mktemp)
  if ! curl -fsSL -m 30 "$URL" -o "$TMP"; then
    echo "!! Download failed (check that the main server has run 'iot.sh bundle' and is reachable)"
    rm -f "$TMP"; return 1
  fi
  sed -i 's/\r$//' "$TMP"
  if ! head -n 1 "$TMP" | grep -q '^#!/bin/bash' || ! bash -n "$TMP" 2>/dev/null; then
    echo "!! The downloaded file is not a valid script, nothing changed"
    rm -f "$TMP"; return 1
  fi
  # a bundle publishes SHA256SUMS next to iot.sh: when it exists, the file must match it
  SUMS_U=$(mktemp)
  if curl -fsS -m 10 -o "$SUMS_U" "${URL%/*}/SHA256SUMS" 2>/dev/null; then
    verify_sum "$TMP" "iot.sh" "$SUMS_U"; rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "!! iot.sh does not match the bundle's SHA256SUMS, nothing changed"
      rm -f "$TMP" "$SUMS_U"; return 1
    fi
  fi
  rm -f "$SUMS_U"
  if cmp -s "$TMP" "$SELF"; then
    echo "Already up to date"
    rm -f "$TMP"; return 0
  fi
  cp -f "$SELF" "$SELF.bak"
  chmod 755 "$TMP"
  mv -f "$TMP" "$SELF"                           # replace the whole file instead of editing the running one
  # main server: also update the copy shared in the bundle
  if [ -f /srv/iot-bundle/iot.sh ]; then
    cp -f "$SELF" /srv/iot-bundle/iot.sh && echo "Updated /srv/iot-bundle/iot.sh"
    bundle_sums && echo "Updated /srv/iot-bundle/SHA256SUMS"   # iot.sh changed, so the checksums must be rewritten
  fi
  [ -d /srv/iot-bundle/repo.git ] && mirror_repo && echo "Updated /srv/iot-bundle/repo.git"
  echo "Update complete (previous version kept at $SELF.bak)"
  return 0
}

# =====================================================================
#  status
# =====================================================================
cmd_status() {
  FAILS=0
  if [ -t 1 ]; then
    G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
  else
    G=""; R=""; Y=""; D=""; N=""
  fi
  ok()   { echo "  ${G}OK${N}    $*"; }
  bad()  { echo "  ${R}FAIL${N}  $*"; FAILS=$((FAILS + 1)); }
  warn() { echo "  ${Y}WARN${N}  $*"; }
  skip() { echo "  ${D}--    $*${N}"; }

  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found on this machine"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Cannot reach Docker (is the docker daemon running?)"
    return 1
  fi

  exists()  { docker container inspect "$1" >/dev/null 2>&1; }
  listen()  { ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"; }
  http()    { curl -s -o /dev/null -m 5 -w "%{http_code}" "$1" 2>/dev/null; }

  echo "===== $(hostname)  $(date '+%Y-%m-%d %H:%M:%S')  iot.sh v$VERSION ====="

  echo
  echo "[Containers]"
  for n in emqx mysql phpmyadmin nodered; do
    if ! exists "$n"; then skip "$n  (not installed)"; continue; fi
    state=$(docker inspect -f '{{.State.Status}}' "$n")
    restarts=$(docker inspect -f '{{.RestartCount}}' "$n")
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$n")
    up=$(docker inspect -f '{{.State.StartedAt}}' "$n" | cut -c1-19 | tr 'T' ' ')
    info="$n  $state  restarts=$restarts  since=$up${health:+  health=$health}"
    if [ "$state" != "running" ] || [ "$health" = "unhealthy" ]; then
      bad "$info"
    elif [ "$restarts" -gt 0 ]; then
      warn "$info  (has restarted, may have crashed)"
    else
      ok "$info"
    fi
  done

  echo
  echo "[Ports]"
  check_port() {   # container name, port, description
    exists "$1" || return
    if listen "$2"; then ok "$2  $3"; else bad "$2  $3  (nothing is listening on this port)"; fi
  }
  check_port nodered    1880  "Node-RED"
  check_port emqx       1883  "MQTT"
  check_port emqx       18083 "EMQX dashboard"
  check_port mysql      3306  "MySQL"
  check_port phpmyadmin 8080  "phpMyAdmin"

  echo
  echo "[Services]"
  if exists mysql; then
    if out=$(docker exec -e MYSQL_PWD="$DB_PASS" mysql mysqladmin -uroot ping 2>&1); then
      ok "MySQL responding ($out)"
    else
      bad "MySQL not responding: $(echo "$out" | tail -n 1)"
    fi
  fi
  if exists nodered; then
    code=$(http http://localhost:1880)
    case "$code" in
      2*|3*|401) ok "Node-RED HTTP $code" ;;
      *)         bad "Node-RED HTTP ${code:-000}" ;;
    esac
  fi
  if exists phpmyadmin; then
    code=$(http http://localhost:8080)
    case "$code" in
      2*|3*) ok "phpMyAdmin HTTP $code" ;;
      *)     bad "phpMyAdmin HTTP ${code:-000}" ;;
    esac
  fi
  if command -v apache2 >/dev/null 2>&1; then
    if systemctl is-active --quiet apache2; then
      code=$(http http://localhost:80)
      case "$code" in
        2*|3*|401|403) ok "Apache HTTP $code" ;;
        *)             bad "Apache HTTP ${code:-000}" ;;
      esac
    else
      bad "Apache not running (systemctl status apache2)"
    fi
  fi
  if exists emqx; then
    if docker exec emqx emqx ctl status >/dev/null 2>&1; then
      clients=$(docker exec emqx emqx ctl clients list 2>/dev/null | grep -c '^Client')
      ok "EMQX running  connected clients=$clients"
    else
      bad "EMQX did not answer ctl status"
    fi
  fi

  echo
  echo "[Resources]"
  if [ -n "$(docker ps -q)" ]; then
    docker stats --no-stream --format "  {{.Name}}\tCPU {{.CPUPerc}}\tRAM {{.MemUsage}}" | column -t -s $'\t'
  else
    skip "No running containers"
  fi
  echo
  free -h | awk 'NR==1 || /^Mem/ {print "  " $0}'
  disk=$(df -h / | awk 'NR==2 {print $5 " used (" $3 " / " $2 ")"}')
  pct=$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')
  if [ "$pct" -ge 90 ]; then bad "Disk /  $disk"; elif [ "$pct" -ge 80 ]; then warn "Disk /  $disk"; else ok "Disk /  $disk"; fi
  echo "  Docker: $(docker system df --format '{{.Type}} {{.Size}}' | paste -sd ' ' -)"

  echo
  if [ "$FAILS" -eq 0 ]; then
    echo "${G}Everything is OK${N}"
  else
    echo "${R}Found $FAILS problem(s)${N}  (see logs: docker logs --tail 50 <container name>)"
    return 1
  fi
}

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

# =====================================================================
#  Insider mode  (hidden: not shown in the menu or --help; reachable only by typing 1225 at the main menu, not as a command)
#  Two topics:
#    1) Push to Deploy guide (text)
#    2) Source repo: the main server mirrors the GitHub repo and shares it over HTTP; a dev machine downloads
#       the frontend, the backend or both from the main server
# =====================================================================
INSIDER_REPO_URL="${INSIDER_REPO_URL:-https://github.com/LittleSoldier2185/insider_file.git}"

cmd_insider() {
  local pick
  echo "=== Insider mode ==="
  echo "  1) Push to Deploy guide"
  echo "  2) Source code (server: publish the repo / dev machine: download frontend or backend)"
  echo "  3) Exit"
  read -r -p "Choose [1]: " pick
  case "${pick:-1}" in
    1) insider_guide ;;
    2) insider_source ;;
    *) echo "Cancelled" ;;
  esac
}

# ---------------------------------------------------------------------
#  topic 2: source code
# ---------------------------------------------------------------------
insider_source() {
  local pick
  echo
  echo "Source code ($INSIDER_REPO_URL)"
  echo "  1) Main server : publish the repo so dev machines can download it (needs sudo + internet)"
  echo "  2) Dev machine : download the source code from the main server (frontend / backend / both)"
  echo "  3) Exit"
  read -r -p "Choose [2]: " pick
  case "${pick:-2}" in
    1) insider_publish ;;
    2) insider_download ;;
    *) echo "Cancelled" ;;
  esac
}

# main server: keep a bare mirror of the GitHub repo in the bundle folder and share it over HTTP
# (run again at any time to pull the latest commits from GitHub)
insider_publish() {
  [ "$(id -u)" -eq 0 ] || { echo "This part needs root: sudo bash $0 (then 1225)"; return 1; }
  local R rc=0 IP
  BUNDLE=/srv/iot-bundle
  BPORT=8000
  R="$BUNDLE/insider.git"
  command -v git >/dev/null 2>&1 || apt-get install -y git || { echo "!! Could not install git"; return 1; }
  command -v python3 >/dev/null 2>&1 || apt-get install -y python3 || { echo "!! Could not install python3"; return 1; }
  mkdir -p "$BUNDLE"
  if [ -d "$R" ]; then
    echo "Updating the mirror from GitHub..."
    git -C "$R" remote update --prune || rc=1
  else
    echo "Cloning $INSIDER_REPO_URL ..."
    git clone --mirror "$INSIDER_REPO_URL" "$R" || { echo "!! Clone failed (no internet? wrong URL?)"; rm -rf "$R"; return 1; }
  fi
  git -C "$R" update-server-info   # needed so plain HTTP can serve the repo
  if ! systemctl is-active --quiet iot-bundle 2>/dev/null; then
    echo "Starting the HTTP file server on port $BPORT..."
    serve_bundle
  fi
  ufw_allow "$BPORT"
  IP=$(my_ip)
  echo
  echo "================================================"
  [ "$rc" -eq 0 ] && echo "Repo published: http://$IP:$BPORT/insider.git" || echo "!! The mirror could not be refreshed from GitHub (serving the previous copy)"
  echo "Latest commit: $(git -C "$R" log -1 --format='%h %s (%cd)' --date=short 2>/dev/null)"
  echo "On a dev machine: bash iot.sh  ->  1225  ->  2  ->  2"
  echo "Or by hand:       git clone http://$IP:$BPORT/insider.git"
  echo "To pick up new commits from GitHub, run this again."
  echo "================================================"
  return "$rc"
}

# dev machine: clone (or update) from the main server and keep only the chosen part. No root needed.
insider_download() {
  command -v git >/dev/null 2>&1 || { echo "!! git is required (Ubuntu: sudo apt-get install git)"; return 1; }
  local URL DEST pick DIRS="" what d host RUNAS=()
  # when started with sudo, create the files as the real user, not root
  [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && RUNAS=(sudo -u "$SUDO_USER")

  URL=""
  [ -s "$BUNDLE_URL_FILE" ] && URL="$(cat "$BUNDLE_URL_FILE")"
  read -r -p "Main server URL [${URL:-http://192.168.10.2:8000}]: " pick
  URL="${pick:-${URL:-http://192.168.10.2:8000}}"
  echo "$URL" | grep -Eq "^https?://[A-Za-z0-9.:-]+/?$" || { echo "Invalid URL: $URL"; return 1; }
  URL="${URL%/}"

  echo "What do you need?"
  echo "  1) frontend  (Vue)"
  echo "  2) backend   (Node.js API)"
  echo "  3) both"
  read -r -p "Choose [1]: " pick
  case "${pick:-1}" in
    1) what=frontend; DIRS="frontend" ;;
    2) what=backend;  DIRS="backend" ;;
    3) what=both;     DIRS="frontend backend" ;;
    *) echo "Cancelled"; return 0 ;;
  esac

  read -r -p "Download into folder [./insider_file]: " DEST
  DEST="${DEST:-./insider_file}"

  if [ -d "$DEST/.git" ]; then
    echo "$DEST already exists: updating it"
    "${RUNAS[@]+"${RUNAS[@]}"}" git -C "$DEST" remote set-url origin "$URL/insider.git" || return 1
    "${RUNAS[@]+"${RUNAS[@]}"}" git -C "$DEST" sparse-checkout disable 2>/dev/null
    "${RUNAS[@]+"${RUNAS[@]}"}" git -C "$DEST" pull --ff-only || { echo "!! Update failed (local changes? run git status in $DEST)"; return 1; }
  else
    [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ] && { echo "!! $DEST exists and is not empty"; return 1; }
    "${RUNAS[@]+"${RUNAS[@]}"}" git clone "$URL/insider.git" "$DEST" || { echo "!! Clone failed. Has the main server published it? (1225 -> 2 -> 1 on the server)"; return 1; }
  fi
  # keep only the chosen folders (top-level files such as README.md and docker-compose.yml always stay)
  if [ "$what" != both ]; then
    "${RUNAS[@]+"${RUNAS[@]}"}" git -C "$DEST" sparse-checkout set --cone $DIRS || return 1
  fi

  # point npm at the main server's registry for these folders only (if the registry is up)
  host=${URL#*://}; host=${host%%[:/]*}
  if curl -fsS -m 3 "http://$host:$REGISTRY_PORT/-/ping" >/dev/null 2>&1; then
    for d in $DIRS; do
      [ -e "$DEST/$d/.npmrc" ] || printf 'registry=http://%s:%s/\n' "$host" "$REGISTRY_PORT" | "${RUNAS[@]+"${RUNAS[@]}"}" tee "$DEST/$d/.npmrc" >/dev/null
    done
    printf '.npmrc\n' | "${RUNAS[@]+"${RUNAS[@]}"}" tee -a "$DEST/.git/info/exclude" >/dev/null
    echo "npm registry: http://$host:$REGISTRY_PORT/ (written to .npmrc in: $DIRS)"
  else
    echo "(npm registry http://$host:$REGISTRY_PORT/ not reachable: npm will use its default registry)"
  fi

  echo
  echo "Done: $DEST  ($what)"
  for d in $DIRS; do
    case "$d" in
      frontend) echo "  cd $DEST/frontend && npm install && npm run dev" ;;
      backend)  echo "  cd $DEST/backend && npm install && npm run seed && npm run dev" ;;
    esac
  done
  echo "Update later:  cd $DEST && git pull"
}

# ---------------------------------------------------------------------
#  topic 1: Push to Deploy guide
# ---------------------------------------------------------------------
insider_guide() {
  cat <<'EOF_INSIDER'

#####################################################################
#  Push to Deploy: No-Hook Version
#####################################################################

No hook file. Push with git, then run Compose over SSH.
Replace "user" and "SERVER_IP" with your own values.

---------------------------------------------------------------------
1. On the server (once)
---------------------------------------------------------------------
  mkdir -p ~/app && cd ~/app
  git init -b main
  git config receive.denyCurrentBranch updateInstead

"updateInstead" lets you push straight into a normal repo and updates
the files in the folder for you.

---------------------------------------------------------------------
2. On your computer (once)
---------------------------------------------------------------------
  ssh-copy-id user@SERVER_IP
  git init -b main
  git remote add production ssh://user@SERVER_IP/home/user/app

Your project root needs a Dockerfile and a compose.yaml.

---------------------------------------------------------------------
3. Deploy (every time)
---------------------------------------------------------------------
  git add .
  git commit -m "update"
  git push production main
  ssh user@SERVER_IP "cd ~/app && docker compose up -d --build"

---------------------------------------------------------------------
4. Optional: one command with deploy.sh
---------------------------------------------------------------------
  #!/bin/bash
  set -e
  git push production main
  ssh user@SERVER_IP "cd ~/app && docker compose up -d --build"

Save it as deploy.sh, run "chmod +x deploy.sh" once, then use
./deploy.sh after each commit.

---------------------------------------------------------------------
Things to know
---------------------------------------------------------------------
- Clean folder required: the push is refused if files in ~/app on the
  server were edited by hand. Do not edit code there. Untracked files
  such as .env are fine.
- Trade-off: unlike the hook version, a plain push does not rebuild.
  You must run the ssh line (or deploy.sh).
- "permission denied (docker)": run
    sudo usermod -aG docker $USER
  on the server, then log out and in.


#####################################################################
#  Running Docker Compose on the Server
#####################################################################

The last step after git push. Replace "user" and "SERVER_IP".

---------------------------------------------------------------------
The command
---------------------------------------------------------------------
Run on the server inside ~/app, where the pushed docker-compose.yml lives:

  ssh user@SERVER_IP "cd ~/app && docker compose up -d"

---------------------------------------------------------------------
What it does with your compose file
---------------------------------------------------------------------
  Order  Service     Action
  1      db          Starts MySQL 8.4 and waits for the healthcheck to pass.
  2      phpmyadmin  Starts phpMyAdmin connected to db.
  3      backend     Runs npm install, npm run seed, npm run dev.
  4      frontend    Runs npm install, npm run dev.

The first run is slow: images must download and npm packages install.
Watch progress with:  docker compose logs -f backend

---------------------------------------------------------------------
Check that it is up
---------------------------------------------------------------------
  ssh user@SERVER_IP "cd ~/app && docker compose ps"

  Service      URL
  frontend     http://SERVER_IP:5173
  backend      http://SERVER_IP:3000
  phpMyAdmin   http://SERVER_IP:8080

---------------------------------------------------------------------
Common commands (run inside ~/app on the server)
---------------------------------------------------------------------
  Goal                              Command
  View logs                         docker compose logs -f backend
  Restart services                  docker compose restart backend frontend
  Stop everything (DB data kept)    docker compose down
  Stop and delete DB data           docker compose down -v   (data is lost)

---------------------------------------------------------------------
On later deploys
---------------------------------------------------------------------
After each push, run the same "docker compose up -d". If the compose
file is unchanged it does nothing, and new code is picked up through
the bind mounts by "npm run dev". After editing package.json, also run:

  docker compose restart backend frontend

Note that "npm run seed" runs on every backend start.

EOF_INSIDER
}
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

# =====================================================================
#  main
# =====================================================================
trap 'rm -f "${SUMS:-}" "${SUMS:-}".*' EXIT

# global options (any position): --yes/-y answers confirmations (never wipes data), --version prints the version
ARGS=()
for a in "$@"; do
  case "$a" in
    --yes|-y)              ASSUME_YES=1 ;;
    --version|-v|version)  echo "iot.sh v$VERSION"; exit 0 ;;
    *)                     ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

CMD="${1:-}"
if [ -z "$CMD" ]; then
  echo "Choose a task"
  echo "  -- New machine (do this before installing) --"
  echo "  1) setup    set up the machine: timezone, IP/network, base packages, firewall"
  echo "  -- Machine with internet / main server --"
  echo "  2) install  install the stack (has internet)"
  echo "  3) proxy    set up a proxy so other machines can reach the internet"
  echo "  4) bundle   download everything and share it with other machines"
  echo "  -- Machine without internet --"
  echo "  5) install  install through the main server's proxy"
  echo "  6) install  install from the main server's bundle"
  echo "  -- General --"
  echo "  7) status   show status"
  echo "  8) reset    remove what was installed"
  echo "  9) update   update iot.sh itself"
  echo "  10) frontend  download the frontend files from the main server (dev machine)"
  echo "  11) backend   download the backend files from the main server (dev machine)"
  read -r -p "Choose: " M
  case "$M" in
    1) CMD=setup ;;
    2) CMD=install ;;
    3) CMD=proxy ;;
    4) CMD=bundle ;;
    5) CMD=install; set -- install --proxy ;;
    6) CMD=install; set -- install --from ;;
    7) CMD=status ;;
    8) CMD=reset ;;
    9) CMD=update ;;
    10) CMD=frontend; set -- frontend --from ;;
    11) CMD=backend; set -- backend --from ;;
    1225) cmd_insider; exit $? ;;   # hidden entry (menu only, not a command)
    *) echo "Cancelled"; exit 1 ;;
  esac
fi
[ $# -gt 0 ] && shift

# the menu can start without root (Insider mode has a dev-machine part); every other command needs root
case "$CMD" in
  frontend|backend) ;;
  *) [ "$(id -u)" -eq 0 ] || { echo "Please run as root: sudo bash $0 $CMD"; exit 1; } ;;
esac

# log install/proxy/bundle/update/reset with timestamps (setup has its own log; status stays on the terminal for colours)
case "$CMD" in
  install|proxy|bundle|update|reset)
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "---- iot.sh v$VERSION $CMD $(date '+%Y-%m-%d %H:%M:%S') ----"
    ;;
esac

case "$CMD" in
  setup)   cmd_setup "$@" ;;
  install) cmd_install "$@" ;;
  proxy)   cmd_proxy "$@" ;;
  bundle)  cmd_bundle ;;
  update)  cmd_update "$@" ;;
  status)  cmd_status ;;
  reset)   cmd_reset "$@" ;;
  frontend) cmd_frontend "$@" ;;
  backend)  cmd_backend "$@" ;;
  *) echo "Unknown command: $CMD (valid: setup install proxy bundle update status reset frontend backend)"; exit 1 ;;
esac
exit $?
