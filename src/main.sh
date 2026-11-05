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
