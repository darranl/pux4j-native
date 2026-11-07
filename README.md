# pux4j-native

GraalVM native image builds for [pux4j](https://github.com/darranl/pux4j).

Produces aarch64 native executables, one per application, cross-compiled on an x86_64 Linux machine using
the [graalvm-pi-builder](https://github.com/lofthouse-dev/graalvm-pi-builder) container image. The
executables run on a Raspberry Pi without a JVM. The build and these instructions are tested on
Arch Linux, x86_64; the target is Raspberry Pi OS 12 (Debian bookworm), 64-bit.

## Apps and HATs

Each app is its own native image and contains that app only.

| App | What it is |
|---|---|
| `smoke` | non-JavaFX display smoke test of the raw drivers |
| `validation` | non-JavaFX interactive display and touch test of the raw drivers |
| `demo` | JavaFX counter demo |
| `dice-demo` | JavaFX dice demo |

The HAT is chosen when you build, not detected on the Pi. Build for the HAT that is attached.

| HAT | Build target (`<hat>`) | Tested on |
|---|---|---|
| 2.9" Touch e-Paper HAT (V2) — SSD1675A display, ICNT86X touch | `hat-2in9v2` | Raspberry Pi 500+ |
| 2.13" Touch e-Paper HAT (V4) — SSD1680 display, GT1151Q touch | `hat-2in13v4` | Raspberry Pi Zero 2 W |

A mismatch does not produce an error: the panel simply shows nothing sensible.

## Relationship to pux4j

`pux4j` is a standalone Java library; no native-image machinery lives there. This project builds
native images from its JVM artifacts, which it takes from the local Maven repository (`~/.m2`).
**Build and install `pux4j` first**, in its root:

```bash
mvn install -DskipTests
```

Nothing here builds or installs `pux4j`. After a change to `pux4j`, install it again before
rebuilding here.

## Prerequisites

| Requirement | Notes |
|---|---|
| GraalVM CE 25 | `JAVA_HOME` must point to the installation; `bin/native-image` must exist there |
| `aarch64-linux-gnu-gcc` | Cross-compiler; `pacman -S aarch64-linux-gnu-gcc` on Arch Linux |
| Podman | Mounts the `graalvm-pi-builder` image as the sysroot |
| QEMU aarch64 binfmt | For the CAP cache on the first build (`pacman -S qemu-user-static-binfmt`) |
| `~/.m2/settings.xml` | A GitHub Packages `read:packages` token with server id `github`, needed for `pi4j-ffm-metadata-bookworm-graal25`, also in a clean checkout |

The `~/.m2/settings.xml` entry:

```xml
<servers>
  <server>
    <id>github</id>
    <username>YOUR_GITHUB_USERNAME</username>
    <password>YOUR_READ_PACKAGES_PAT</password>
  </server>
</servers>
```

GraalVM CE 25 via SDKMAN:

```bash
sdk install java 25.3.4-graalce
sdk use java 25.3.4-graalce
```

The sysroot is the `graalvm-pi-builder` container image, a Debian bookworm arm64 sysroot with
GraalVM CE 25 and the aarch64 libraries. The image is arm64-only (no amd64 manifest), so
`--platform` is required on an x86_64 host. Pull it once:

```bash
podman pull --platform=linux/arm64 ghcr.io/lofthouse-dev/graalvm-pi-builder:bookworm-25.3.4.1
```

To move to a new image tag, change `IMAGE` in `scripts/deploy.sh` and `IMAGE_TAG` in
`scripts/generate-cap-cache.sh`. Source and rebuild instructions (a `workflow_dispatch` run of the
repository's build workflow) are in the
[graalvm-pi-builder](https://github.com/lofthouse-dev/graalvm-pi-builder) repository.

## Build and deploy

`scripts/deploy.sh` cross-compiles the apps you name for one HAT and copies them to a Pi. It never
builds or installs `pux4j`; it checks that the `pux4j` artifacts are in the local Maven repository
and says so if they are not.

```bash
sdk use java 25.3.4-graalce                       # JAVA_HOME must be GraalVM CE
scripts/deploy.sh <host> <hat> <app>...           # for example: scripts/deploy.sh mypi hat-2in9v2 smoke demo
scripts/deploy.sh <host> <hat> --all              # all four apps (the sysroot is mounted once)
```

| Option | Effect |
|---|---|
| `--user <user>` | ssh user, if different from what ssh would choose |
| `--dir <dir>` | directory on the Pi that will contain `pux4j-native` (default `applications`, so `~/applications/pux4j-native`) |
| `--pux4j-version <v>` | version of the `pux4j` artifacts to build against (default: `pux4j.version` in `pom.xml`) |
| `--repo <dir>` | local Maven repository (default `~/.m2/repository`) |
| `--settings <file>` | Maven settings file (default `~/.m2/settings.xml` when it exists) |
| `--skip-build` | deploy the images already in `target/` without building |
| `--dry-run` | print what would be done without building, connecting or changing anything |

`--help` prints the full text. On the Pi the script runs read-only checks (aarch64, SPI and I2C
devices, `tar`), then adds or replaces `lib/<app>` for the apps given and replaces `bin/`. Other
apps in `lib/` and the `logs/` directory are left alone, so you can deploy one app at a time. A
failed transfer leaves the previous installation working. Finally it runs `bin/install.sh`, which
links `pux4j-native` into `~/bin` (creating it if needed).

Each image takes one to two minutes to build. The build prints three warnings (the deprecated
`--no-fallback` option, the deprecated `FallbackThreshold`, and the host CPU falling back to
`-march=compatibility`); all are expected.

The CAP cache (aarch64 C type layout data) is generated on the first build and kept in
`target/cap-cache/`. Regenerate it (`mvn clean`) after a GraalVM upgrade or a Debian bookworm
glibc update.

## Running on the Pi

```bash
pux4j-native --list                  # the apps installed on this Pi
pux4j-native demo
pux4j-native validation --start-step 3
```

(If `~/bin` is not on the `PATH` yet, run `~/applications/pux4j-native/bin/pux4j-native`, or log
out and back in.)

- **App name** is the first argument that does not start with `-`. It is optional while only one
  app is installed. Exit codes: 0 success, 1 failure, 2 usage error (unknown or missing app).
- **Arguments:** `-D<property>=<value>` sets a system property for the app. For `smoke` and
  `validation`, everything else after the name goes to the test unchanged. The JavaFX apps
  (`demo`, `dice-demo`) ignore further arguments.
- **`DISPLAY`** defaults to `:0`. The JavaFX apps need a desktop session on the Pi even though
  nothing is shown on it, and `DISPLAY` must point at that session: `export DISPLAY=:1` first if
  the desktop is on `:1`. `smoke` and `validation` do not need one.
- **Logs:** output goes to the terminal and to `~/applications/pux4j-native/logs/<app>.log`,
  replaced on every run of that app. `--list` and `--help` write no log.

Nothing installed on the Pi carries a HAT name, and the installation does not record which HAT it
was built for. Keep track of which HAT you deployed to which Pi.

## One app per image

An image must not contain another app, the emulator (on a HAT build), or a second HAT driver.
Maven Enforcer rules in the app and HAT profiles of `pom.xml` fail the build if one reaches the
dependency tree, and a second check at the `prepare-package` phase fails it if the wrong jars are
in the module-path directory `target/deps-<hat>/`. `smoke` and `validation` additionally forbid
JavaFX and the launcher.

In the demo module-path directories, `javafx-base-<v>.jar` and `javafx-controls-<v>.jar` (about
300 bytes each) sit next to the `-linux-aarch64` platform jars. That is normal: OpenJFX publishes
manifest-only placeholder jars under the plain coordinates; they declare no module and cannot clash
with the platform jars.

## Maven profiles

The deploy script runs these for you. Two profile axes are always combined: one app, one target.

| Axis | Profile | Selects |
|---|---|---|
| App | `smoke` | `DisplaySmokeTest` |
| App | `validation` | `HardwareValidationTest` |
| App | `demo` | the generic launcher with `pux4j-demo` |
| App | `dice-demo` | the generic launcher with `pux4j-dice-demo` |
| Target | `hat-2in9v2` | 2.9" V2 HAT drivers, cross-compiled for aarch64 |
| Target | `hat-2in13v4` | 2.13" V4 HAT drivers, cross-compiled for aarch64 |

```bash
mvn package -P smoke,hat-2in9v2 -Dsysroot=<sysroot>     # normally done by scripts/deploy.sh
```

`-Dsysroot=` is the mounted sysroot image; `deploy.sh` sets it. The image is
`target/pux4j-<app>-<hat>`, for example `target/pux4j-demo-hat-2in9v2`. `-Dpux4j.version=<v>`
selects the `pux4j` artifacts.

### Build machine only: emulator builds

The emulator variants run on the build machine, not on a Pi; `deploy.sh` does not build them.

```bash
mvn package -P demo,x86_64 -DskipTests               # x86_64 native image, JavaFX emulator window
mvn package -P dice-demo,x86_64 -DskipTests
target/pux4j-demo-x86_64
target/pux4j-dice-demo-x86_64 --list

mvn package -P smoke-emulator,x86_64 -DskipTests     # smoke / validation against the emulator
mvn package -P validation-emulator,x86_64 -DskipTests
```

`run-smoke-emulator.sh` and `run-validation-emulator.sh` run the emulator variants.

## Tests

`scripts/deploy-test.sh` tests the deploy script and the Pi-side dispatcher without a Pi, podman or
network, using a fake `ssh` and tiny stand-in images. It does not build a native image.

```bash
scripts/deploy-test.sh
```

## Metadata

`reachability-metadata.json` is one shared file across every app and target profile — see
[`metadata-notes.md`](metadata-notes.md) for its history, how to add coverage for a new app or
profile, and a known gotcha with `scripts/generate-metadata.sh` on the currently installed GraalVM
version (read this before running it).

## Dependency notes

- **`pux4j` version** — `<pux4j.version>` in `pom.xml` is the default; override it with
  `-Dpux4j.version` or `deploy.sh --pux4j-version`.
- **`pi4j-ffm-metadata-bookworm-graal25`** — GraalVM reachability metadata for Pi4J's FFM
  downcalls. Version `4.0.2-0` is aligned with Pi4J 4.0.2. If `pux4j` upgrades Pi4J, update this
  version and publish a new artifact from
  [lofthouse-dev/pi4j-graalvm-metadata](https://github.com/lofthouse-dev/pi4j-graalvm-metadata).

## Future: native shared library

This project is expected to grow into a multi-module project when a native shared library is
added: `@CEntryPoint` wrappers over `EInkDisplayDriver`, `TouchDriver` and `RenderSession`,
compiled with `--shared` to produce a `.so` and a C header callable from C, Python and Rust.
