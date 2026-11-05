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

