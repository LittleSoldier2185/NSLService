#!/bin/bash
# Build src/*.sh into a single iot.sh (the file that gets distributed).
# Usage: ./build.sh [output]     default output: ./iot.sh
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-iot.sh}"

# Order matters: bash must define a function before it is called, main.sh goes last.
PARTS=(
  src/00-header.sh
  src/lib/10-common.sh
  src/lib/20-projects.sh
  src/cmd/install.sh
  src/cmd/proxy.sh
  src/cmd/bundle.sh
  src/cmd/update.sh
  src/cmd/status.sh
  src/cmd/reset.sh
  src/cmd/insider.sh
  src/cmd/remove-self.sh
  src/cmd/setup-1-core.sh
  src/cmd/setup-2-netplan.sh
  src/cmd/setup-3-ifupdown.sh
  src/cmd/setup-4-flow.sh
  src/main.sh
)

# every source file must be listed, so a new file is never silently left out
for f in $(find src -name '*.sh' | sort); do
  printf '%s\n' "${PARTS[@]}" | grep -qx "$f" || { echo "build: $f is not in PARTS" >&2; exit 1; }
done

TMP="$OUT.tmp"
: > "$TMP"
for f in "${PARTS[@]}"; do
  [ -f "$f" ] || { echo "build: missing $f" >&2; rm -f "$TMP"; exit 1; }
  tr -d '\r' < "$f" >> "$TMP"   # always emit LF, even if edited on Windows
done
bash -n "$TMP" || { rm -f "$TMP"; echo "build: syntax error" >&2; exit 1; }
chmod +x "$TMP"
mv "$TMP" "$OUT"
echo "built $OUT ($(wc -l < "$OUT") lines)"
