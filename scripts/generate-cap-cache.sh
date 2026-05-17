#!/usr/bin/env bash
# Generates the GraalVM CAP cache for aarch64 cross-compilation.
#
# The CAP cache (Cross-Architecture Profile) stores aarch64 C type layout data
# (struct sizes, alignments) by running small C probe programs inside a QEMU
# arm64 Podman container. This data is required by native-image when cross-
# compiling from x86_64 to aarch64. It is architecture-specific, not code-
# specific — regenerate only after mvn clean, a GraalVM CE upgrade, or a
# Debian bookworm glibc update.
#
# Called from Maven via exec-maven-plugin (package phase) after
# maven-dependency-plugin:copy-dependencies has collected JARs into target/deps/.
#
# Usage (from Maven — args set by exec-maven-plugin):
#   generate-cap-cache.sh --skip-collect
#                         --cap-cache-dir=PATH
#                         --deps-dir=PATH
#                         --main-class=FQCN
#
# Prerequisites:
#   - Podman installed and usable (this script may run inside podman unshare)
#   - QEMU aarch64 binfmt registered:
#       Arch Linux: sudo pacman -S qemu-user-static-binfmt
#                   sudo systemctl restart systemd-binfmt

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="ghcr.io/lofthouse-dev/graalvm-pi-builder:bookworm-graal25"

SKIP_COLLECT=false
CAP_CACHE_DIR="$PROJECT_ROOT/target/cap-cache"
DEPS_DIR="$PROJECT_ROOT/target/deps"
MAIN_CLASS=""

for arg in "$@"; do
    case "$arg" in
        --skip-collect)       SKIP_COLLECT=true ;;
        --cap-cache-dir=*)    CAP_CACHE_DIR="${arg#--cap-cache-dir=}" ;;
        --deps-dir=*)         DEPS_DIR="${arg#--deps-dir=}" ;;
        --main-class=*)       MAIN_CLASS="${arg#--main-class=}" ;;
        *) echo "ERROR: Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [ -z "$MAIN_CLASS" ]; then
    echo "ERROR: --main-class is required" >&2
    exit 1
fi

# Early-exit if cache is already populated
if compgen -G "$CAP_CACHE_DIR/*.cap" > /dev/null 2>&1; then
    echo "==> CAP cache up to date at $CAP_CACHE_DIR, skipping."
    exit 0
fi

# Preflight checks
if ! command -v podman &>/dev/null; then
    echo "ERROR: podman not found." >&2
    exit 1
fi

if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "ERROR: QEMU aarch64 binfmt handler not registered." >&2
    echo "  Arch Linux: sudo pacman -S qemu-user-static-binfmt" >&2
    echo "              sudo systemctl restart systemd-binfmt" >&2
    exit 1
fi

if [ "$SKIP_COLLECT" = false ]; then
    echo "==> Collecting dependency JARs into $DEPS_DIR ..."
    mvn -f "$PROJECT_ROOT/pom.xml" dependency:copy-dependencies \
        -DoutputDirectory="$DEPS_DIR" -DincludeScope=runtime -q
fi

if [ ! -d "$DEPS_DIR" ] || [ -z "$(ls -A "$DEPS_DIR" 2>/dev/null)" ]; then
    echo "ERROR: No JARs in $DEPS_DIR — was maven-dependency-plugin:copy-dependencies run?" >&2
    exit 1
fi

if ! podman image exists "$IMAGE_TAG"; then
    echo "ERROR: Container image not found: $IMAGE_TAG" >&2
    echo "  Pull with: podman pull $IMAGE_TAG" >&2
    exit 1
fi

# Build /deps/jar1.jar:/deps/jar2.jar:... for use inside the container
CONTAINER_CP=$(
    ls "$DEPS_DIR"/*.jar | xargs -n1 basename | sed 's|^|/deps/|' | paste -sd':'
)

mkdir -p "$CAP_CACHE_DIR"
echo "==> Generating aarch64 CAP cache (QEMU arm64 container)..."
echo "    Main class: $MAIN_CLASS"

podman run --rm \
    --platform=linux/arm64 \
    -v "$DEPS_DIR":/deps:Z \
    -v "$CAP_CACHE_DIR":/cap-cache:Z \
    "$IMAGE_TAG" \
    native-image \
        -H:+UnlockExperimentalVMOptions \
        -H:+NewCAPCache \
        -H:+ExitAfterCAPCache \
        -H:CAPCacheDir=/cap-cache \
        -cp "$CONTAINER_CP" \
        "$MAIN_CLASS"

echo "==> CAP cache written to $CAP_CACHE_DIR"
