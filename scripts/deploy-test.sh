#!/usr/bin/env bash
# Tests of scripts/deploy.sh and dist/bin/pux4j-native. Needs only bash and coreutils: a fake `ssh`
# on the PATH runs the "remote" command locally under a scratch HOME, and the images are tiny shell
# scripts, so no Pi, no podman, no GraalVM and no network are involved. Every deploy uses --skip-build.
#
# Run from anywhere:   pux4j-native/scripts/deploy-test.sh
# Creates (and removes) its scratch directories under ${TMPDIR:-$HOME/tmp/pux4j-native}.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${TMPDIR:-$HOME/tmp/pux4j-native}"
mkdir -p "$BASE"
WORK="$(mktemp -d "$BASE/deploy-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "ok   - $1"; pass=$((pass+1)); }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
rc_is() { [ "$1" -eq "$2" ] && ok "$3" || bad "$3 (exit $1, wanted $2)"; }

# A synthetic copy of the project: the scripts under test plus fake images in target/.
REPO="$WORK/repo"; PIHOME="$WORK/pihome"; FAKEBIN="$WORK/fakebin"
mkdir -p "$REPO/scripts" "$REPO/dist" "$REPO/target" "$PIHOME" "$FAKEBIN"
cp "$ROOT/scripts/deploy.sh" "$REPO/scripts/"
cp -r "$ROOT/dist/bin" "$REPO/dist/"
cp "$ROOT/pom.xml" "$REPO/pom.xml"

make_image() { # $1 = app, $2 = hat, $3 = exit code of the fake app
    cat > "$REPO/target/pux4j-$1-$2" <<IMG
#!/usr/bin/env bash
echo "image $1 args: \$*"
echo "DISPLAY=\$DISPLAY HOME_DIR=\$PUX4J_HOME"
exit ${3:-0}
IMG
    chmod +x "$REPO/target/pux4j-$1-$2"
}
for a in smoke validation demo dice-demo; do make_image "$a" hat-2in9v2; make_image "$a" hat-2in13v4; done

# Fake ssh: ssh [user@]host command -> run the command locally with HOME=$PIHOME.
cat > "$FAKEBIN/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_SSH_LOG"
shift
cd "$FAKE_PIHOME" || exit 99
HOME="$FAKE_PIHOME" exec bash -c "$1"
FAKE
chmod +x "$FAKEBIN/ssh"
export FAKE_PIHOME="$PIHOME" FAKE_SSH_LOG="$WORK/ssh.log"
export PATH="$FAKEBIN:$PATH"
run() { (cd "$REPO" && scripts/deploy.sh --skip-build "$@"); }
INST="$PIHOME/applications/pux4j-native"
PUX="$INST/bin/pux4j-native"

# --- usage errors: exit 2 ----------------------------------------------------------
run >/dev/null 2>&1;                         rc_is $? 2 "no arguments: exit 2"
run 2>&1 | grep -q "^Usage:";             rc_is ${PIPESTATUS[1]} 0 "no arguments: prints the usage"
run pi >/dev/null 2>&1;                      rc_is $? 2 "no hat: exit 2"
run pi 2in9v2 >/dev/null 2>&1;               rc_is $? 2 "no app: exit 2"
run pi 7in5 smoke >/dev/null 2>&1;           rc_is $? 2 "unknown hat: exit 2"
run pi 2in9v2 nosuch >/dev/null 2>&1;        rc_is $? 2 "unknown app: exit 2"
run pi 2in9v2 smoke --all >/dev/null 2>&1;   rc_is $? 2 "apps and --all together: exit 2"
run --bogus pi 2in9v2 smoke >/dev/null 2>&1; rc_is $? 2 "unknown option: exit 2"

# --- the image must exist ----------------------------------------------------------------
mv "$REPO/target/pux4j-demo-hat-2in9v2" "$WORK/demo.img"
out="$(run pi 2in9v2 demo 2>&1)"; rc=$?
rc_is $rc 1 "missing image: exit 1"
case "$out" in *"without --skip-build"*) ok "missing image: message says how to build" ;; *) bad "missing image: message" ;; esac
mv "$WORK/demo.img" "$REPO/target/pux4j-demo-hat-2in9v2"
check "missing image: nothing was copied" test ! -e "$INST"

# --- first deploy of one app ------------------------------------------------------------------
out="$(run pi 2in9v2 smoke 2>&1)"; rc=$?
rc_is $rc 0 "deploy smoke: exit 0"
check "deploy smoke: lib/smoke executable"   test -x "$INST/lib/smoke"
check "deploy smoke: no other app installed" test ! -e "$INST/lib/demo"
check "deploy smoke: dispatcher executable"  test -x "$PUX"
check "deploy smoke: install.sh present"     test -x "$INST/bin/install.sh"
check "deploy smoke: logs/ created"          test -d "$INST/logs"
check "deploy smoke: ~/bin link made"        test -L "$PIHOME/bin/pux4j-native"
check "deploy smoke: no .new left"           test ! -e "$INST/.new"
check "deploy smoke: no HAT name Pi-side"    bash -c "! find '$INST' '$PIHOME/bin' -name '*hat*' | grep -q ."
grep -qx "pi" "$FAKE_SSH_LOG" && ok "no --user: ssh gets the bare host" || bad "no --user: ssh target"

# --- the dispatcher ---------------------------------------------------------------------------
out="$("$PUX" 2>&1)"; rc=$?
rc_is $rc 0 "one app installed: runs without a name"
case "$out" in *"image smoke args:"*) ok "driver test: runs the smoke image" ;; *) bad "driver test: output ($out)" ;; esac
case "$out" in *"args: smoke"*) bad "driver test: app name must not be passed" ;; *) ok "driver test: app name not passed" ;; esac
"$PUX" smoke --start-step 3 -Dx=y 2>&1 | grep -q "args: -Dx=y --start-step 3" && ok "driver test: -D first, then its arguments" || bad "driver test: argument passing"
check "log written" test -f "$INST/logs/smoke.log"
grep -q "image smoke" "$INST/logs/smoke.log" && ok "log has the output" || bad "log content"
echo stale >> "$INST/logs/smoke.log"; "$PUX" smoke >/dev/null 2>&1
grep -q stale "$INST/logs/smoke.log" && bad "log is replaced on each run" || ok "log is replaced on each run"
out="$("$PUX" --list 2>&1)"; rc=$?
rc_is $rc 0 "--list: exit 0"
case "$out" in *smoke*"driver test"*) ok "--list: names the app and its kind" ;; *) bad "--list: output ($out)" ;; esac
"$PUX" nosuch >/dev/null 2>&1; rc_is $? 2 "unknown app: exit 2"
"$PUX" ../x >/dev/null 2>&1;   rc_is $? 2 "path as app name: exit 2"
"$PUX" --help >/dev/null 2>&1; rc_is $? 0 "--help: exit 0"

# --- additive deploy: more apps join, the first and the logs stay -------------------------------
run pi 2in9v2 demo dice-demo >/dev/null 2>&1; rc=$?
rc_is $rc 0 "deploy two more apps: exit 0"
check "additive: smoke still installed" test -x "$INST/lib/smoke"
check "additive: demo installed"        test -x "$INST/lib/demo"
check "additive: dice-demo installed"   test -x "$INST/lib/dice-demo"
check "additive: logs kept"             test -f "$INST/logs/smoke.log"
"$PUX" >/dev/null 2>&1; rc_is $? 2 "several apps, no name: exit 2"
out="$("$PUX" demo -Dpux4j.display.width=250 extra 2>&1)"
case "$out" in *"image demo args: -Dpux4j.display.width=250 demo"*) ok "JavaFX app: told its own name, extra args dropped" ;; *) bad "JavaFX app args ($out)" ;; esac
case "$out" in *"DISPLAY=:0"*) ok "DISPLAY defaults to :0" ;; *) bad "DISPLAY default" ;; esac
DISPLAY=:1 "$PUX" demo 2>&1 | grep -q "DISPLAY=:1" && ok "DISPLAY from the environment is kept" || bad "DISPLAY kept"
case "$out" in *"HOME_DIR=$INST"*) ok "PUX4J_HOME is the installation directory" ;; *) bad "PUX4J_HOME ($out)" ;; esac
check "--list shows all installed" bash -c "'$PUX' --list | grep -c . | grep -qx 4"

# --- a deploy leaves apps it was not asked about alone --------------------------------------------
echo other > "$INST/lib/other"; chmod +x "$INST/lib/other"
run pi 2in9v2 smoke >/dev/null 2>&1
check "re-deploy: an app not named is left alone" test -f "$INST/lib/other"
"$PUX" smoke 2>&1 | grep -q "image smoke" && ok "re-deploy: smoke image still runs" || bad "re-deploy"

# --- the app's exit code is the dispatcher's --------------------------------------------------------
make_image validation hat-2in9v2 7
run pi 2in9v2 validation >/dev/null 2>&1
"$PUX" validation >/dev/null 2>&1; rc_is $? 7 "app exit code is passed through"

# --- all apps; hat prefix optional; --user; --dir ----------------------------------------------------
rm -rf "$PIHOME/applications"; : > "$FAKE_SSH_LOG"
run --user pi --dir "my apps" host hat-2in13v4 --all >/dev/null 2>&1; rc=$?
rc_is $rc 0 "--all with --user and --dir: exit 0"
for a in smoke validation demo dice-demo; do
    check "--all: $a installed under the spaced dir" test -x "$PIHOME/my apps/pux4j-native/lib/$a"
done
grep -qx "pi@host" "$FAKE_SSH_LOG" && ok "--user: ssh gets user@host" || bad "--user: ssh target"
run --dir '~/tilde dir' host 2in9v2 smoke >/dev/null 2>&1; rc=$?
rc_is $rc 0 "--dir ~/x: exit 0"
check "--dir ~/x: relative to the Pi home" test -x "$PIHOME/tilde dir/pux4j-native/lib/smoke"
check "--dir ~/x: no literal ~ directory"  test ! -e "$PIHOME/~"

# --- a failed transfer leaves the previous deployment working -----------------------------------------
run pi 2in9v2 smoke >/dev/null 2>&1
cat > "$FAKEBIN/tar" <<'BADTAR'
#!/usr/bin/env bash
case " $* " in *" -xf "*) cat >/dev/null; exit 1 ;; *) exec /usr/bin/tar "$@" ;; esac
BADTAR
chmod +x "$FAKEBIN/tar"
run pi 2in9v2 smoke >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "failing tar: deploy fails" || bad "failing tar: exit 0"
check "failing tar: previous image kept" test -x "$INST/lib/smoke"
rm -f "$FAKEBIN/tar"

# --- dry run does nothing ------------------------------------------------------------------------------
rm -rf "$PIHOME/applications" "$PIHOME/bin"
out="$(cd "$REPO" && scripts/deploy.sh --dry-run host 2in9v2 --all 2>&1)"; rc=$?
rc_is $rc 0 "--dry-run (with build step): exit 0"
check "--dry-run: nothing created on the Pi" test ! -e "$PIHOME/applications"
case "$out" in *"[DRY RUN]"*) ok "--dry-run: says what it would do" ;; *) bad "--dry-run: output" ;; esac

# --- the shipped pom names the images the script expects ------------------------------------------------
for a in smoke validation demo dice-demo; do
    grep -q "<native.image.name>pux4j-$a-\${native.target.suffix}</native.image.name>" "$ROOT/pom.xml" \
        && ok "pom: image name pux4j-$a-<hat>" || bad "pom: image name for $a"
done

echo
if [ "$fail" -eq 0 ]; then echo "All $pass checks passed."; else echo "$fail of $((pass+fail)) checks FAILED."; exit 1; fi
