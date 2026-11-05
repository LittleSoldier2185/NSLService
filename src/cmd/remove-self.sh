# =====================================================================
#  remove self  (hidden: reachable only by typing 666 at the main menu, not as a command)
#  Deletes the whole folder only when it is the project folder (named NSLService, what `git clone` creates);
#  in any other folder it deletes just this script file.
#  It never touches installed software, Docker data, logs or /srv/iot-bundle.
# =====================================================================
cmd_remove_self() {
  local self dir mode=folder depth entries size ans git_note=""
  self=$(readlink -f "${BASH_SOURCE[0]}") || { echo "!! Cannot find where this script is"; return 1; }
  dir=$(dirname "$self")

  # only the project folder itself may be removed; anywhere else only this file goes
  [ "$(basename "$dir")" = "NSLService" ] || mode=file
  # shared / system locations: never remove the whole folder, even if it is named NSLService
  case "$dir" in
    /|/bin|/boot|/dev|/etc|/home|/lib*|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) mode=file ;;
    /srv/*|/var/*|/usr/*|/etc/*|/boot/*|/bin/*|/sbin/*|/lib*|/proc/*|/sys/*|/dev/*|/run/*) mode=file ;;
  esac
  [ "$dir" = "${HOME:-/nonexistent}" ] && mode=file
  [ "$dir" = "$(dirname "${HOME:-/nonexistent}")" ] && mode=file
  depth=$(printf '%s' "$dir" | tr -cd / | wc -c)
  [ "$depth" -lt 2 ] && mode=file
  mountpoint -q "$dir" 2>/dev/null && mode=file

  echo "=== Remove iot.sh ==="
  if [ "$mode" = folder ]; then
    entries=$(find "$dir" -mindepth 1 2>/dev/null | wc -l)
    size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    echo "This will DELETE the whole folder:"
    echo "  $dir   ($entries items, ${size:-?})"
    # do not lose unsaved work silently
    if command -v git >/dev/null 2>&1 && git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && git_note="uncommitted changes"
      [ -n "$(git -C "$dir" log --branches --not --remotes --oneline 2>/dev/null)" ] && git_note="${git_note:+$git_note and }commits that are not pushed"
      [ -n "$git_note" ] && echo "!! This folder is a git repo with $git_note: they will be lost."
    fi
  else
    echo "This is not the NSLService project folder (or it is a shared/system location), so only the script file will be deleted:"
    echo "  $self"
  fi
  echo "Not removed: installed software, Docker containers/volumes, logs, /srv/iot-bundle, systemd services."
  read -r -p "Type yes to delete (anything else cancels): " ans
  [ "$ans" = "yes" ] || { echo "Cancelled"; return 0; }

  cd / || return 1   # leave the folder before deleting it
  if [ "$mode" = folder ]; then
    rm -rf -- "$dir" || { echo "!! Could not delete $dir"; return 1; }
    echo "Deleted $dir"
  else
    rm -f -- "$self" || { echo "!! Could not delete $self"; return 1; }
    echo "Deleted $self"
  fi
}
