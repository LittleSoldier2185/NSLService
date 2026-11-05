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
  echo "  3) Guide       : how to get the frontend / backend files (text)"
  echo "  4) Exit"
  read -r -p "Choose [2]: " pick
  case "${pick:-2}" in
    1) insider_publish ;;
    2) insider_download ;;
    3) insider_files_guide ;;
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

# text only: how a dev machine gets the frontend / backend files
insider_files_guide() {
  cat <<'EOF_FILES'

#####################################################################
#  Getting the frontend / backend files
#####################################################################

Two kinds of files are prepared on the main server (the one with internet).

  A) Source code   - the project itself (this menu: Source code -> 1 / 2)
  B) Dependencies  - packages for npm (bundle: package.json, lock file,
                     npm registry mirror, ready-made frontend libraries)

---------------------------------------------------------------------
On the main server (once, and again after changes)
---------------------------------------------------------------------
  sudo bash iot.sh bundle            # dependencies (B): needs internet
  sudo bash iot.sh                   # then 1225 -> 2 -> 1 : publishes the source code (A)

Run the second command again whenever GitHub has new commits.
Ports used: 8000 (files and repo), 4873 (npm registry).

---------------------------------------------------------------------
On the dev machine (no root needed)
---------------------------------------------------------------------
Source code (A), choose frontend, backend or both:
  curl -fO http://SERVER_IP:8000/iot.sh
  bash iot.sh                        # then 1225 -> 2 -> 2
  or by hand: git clone http://SERVER_IP:8000/insider.git

Update later:  cd insider_file && git pull

Dependencies (B), when you want only the package files:
  bash iot.sh frontend --from http://SERVER_IP:8000 ./web
  bash iot.sh backend  --from http://SERVER_IP:8000 ./api

Both commands verify checksums and write a .npmrc in that folder so npm
uses http://SERVER_IP:4873/. Your own package.json is never overwritten
(the server's copy is saved as package.json.new).

Then:
  cd frontend && npm ci && npm run dev
  cd backend  && npm ci && npm run seed && npm run dev

The frontend also has ready-made libraries (Vue, Vuetify, axios ...) in
static/ ; open static/example.html in a browser, no npm needed.

---------------------------------------------------------------------
Problems
---------------------------------------------------------------------
- Clone fails / "Cannot fetch": check the URL and port 8000, and that the
  server ran "1225 -> 2 -> 1" (source) or "bundle" (dependencies).
  On the server: systemctl status iot-bundle
- npm cannot connect: check http://SERVER_IP:4873/-/ping and
  "docker ps" shows npm-registry on the server.
- "This bundle has no frontend files": the bundle is old, run bundle again.
- "Checksum ... does not match": run bundle again on the server, then retry.
- npm ci says the lock file is out of sync: use npm install instead.
- Only the frontend or backend is needed: choose it in step 2 (the other
  folder is not downloaded).

EOF_FILES
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
