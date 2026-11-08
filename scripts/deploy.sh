#!/usr/bin/env bash
# Cross-compile pux4j native images on an x86_64 Linux machine and deploy them to a Raspberry Pi.
#
# Each app is its own native image (smoke, validation, demo, dice-demo) and contains that app only.
# The HAT is fixed when an image is built; build for the HAT that is on the Pi.
#
# Usage:
#   scripts/deploy.sh [OPTIONS] <host> <hat> <app>...
#   scripts/deploy.sh [OPTIONS] <host> <hat> --all
#
#   <hat>   hat-2in9v2 or hat-2in13v4 (the "hat-" prefix is optional)
#   <app>   smoke, validation, demo or dice-demo; --all means all four
#
# Prerequisites (tested on Arch Linux x86_64):
#   - the pux4j artifacts, at the version you build, are in the local Maven repository: run the
#     Maven build of the pux4j project first (mvn install). This script never builds or installs it.
#   - JAVA_HOME points to a GraalVM CE 25 installation (it must contain bin/native-image)
#   - podman, and the sysroot image below (podman pull it once)
#   - aarch64-linux-gnu-gcc, and QEMU aarch64 binfmt registered (for the CAP cache)
#   - a ~/.m2/settings.xml with a GitHub Packages token (server id "github") so Maven can fetch the
#     Pi4J FFM reachability metadata
#
# Options:
#   --user <user>            ssh user (default: whatever ssh chooses)
#   --dir <dir>              directory on the Pi that will contain the "pux4j-native" installation.
#                            Relative paths are relative to the Pi user's home; a leading "~/" is
#                            accepted (quote it, or your local shell expands the ~).
#                            Default: applications  (installed to ~/applications/pux4j-native)
#   --pux4j-version <v>      version of the pux4j artifacts to build against (default: the pom's)
#   --repo <dir>             local Maven repository (default: ~/.m2/repository)
#   --settings <file>        Maven settings file (default: ~/.m2/settings.xml when it exists)
#   --skip-build             deploy the images already in target/ without building
#   --dry-run                print what would be done without building, connecting or changing anything
#   -h, --help               show this help
#
# What it does on the Pi, in order (the Pi is changed only by step 2 and 3):
#   1. read-only checks: aarch64, SPI and I2C devices, tar. It warns about anything missing.
#   2. adds or replaces lib/<app> for the apps given and replaces bin/. Other apps in lib/ and the
#      logs/ directory are left alone.
#   3. runs bin/install.sh, which links pux4j-native into ~/bin (creating it if needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="ghcr.io/lofthouse-dev/graalvm-pi-builder:bookworm-25.3.4.1"
ALL_APPS=(smoke validation demo dice-demo)

# ── BUILD PHASE (inside podman unshare) ─────────────────────────────────────
# Re-invoked by the outer phase via: _BUILD_PHASE=1 podman unshare -- "$0"
# The environment set by the outer phase carries all parameters. The sysroot is mounted once for
# all the apps.
if [ "${_BUILD_PHASE:-}" = "1" ]; then
    echo "==> Mounting container image as sysroot..."
    SYSROOT=$(podman image mount "$IMAGE")
    echo "    Sysroot: $SYSROOT"
    cleanup() { podman image unmount "$IMAGE" 2>/dev/null || true; }
    trap cleanup EXIT

    # Symlink the aarch64 static JDK libs from the sysroot into the local GraalVM
    # (the GraalVM in graalvm-pi-builder is at /opt/graalvm).
    SYSROOT="$SYSROOT" SYSROOT_GRAALVM_HOME=/opt/graalvm "$SCRIPT_DIR/setup-aarch64-libs.sh"

    MVN_EXTRA=()
    [ -n "${_PUX4J_VERSION:-}" ] && MVN_EXTRA+=("-Dpux4j.version=${_PUX4J_VERSION}")
    [ -n "${_MAVEN_SETTINGS:-}" ] && MVN_EXTRA+=("--settings=${_MAVEN_SETTINGS}")

    for app in $_APPS; do
        echo "==> Building native image: $app for $_HAT"
        mvn -f "$NATIVE_ROOT/pom.xml" package \
            -P "${app},${_HAT}" \
            "-Dsysroot=$SYSROOT" \
            "-Dmaven.repo.local=${_MAVEN_REPO}" \
            ${MVN_EXTRA[@]+"${MVN_EXTRA[@]}"}
    done
    exit 0
fi

# ── OUTER PHASE ─────────────────────────────────────────────────────────────

TARGET_USER=""
PARENT_DIR="applications"
PUX4J_VERSION=""
MAVEN_REPO="${HOME}/.m2/repository"
MAVEN_SETTINGS=""
SETTINGS_GIVEN=0
SKIP_BUILD=0
DRY_RUN=0
ALL=0
TARGET_HOST=""
HAT=""
APPS=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die()   { echo "ERROR: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --user)          TARGET_USER="${2:?--user needs a value}"; shift 2 ;;
        --dir)           PARENT_DIR="${2:?--dir needs a value}"; shift 2 ;;
        --pux4j-version) PUX4J_VERSION="${2:?--pux4j-version needs a value}"; shift 2 ;;
        --repo)          MAVEN_REPO="${2:?--repo needs a value}"; shift 2 ;;
        --settings)      MAVEN_SETTINGS="${2:?--settings needs a value}"; SETTINGS_GIVEN=1; shift 2 ;;
        --skip-build)    SKIP_BUILD=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --all)           ALL=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        -*)              die "unknown option: $1 (see --help)" ;;
        *)               if   [[ -z "$TARGET_HOST" ]]; then TARGET_HOST="$1"
                         elif [[ -z "$HAT" ]];         then HAT="$1"
                         else APPS+=("$1"); fi
                         shift ;;
    esac
done

# No <host> (no arguments, or options only): show the help rather than a one-line error.
if [[ -z "$TARGET_HOST" ]]; then usage; exit 2; fi
[[ -n "$HAT" ]]         || die "<hat> is required: hat-2in9v2 or hat-2in13v4 (see --help)"
HAT="hat-${HAT#hat-}"
case "$HAT" in
    hat-2in9v2|hat-2in13v4) ;;
    *) die "unknown HAT '$HAT'. Valid: hat-2in9v2, hat-2in13v4" ;;
esac

if [[ $ALL -eq 1 ]]; then
    [[ ${#APPS[@]} -eq 0 ]] || die "give either app names or --all, not both"
    APPS=("${ALL_APPS[@]}")
fi
[[ ${#APPS[@]} -gt 0 ]] || die "name at least one app (smoke, validation, demo, dice-demo) or give --all"
for app in "${APPS[@]}"; do
    case "$app" in
        smoke|validation|demo|dice-demo) ;;
        *) die "unknown app '$app'. Valid: smoke, validation, demo, dice-demo" ;;
    esac
done
# drop duplicates, keep order
mapfile -t APPS < <(printf '%s\n' "${APPS[@]}" | awk '!seen[$0]++')

PARENT_DIR="${PARENT_DIR#\~/}"      # "~/x" means x, relative to the Pi user's home
[[ -n "$PARENT_DIR" && "$PARENT_DIR" != "~" ]] || die "--dir must be a directory name"

if [[ $SETTINGS_GIVEN -eq 0 && -f "${HOME}/.m2/settings.xml" ]]; then
    MAVEN_SETTINGS="${HOME}/.m2/settings.xml"
fi

REMOTE="${TARGET_USER:+$TARGET_USER@}$TARGET_HOST"
printf -v Q_PARENT '%q' "$PARENT_DIR"
REMOTE_DIR_SH="$Q_PARENT/pux4j-native"      # shell-quoted; relative paths are relative to the remote home
case "$PARENT_DIR" in /*) SHOW_DIR="$PARENT_DIR" ;; *) SHOW_DIR="~/$PARENT_DIR" ;; esac

log() { echo "[deploy] $*"; }

log "HAT:     $HAT"
log "apps:    ${APPS[*]}"
log "target:  $REMOTE:$SHOW_DIR/pux4j-native"

# ── 1. build ─────────────────────────────────────────────────────────────────
if [[ $SKIP_BUILD -eq 0 ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
        command -v podman &>/dev/null || { echo "ERROR: podman not found" >&2; exit 1; }
        podman image exists "$IMAGE" || { echo "ERROR: container image not found: $IMAGE" >&2
                                         echo "       Pull it with: podman pull --platform=linux/arm64 $IMAGE" >&2; exit 1; }
        if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/native-image" ]]; then
            echo "ERROR: JAVA_HOME must point to a GraalVM CE 25 installation (bin/native-image)" >&2
            exit 1
        fi
        # The pux4j artifacts must be in the local repository (this script never installs them).
        # The version defaults to the pom's: read it from the Maven property.
        if [[ -z "$PUX4J_VERSION" ]]; then
            PUX4J_VERSION="$(sed -n 's:.*<pux4j.version>\(.*\)</pux4j.version>.*:\1:p' "$NATIVE_ROOT/pom.xml" | head -1)"
        fi
        [[ -n "$PUX4J_VERSION" ]] || { echo "ERROR: cannot determine the pux4j version; give --pux4j-version" >&2; exit 1; }
        need=(pux4j-core "pux4j-driver-${HAT}")
        for app in "${APPS[@]}"; do
            case "$app" in
                smoke|validation) need+=(pux4j-validation) ;;
                demo)             need+=(pux4j-demo pux4j-launcher pux4j-fx) ;;
                dice-demo)        need+=(pux4j-dice-demo pux4j-launcher pux4j-fx) ;;
            esac
        done
        missing=0
        for a in $(printf '%s\n' "${need[@]}" | sort -u); do
            if [[ ! -f "$MAVEN_REPO/dev/pux4j/ui/$a/$PUX4J_VERSION/$a-$PUX4J_VERSION.jar" ]]; then
                echo "ERROR: $a $PUX4J_VERSION is not in $MAVEN_REPO" >&2; missing=1
            fi
        done
        if [[ $missing -eq 1 ]]; then
            echo "       Build and install the pux4j project first (mvn install in its root)," >&2
            echo "       or give --pux4j-version / --repo to match what you installed." >&2
            exit 1
        fi
        [[ -n "$MAVEN_SETTINGS" ]] || echo "WARN: no Maven settings file: the Pi4J FFM metadata needs a GitHub Packages token (server id \"github\")" >&2
    fi
    export _APPS="${APPS[*]}" _HAT="$HAT" _PUX4J_VERSION="$PUX4J_VERSION" \
           _MAVEN_REPO="$MAVEN_REPO" _MAVEN_SETTINGS="$MAVEN_SETTINGS"
    log "building (one native image per app, sysroot mounted once)..."
    if [[ $DRY_RUN -eq 1 ]]; then
        log "[DRY RUN] would run: _BUILD_PHASE=1 podman unshare -- $SCRIPT_DIR/deploy.sh   (mvn package -P <app>,$HAT for: ${APPS[*]})"
    else
        _BUILD_PHASE=1 podman unshare -- "$SCRIPT_DIR/deploy.sh"
    fi
else
    log "--skip-build: using the images already in target/"
fi

# ── 2. the images must exist ─────────────────────────────────────────────────
for app in "${APPS[@]}"; do
    img="$NATIVE_ROOT/target/pux4j-${app}-${HAT}"
    if [[ $DRY_RUN -eq 0 && ! -f "$img" ]]; then
        echo "ERROR: image not found: $img" >&2
        echo "       Build it: run this script without --skip-build." >&2
        exit 1
    fi
done

# ── 3. stage what goes to the Pi ─────────────────────────────────────────────
STAGE_BASE="${TMPDIR:-$HOME/tmp/pux4j-native}"
mkdir -p "$STAGE_BASE"
STAGE="$(mktemp -d "$STAGE_BASE/deploy.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/lib"
cp "$NATIVE_ROOT/dist/bin/pux4j-native" "$NATIVE_ROOT/dist/bin/install.sh" "$STAGE/bin/"
chmod +x "$STAGE/bin/"*
if [[ $DRY_RUN -eq 0 ]]; then
    for app in "${APPS[@]}"; do
        cp "$NATIVE_ROOT/target/pux4j-${app}-${HAT}" "$STAGE/lib/$app"
        chmod +x "$STAGE/lib/$app"
    done
fi

# ── 4. read-only checks on the Pi ────────────────────────────────────────────
CHECK_SCRIPT='
arch=$(uname -m)
if [ "$arch" = "aarch64" ]; then echo "OK:   $arch"
else echo "WARN: this machine is $arch, the images are aarch64 and will not run here"; fi
if [ -e /dev/spidev0.0 ]; then echo "OK:   SPI device present"
else echo "WARN: /dev/spidev0.0 not found: SPI is not enabled (see the Raspberry Pi documentation, raspi-config)"; fi
if [ -e /dev/i2c-1 ]; then echo "OK:   I2C device present"
else echo "WARN: /dev/i2c-1 not found: I2C is not enabled (see the Raspberry Pi documentation, raspi-config)"; fi
command -v tar >/dev/null 2>&1 && echo "OK:   tar" || { echo "ERROR: tar is missing on the Pi"; exit 1; }
'
log "checking the Pi (read-only)..."
if [[ $DRY_RUN -eq 1 ]]; then
    log "[DRY RUN] would run on $REMOTE: architecture, /dev/spidev0.0, /dev/i2c-1 and tar checks"
else
    ssh "$REMOTE" "sh -s" <<< "$CHECK_SCRIPT"
fi

# ── 5. copy ──────────────────────────────────────────────────────────────────
# Unpack next to the old files first; bin/ and the lib/<app> files given are replaced only after the
# whole stream arrived, so a failed transfer leaves the previous deployment working. Other lib/ files
# and logs/ are not touched.
REMOTE_UNPACK="set -e; d=$REMOTE_DIR_SH; mkdir -p \"\$d/lib\" \"\$d/logs\"; cd \"\$d\"; rm -rf .new; mkdir .new; tar -xf - -C .new; rm -rf bin; mv .new/bin bin; for f in .new/lib/*; do mv -f \"\$f\" lib/; done; rm -rf .new"
log "copying bin/ and lib/{${APPS[*]}} (other apps and logs/ are kept)..."
if [[ $DRY_RUN -eq 1 ]]; then
    log "[DRY RUN] would run: tar -C <staging> -cf - bin lib | ssh $REMOTE '<unpack into $PARENT_DIR/pux4j-native>'"
else
    COPYFILE_DISABLE=1 tar -C "$STAGE" -cf - bin lib | ssh "$REMOTE" "$REMOTE_UNPACK"
fi

# ── 6. install ───────────────────────────────────────────────────────────────
log "running bin/install.sh on the Pi..."
if [[ $DRY_RUN -eq 1 ]]; then
    log "[DRY RUN] would run on $REMOTE: bash $PARENT_DIR/pux4j-native/bin/install.sh"
else
    ssh "$REMOTE" "bash $REMOTE_DIR_SH/bin/install.sh"
fi

log "Done. On $TARGET_HOST:"
log "    pux4j-native --list     (if ~/bin is on your PATH; otherwise: $SHOW_DIR/pux4j-native/bin/pux4j-native --list)"
log "    pux4j-native <app>      the JavaFX apps need a desktop session: export DISPLAY=:0 (or :1) first"
