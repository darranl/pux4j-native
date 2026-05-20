#!/usr/bin/env bash
# Regenerate reachability metadata by running pux4j-demo with the GraalVM tracing agent.
#
# The tracing agent observes all reflection, resource, and JNI accesses at runtime
# and writes configuration files used by native-image at build time. Run this whenever
# the demo app acquires new reflection or resource access patterns (new FXML elements,
# new service providers, new resource paths, etc.).
#
# After the app exits the agent output is converted to the consolidated
# reachability-metadata.json format and written to the native-image resources directory.
# The augment/ subdirectory (shader wildcards, service loader registrations) is left
# untouched and continues to be picked up automatically by native-image.
#
# Usage:
#   ./generate-metadata.sh [--force-prepare]
#
#   --force-prepare   Force re-run of 'mvn prepare-package' even if target/deps/ exists
#
# Prerequisites:
#   JAVA_HOME must point to GraalVM CE (sdk use java 25.0.2-graalce).
#   pux4j-ui must be installed to ~/.m2: cd pux4j-ui && mvn install -DskipTests
#
# What to exercise in the app:
#   - Click the Increment button several times
#   - Click the Decrement button
#   - Move the mouse around the window
#   - Right-click anywhere and use the context menu
#   Then exit (right-click → Exit, or Ctrl+C in the terminal).
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

METADATA_DIR="$PROJECT_DIR/src/main/resources/META-INF/native-image"
DEPS_DIR="$PROJECT_DIR/target/deps"
AGENT_OUTPUT_DIR="$PROJECT_DIR/target/generated-metadata"
OUTPUT_FILE="$METADATA_DIR/reachability-metadata.json"

FORCE_PREPARE=false
for arg in "$@"; do
    case "$arg" in
        --force-prepare) FORCE_PREPARE=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "ERROR: Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# --- Verify GraalVM ---
if [[ -z "${JAVA_HOME:-}" ]]; then
    echo "ERROR: JAVA_HOME is not set." >&2
    echo "  Use: sdk use java 25.0.2-graalce" >&2
    exit 1
fi
if [[ ! -x "$JAVA_HOME/bin/native-image" ]]; then
    echo "ERROR: JAVA_HOME does not contain native-image: $JAVA_HOME" >&2
    echo "  JAVA_HOME must point to GraalVM CE, not a standard JDK." >&2
    echo "  Use: sdk use java 25.0.2-graalce" >&2
    exit 1
fi
if [[ ! -f "$JAVA_HOME/lib/native-image-agent.jar" ]] && \
   ! ls "$JAVA_HOME"/lib/svm/builder/native-image-agent*.jar &>/dev/null 2>&1; then
    # Also check via java -agentlib - some distributions bundle it differently
    :
fi

# --- Prepare deps ---
if [[ "$FORCE_PREPARE" == "true" ]] || [[ ! -d "$DEPS_DIR" ]] || \
   [[ -z "$(ls -A "$DEPS_DIR" 2>/dev/null)" ]]; then
    echo "==> Preparing demo dependencies (mvn prepare-package)..."
    (cd "$PROJECT_DIR" && mvn -P demo,x86_64 -DskipTests prepare-package -q)
else
    echo "==> Using existing deps in $DEPS_DIR (pass --force-prepare to refresh)"
fi

DEMO_JAR=$(ls "$DEPS_DIR"/pux4j-demo-*.jar 2>/dev/null | head -1)
if [[ -z "$DEMO_JAR" ]]; then
    echo "ERROR: pux4j-demo JAR not found in $DEPS_DIR" >&2
    echo "  Run: mvn -P demo,x86_64 -DskipTests prepare-package" >&2
    exit 1
fi

MODULE_PATH=$(ls "$DEPS_DIR"/*.jar | tr '\n' ':')
MODULE_PATH="${MODULE_PATH%:}"

# --- Run tracing agent ---
mkdir -p "$AGENT_OUTPUT_DIR"

echo ""
echo "==> Starting pux4j-demo with GraalVM tracing agent..."
echo "    Exercise all UI features, then exit the app to complete tracing."
echo ""
echo "    What to do:"
echo "      - Click Increment several times"
echo "      - Click Decrement"
echo "      - Move the mouse around the window"
echo "      - Right-click anywhere (opens context menu)"
echo "      - Right-click → Exit"
echo ""

"$JAVA_HOME/bin/java" \
    --module-path "$MODULE_PATH" \
    --enable-native-access=javafx.graphics \
    -agentlib:native-image-agent=config-output-dir="$AGENT_OUTPUT_DIR" \
    -Dpux4j.display.scale=3.0 \
    -Dpux4j.display.bezel=true \
    -m dev.pux4j.ui.demo/dev.pux4j.ui.demo.DemoApp

echo ""
echo "==> Tracing complete. Converting agent output to reachability-metadata.json..."

jbang "$SCRIPT_DIR/MergeMetadata.java" \
    --generated "$AGENT_OUTPUT_DIR" \
    --output "$OUTPUT_FILE"

echo ""
echo "==> Done. Updated: $OUTPUT_FILE"
echo "    augment/resource-config.json: unchanged (picked up separately by native-image)"
echo ""
echo "    Review the diff before committing:"
echo "      git diff src/main/resources/META-INF/native-image/reachability-metadata.json"
