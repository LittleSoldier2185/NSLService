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

