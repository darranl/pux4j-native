#!/usr/bin/env bash
# Creates symlinks in the local GraalVM CE x86_64 installation pointing to
# aarch64 static libraries from a mounted sysroot. Required for cross-compiling
# GraalVM native images to aarch64.
#
# Must be called inside 'podman unshare' after mounting the sysroot.
# deploy.sh calls this automatically.
#
# Environment variables:
#   SYSROOT               (required) Path to the aarch64 sysroot root.
#                         Obtain via: podman image mount <image>
#   SYSROOT_GRAALVM_HOME  GraalVM path inside the sysroot; defaults to $JAVA_HOME.
#                         For graalvm-pi-builder: /opt/graalvm

set -euo pipefail

if [ -z "${SYSROOT:-}" ]; then
    echo "ERROR: SYSROOT is not set" >&2
    exit 1
fi
if [ -z "${JAVA_HOME:-}" ]; then
    echo "ERROR: JAVA_HOME is not set" >&2
    exit 1
fi
if [ ! -x "${JAVA_HOME}/bin/native-image" ]; then
    echo "ERROR: JAVA_HOME does not point to a GraalVM CE installation: ${JAVA_HOME}" >&2
    exit 1
fi

LOCAL_GRAAL="${JAVA_HOME}"
SYSROOT_GRAAL="${SYSROOT}${SYSROOT_GRAALVM_HOME:-${LOCAL_GRAAL}}"

if [ ! -d "${SYSROOT_GRAAL}" ]; then
    echo "ERROR: GraalVM not found in sysroot at ${SYSROOT_GRAAL}" >&2
    echo "  Set SYSROOT_GRAALVM_HOME to the GraalVM path inside the sysroot (e.g. /opt/graalvm)" >&2
    exit 1
fi

echo "==> Setting up aarch64 static lib symlinks..."
echo "    Local GraalVM:   ${LOCAL_GRAAL}"
echo "    Sysroot GraalVM: ${SYSROOT_GRAAL}"

symlink() {
    local link="$1"
    local target="$2"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        echo "    OK (already correct): $link"
    elif [ -L "$link" ]; then
        ln -sfn "$target" "$link"
        echo "    Updated: $link -> $target"
    elif [ -e "$link" ]; then
        echo "ERROR: $link exists and is not a symlink — remove it manually" >&2
        exit 1
    else
        ln -s "$target" "$link"
        echo "    Created: $link -> $target"
    fi
}

# Static JDK libs: libjava.a, libnio.a, libnet.a, ...
symlink \
    "${LOCAL_GRAAL}/lib/static/linux-aarch64" \
    "${SYSROOT_GRAAL}/lib/static/linux-aarch64"

# SVM C libraries: liblibchelper.a, libjvm.a, libsvm_container.a, ...
symlink \
    "${LOCAL_GRAAL}/lib/svm/clibraries/linux-aarch64" \
    "${SYSROOT_GRAAL}/lib/svm/clibraries/linux-aarch64"

echo "==> Done."
