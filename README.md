# pux4j-native

GraalVM native image builds for [pux4j](https://github.com/lofthouse-dev/pux4j-ui).

Produces aarch64 native executables for the pux4j smoke test and hardware validation test,
cross-compiled from x86_64 using the
[graalvm-pi-builder](https://github.com/lofthouse-dev/graalvm-pi-builder) container image.
The resulting binaries run on Raspberry Pi hardware without a JVM.

## Relationship to pux4j-ui

`pux4j-ui` is a standalone Java library — no native image machinery lives there. This repo
depends on `pux4j-ui` JVM artifacts (published to `~/.m2` via `mvn install`) and builds
native images from them. Keep the two repos decoupled: changes to `pux4j-ui` require a fresh
`mvn install` on that project before rebuilding here.

## Prerequisites

| Requirement | Notes |
|---|---|
| GraalVM CE 25 | Set `JAVA_HOME` to the GraalVM installation; `native-image` must be on `PATH` |
| `aarch64-linux-gnu-gcc` | Cross-compiler; `pacman -S aarch64-linux-gnu-gcc` on Arch Linux |
| Podman | For mounting the `graalvm-pi-builder` image as sysroot |
| QEMU aarch64 binfmt | For inline CAP cache generation on first build (`pacman -S qemu-user-static-binfmt`) |
| `~/.m2/settings.xml` | GitHub Packages `read:packages` PAT for `pi4j-ffm-metadata-bookworm-graal25` |

### `~/.m2/settings.xml` snippet

```xml
<servers>
  <server>
    <id>github</id>
    <username>YOUR_GITHUB_USERNAME</username>
    <password>YOUR_READ_PACKAGES_PAT</password>
  </server>
</servers>
```

### GraalVM CE 25 via SDKMAN

```bash
sdk install java 25.0.2-graalce
sdk use java 25.0.2-graalce
```

## Cross-compilation prerequisites

Cross-compilation uses the `graalvm-pi-builder` container image, which provides a Debian
bookworm arm64 sysroot with GraalVM CE 25 and the aarch64 cross-compiler.

**Container image:** `ghcr.io/lofthouse-dev/graalvm-pi-builder:bookworm-graal25`

Pull it:
```bash
podman pull ghcr.io/lofthouse-dev/graalvm-pi-builder:bookworm-graal25
```

**If you need to rebuild the image** (e.g. after a GraalVM version update or base OS change):
- Source repository: `https://github.com/lofthouse-dev/graalvm-pi-builder`
- Trigger a rebuild via GitHub Actions → **`workflow_dispatch`** on the repository's
  build workflow. No local rebuild step is required.
- After publishing, update the image tag in `pux4j-native/pom.xml` (`<graalvm.pi.builder.image>`
  property or equivalent) to the new tag.
- **Tip:** Pin the image to a digest (`@sha256:...`) for reproducible builds once the image
  is stable.

**Current GraalVM version:** CE 25.0.2 (as of the bookworm-graal25 tag).

## Build profiles

Two orthogonal profile axes must always be combined:

| Axis | Profile | Selects |
|---|---|---|
| App | `smoke` | `DisplaySmokeTest` (7-step display smoke test) |
| App | `validation` | `HardwareValidationTest` (10-step interactive validation) |
| Target | `hat-2in9v2` | Pi 500+ — SSD1675A display + ICNT86X touch |
| Target | `hat-2in13v4` | LittleRaspberry — SSD1680 display + GT1151Q touch |

```bash
mvn package -P smoke,hat-2in9v2          # smoke test for Pi 500+
mvn package -P validation,hat-2in9v2     # validation test for Pi 500+
mvn package -P smoke,hat-2in13v4         # smoke test for LittleRaspberry
mvn package -P validation,hat-2in13v4   # validation test for LittleRaspberry
```

Output: `target/<binary-name>` (e.g. `target/pux4j-smoke-test-hat-2in9v2`)

The `-Dsysroot=` property is set automatically by `deploy-native.sh` from the
mounted `graalvm-pi-builder` container image. Do not set it manually unless you
know what you are doing.

## Deploying

Use `scripts/deploy-native.sh` from the parent `waveshare-integration-project` repo:

```bash
# From waveshare-integration-project/
scripts/deploy-native.sh pi500 smoke hat-2in9v2
scripts/deploy-native.sh --skip-install littleraspberry validation hat-2in13v4
```

The script:
1. Runs `mvn install -DskipTests` on `pux4j-ui` (populates `~/.m2`)
2. Enters `podman unshare` and mounts the `graalvm-pi-builder` image as the aarch64 sysroot
3. Cross-compiles the native binary (`mvn package -P <app>,<target> -Dsysroot=...`)
4. `scp`s the binary to `~/bin/<binary-name>` on the target Pi

The GraalVM CAP cache (aarch64 C type layout data) is generated inline by `native-image`
on the first build and cached in `target/cap-cache/`. Regenerate after: `mvn clean`,
a GraalVM CE upgrade, or a Debian bookworm glibc update.

## Running on the Pi

After deployment the binary is in `~/bin/`. It accepts the same arguments as the JVM launcher:

```bash
# Smoke test — pass driver name as first argument
pux4j-smoke-test-hat-2in9v2 ssd1675a
pux4j-smoke-test-hat-2in13v4 ssd1680

# Validation test — interactive 10-step test
pux4j-validation-test-hat-2in9v2
```

## Dependency notes

- **`pux4j-ui` version** — set `<pux4j.version>` in `pom.xml` to match the installed
  `pux4j-ui` version. Currently `0.1.0-SNAPSHOT`.
- **`pi4j-ffm-metadata-bookworm-graal25`** — GraalVM reachability metadata for Pi4J's
  FFM downcalls. Version `4.0.1-0` is aligned with `pi4j 4.0.1`. If `pux4j-ui` upgrades
  Pi4J, update this version and publish a new artifact from
  [lofthouse-dev/pi4j-graalvm-metadata](https://github.com/lofthouse-dev/pi4j-graalvm-metadata).
- **`graalvm-pi-builder`** — source at
  [lofthouse-dev/graalvm-pi-builder](https://github.com/lofthouse-dev/graalvm-pi-builder).
  Pull the latest image or build locally with `make build-dev`.

## Future: native shared library (Phase 8)

This repo will expand to a multi-module project when the native shared library is added:
`@CEntryPoint` wrappers over `EInkDisplayDriver`, `TouchDriver`, and `RenderSession`,
compiled with `--shared` to produce a `.so` + C header callable from C, Python, and Rust.
