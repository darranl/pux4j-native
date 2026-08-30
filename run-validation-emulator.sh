#!/usr/bin/env bash
# Run the native HardwareValidationTest against the JavaFX emulator (no hardware required).
# Mouse click = touch down; mouse release = touch up.
# Build first: cd pux4j-native && mvn -DskipTests package -P validation-emulator,x86_64
set -euo pipefail

DISPLAY_PROFILE="ssd1675a"
SCALE="3"
EXTRA_ARGS=()
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BINARY="$SCRIPT_DIR/target/pux4j-validation-emulator-x86_64"

usage() {
  cat <<'EOF'
Usage:
  ./run-validation-emulator.sh [--display=PROFILE] [--scale=N] [extra args...]

Options:
  --display=PROFILE   Display profile: ssd1675a (2.9" V2, default) or ssd1680 (2.13" V4)
  --scale=N           Canvas scale factor (default: 3)
  extra args          Passed through to HardwareValidationTest (e.g. --start-step 3)

Build first:
  cd pux4j-native && mvn -DskipTests package -P validation-emulator,x86_64
EOF
}

while [[ $# -gt 0 ]]; do
  case ${1:-} in
    -h|--help)   usage; exit 0 ;;
    --display=*) DISPLAY_PROFILE="${1#--display=}"; shift ;;
    --scale=*)   SCALE="${1#--scale=}"; shift ;;
    *)           EXTRA_ARGS+=("$1"); shift ;;
  esac
done

case "$DISPLAY_PROFILE" in
  ssd1675a) TOUCH_NATIVE_W=296; TOUCH_NATIVE_H=128 ;;
  ssd1680)  TOUCH_NATIVE_W=250; TOUCH_NATIVE_H=122 ;;
  *)
    echo "ERROR: Unknown display profile '$DISPLAY_PROFILE'. Valid: ssd1675a, ssd1680"
    exit 1
    ;;
esac

if [[ ! -f "$BINARY" ]]; then
  echo "ERROR: $BINARY not found."
  echo "       Build: cd pux4j-native && mvn -DskipTests package -P validation-emulator,x86_64"
  exit 1
fi

"$BINARY" \
  -Dpux4j.emulator.display="$DISPLAY_PROFILE" \
  -Dpux4j.emulator.scale="$SCALE" \
  --touch-native-width "$TOUCH_NATIVE_W" \
  --touch-native-height "$TOUCH_NATIVE_H" \
  "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
