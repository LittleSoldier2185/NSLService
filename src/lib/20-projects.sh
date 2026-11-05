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
  echo "More help: bash iot.sh -> 1225 -> 2 -> 3"
}

cmd_frontend() { fetch_project frontend "$@"; }
cmd_backend()  { fetch_project backend "$@"; }
