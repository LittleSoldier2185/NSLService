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

