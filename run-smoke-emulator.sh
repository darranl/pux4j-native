#!/usr/bin/env bash
# Run the native DisplaySmokeTest against the JavaFX emulator (no hardware required).
# Build first: cd pux4j-native && mvn -DskipTests package -P smoke-emulator,x86_64
set -euo pipefail

DISPLAY_PROFILE="ssd1675a"
SCALE="3"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BINARY="$SCRIPT_DIR/target/pux4j-smoke-emulator-x86_64"

usage() {
  cat <<'EOF'
Usage:
  ./run-smoke-emulator.sh [--display=PROFILE] [--scale=N]

Options:
  --display=PROFILE   Display profile: ssd1675a (2.9" V2, default) or ssd1680 (2.13" V4)
  --scale=N           Canvas scale factor (default: 3)

Build first:
  cd pux4j-native && mvn -DskipTests package -P smoke-emulator,x86_64
EOF
}

while [[ $# -gt 0 ]]; do
  case ${1:-} in
    -h|--help)   usage; exit 0 ;;
    --display=*) DISPLAY_PROFILE="${1#--display=}"; shift ;;
    --scale=*)   SCALE="${1#--scale=}"; shift ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ ! -f "$BINARY" ]]; then
  echo "ERROR: $BINARY not found."
  echo "       Build: cd pux4j-native && mvn -DskipTests package -P smoke-emulator,x86_64"
  exit 1
fi

"$BINARY" \
  -Dpux4j.emulator.display="$DISPLAY_PROFILE" \
  -Dpux4j.emulator.scale="$SCALE"
