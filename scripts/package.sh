#!/usr/bin/env bash
# Build a self-contained micro-harness-manager app image and native installer for
# the current OS and architecture. Run from any directory:
#
#   scripts/package.sh [all|app-image|installer] [X.Y.Z]
#
# The release workflow supplies X.Y.Z from its vX.Y.Z tag; local builds default to
# 1.0.0. Signing is optional: on macOS set MACOS_SIGNING_IDENTITY (and MACOS_KEYCHAIN
# to use a specific keychain). Windows signing happens in the release workflow,
# between the app-image and installer modes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-all}"
VERSION="${2:-${APP_VERSION:-1.0.0}}"
APP_NAME="micro-harness-manager"
APP_ID="io.github.ghosthack.microhm"
# The name people see in the OS: the macOS bundle name (menu bar, Finder; at most 16
# characters) and the Windows Start-menu folder. Launchers, paths, package ids and
# artifacts keep APP_NAME.
DISPLAY_NAME="Microhm"
MAC_PACKAGE_NAME="$DISPLAY_NAME"
MAIN_CLASS="io.github.ghosthack.microhm.app.MicroHarnessManagerApp"
MUX_CLASS="io.github.ghosthack.microhm.mux.Main"
MUX_LAUNCHER="microhm-mux"
RUNTIME_MODULES="java.desktop,java.net.http,java.logging,java.sql,jdk.httpserver,jdk.unsupported,jdk.charsets"
# Windows Installer relates every release of the app through this identity. Never
# change it, or upgrades install side by side instead of replacing the old version.
WINDOWS_UPGRADE_UUID="c724e8e7-827f-438a-9bf2-464b0afa89d2"
VENDOR="ghosthack contributors"
DESCRIPTION="A desktop manager for coding-agent and shell sessions"
COPYRIGHT="Copyright © 2026 ghosthack contributors"
INPUT_DIR="$ROOT/target/jpackage-input"
PACKAGE_ROOT="$ROOT/target/jpackage"
IMAGE_DIR="$PACKAGE_ROOT/images"
RELEASE_DIR="$PACKAGE_ROOT/release"

if [[ "$MODE" != "all" && "$MODE" != "app-image" && "$MODE" != "installer" ]]; then
    echo "error: mode must be 'all', 'app-image', or 'installer'" >&2
    exit 2
fi
# jpackage (macOS above all) rejects a leading 0, so releases start at 1.0.0
if [[ ! "$VERSION" =~ ^[1-9][0-9]*\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: the release version must be numeric X.Y.Z with X >= 1 (got '$VERSION')" >&2
    exit 2
fi

case "$(uname -s)" in
    Darwin)
        PLATFORM="macos"
        [[ "$(uname -m)" == "arm64" ]] || { echo "error: macOS packages are arm64 only" >&2; exit 2; }
        NATIVE_TYPE="dmg"
        IMAGE_PATH="$IMAGE_DIR/$APP_NAME.app"
        ASSET_PLATFORM="macos-arm64"
        ;;
    Linux)
        PLATFORM="linux"
        [[ "$(uname -m)" == "x86_64" ]] || { echo "error: Linux packages are x64 only" >&2; exit 2; }
        NATIVE_TYPE="deb"
        IMAGE_PATH="$IMAGE_DIR/$APP_NAME"
        ASSET_PLATFORM="linux-x64"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        PLATFORM="windows"
        NATIVE_TYPE="exe"
        IMAGE_PATH="$IMAGE_DIR/$APP_NAME"
        ASSET_PLATFORM="windows-x64"
        ;;
    *)
        echo "error: unsupported packaging host: $(uname -s)" >&2
        exit 2
        ;;
esac

for input in LICENSE THIRD-PARTY.md licenses; do
    [[ -e "$ROOT/$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 1; }
done

shopt -s nullglob

# Apple's notary service scans native binaries inside JARs (FlatLaf ships dylibs), and
# jpackage's signing can't reach into a JAR, so sign them before the image is built.
sign_macos_jar_natives() {
    local jar_file="$1" identity="$2"
    local work entry
    local -a natives=()
    while IFS= read -r entry; do
        case "$entry" in
            /*|../*|*/../*|*/..) echo "error: unsafe JAR entry: $entry" >&2; return 1 ;;
            *.dylib|*.jnilib) natives+=("$entry") ;;
        esac
    done < <(jar tf "$jar_file")
    if (( ${#natives[@]} == 0 )); then
        echo "error: no macOS native libraries found in $jar_file" >&2
        return 1
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/microhm-native-sign.XXXXXX")"
    (
        cd "$work"
        jar xf "$jar_file" "${natives[@]}"
        for entry in "${natives[@]}"; do
            if [[ -n "${MACOS_KEYCHAIN:-}" ]]; then
                codesign --force --sign "$identity" --timestamp --options runtime \
                    --keychain "$MACOS_KEYCHAIN" "$entry"
            else
                codesign --force --sign "$identity" --timestamp --options runtime "$entry"
            fi
            codesign --verify --strict "$entry"
        done
        zip -q "$jar_file" "${natives[@]}"
    ) || { rm -rf "$work"; return 1; }
    rm -rf "$work"
    echo "==> Signed ${#natives[@]} native libraries inside $(basename "$jar_file")"
}

if [[ "$MODE" != "installer" ]]; then
    echo "==> Building micro-harness-manager $VERSION"
    # clean wipes target/, so the staging directories are made after the build
    (cd "$ROOT" && mvn -B -q -DskipTests -Drevision="$VERSION" clean package)
    rm -rf "$INPUT_DIR" "$PACKAGE_ROOT"
    mkdir -p "$INPUT_DIR" "$IMAGE_DIR" "$RELEASE_DIR"
    MAIN_JAR="microhm-app-$VERSION.jar"
    cp "$ROOT/app/target/$MAIN_JAR" "$INPUT_DIR/"
    cp "$ROOT/LICENSE" "$INPUT_DIR/LICENSE"
    cp "$ROOT/THIRD-PARTY.md" "$INPUT_DIR/THIRD-PARTY.md"
    cp -R "$ROOT/licenses" "$INPUT_DIR/THIRD-PARTY-LICENSES"

    if [[ "$PLATFORM" == "macos" && -n "${MACOS_SIGNING_IDENTITY:-}" ]]; then
        sign_macos_jar_natives "$INPUT_DIR/$MAIN_JAR" "$MACOS_SIGNING_IDENTITY"
    fi

    case "$PLATFORM" in
        macos)   ICON="$ROOT/packaging/icons/micro-harness-manager.icns" ;;
        windows) ICON="$ROOT/packaging/icons/micro-harness-manager.ico" ;;
        linux)   ICON="$ROOT/packaging/icons/micro-harness-manager.png" ;;
    esac

    # The daemon CLI and session daemon: ServerLauncher looks for this launcher
    # next to the app's own, so the GUI starts the daemon through it.
    MUX_PROPERTIES="$PACKAGE_ROOT/$MUX_LAUNCHER-launcher.properties"
    printf 'main-jar=%s\nmain-class=%s\nwin-console=true\njava-options=--enable-native-access=ALL-UNNAMED\n' \
        "$MAIN_JAR" "$MUX_CLASS" > "$MUX_PROPERTIES"

    echo "==> Creating the self-contained application image"
    IMAGE_ARGS=(
        --type app-image
        --dest "$IMAGE_DIR"
        --name "$APP_NAME"
        --app-version "$VERSION"
        --vendor "$VENDOR"
        --description "$DESCRIPTION"
        --copyright "$COPYRIGHT"
        --input "$INPUT_DIR"
        --main-jar "$MAIN_JAR"
        --main-class "$MAIN_CLASS"
        --add-modules "$RUNTIME_MODULES"
        # Keep bin/java: on macOS every session starts through a small JVM
        # (ControllingTerminal) that takes the controlling terminal, run from
        # <java.home>/bin/java. jpackage strips native commands by default.
        --jlink-options "--strip-debug --no-man-pages --no-header-files"
        --java-options "--enable-native-access=ALL-UNNAMED"
        --add-launcher "$MUX_LAUNCHER=$MUX_PROPERTIES"
        --icon "$ICON"
    )
    if [[ "$PLATFORM" == "macos" ]]; then
        IMAGE_ARGS+=(
            --mac-package-identifier "$APP_ID"
            --mac-package-name "$MAC_PACKAGE_NAME"
            --mac-app-category developer-tools
        )
    fi
    jpackage "${IMAGE_ARGS[@]}"

    if [[ "$PLATFORM" == "linux" ]]; then
        # A jpackage launcher started by another inherits its re-execution marker;
        # clear it so the daemon launcher's arguments stay program arguments.
        cp "$IMAGE_PATH/bin/$MUX_LAUNCHER" "$IMAGE_PATH/bin/.$MUX_LAUNCHER-native"
        cp "$IMAGE_PATH/lib/app/$MUX_LAUNCHER.cfg" "$IMAGE_PATH/lib/app/.$MUX_LAUNCHER-native.cfg"
        cat > "$IMAGE_PATH/bin/$MUX_LAUNCHER" <<EOF
#!/bin/sh
unset _JPACKAGE_LAUNCHER
exec "\$(dirname "\$0")/.$MUX_LAUNCHER-native" "\$@"
EOF
        chmod +x "$IMAGE_PATH/bin/$MUX_LAUNCHER"
    fi

    if [[ "$PLATFORM" == "macos" && -n "${MACOS_SIGNING_IDENTITY:-}" ]]; then
        echo "==> Signing the macOS application image"
        SIGN_ARGS=(
            --type app-image
            --app-image "$IMAGE_PATH"
            --mac-sign
            --mac-app-image-sign-identity "$MACOS_SIGNING_IDENTITY"
        )
        if [[ -n "${MACOS_KEYCHAIN:-}" ]]; then
            SIGN_ARGS+=(--mac-signing-keychain "$MACOS_KEYCHAIN")
        fi
        jpackage "${SIGN_ARGS[@]}"
        codesign --verify --deep --strict --verbose=2 "$IMAGE_PATH"
    fi

    if [[ "${SKIP_PACKAGE_SMOKE:-false}" != "true" ]]; then
        echo "==> Smoke-testing the packaged runtime, daemon launcher and PTYs"
        bash "$ROOT/scripts/smoke-package.sh" "$IMAGE_PATH"
    fi

    if [[ "$MODE" == "app-image" ]]; then
        echo "application image: $IMAGE_PATH"
        exit 0
    fi
else
    [[ -d "$IMAGE_PATH" ]] || {
        echo "error: application image does not exist: $IMAGE_PATH" >&2
        echo "Run app-image mode before installer mode." >&2
        exit 1
    }
    rm -rf "$RELEASE_DIR" "$PACKAGE_ROOT/license-artifact"
    mkdir -p "$RELEASE_DIR"
fi

echo "==> Creating the $NATIVE_TYPE installer"
INSTALLER_ARGS=(
    --type "$NATIVE_TYPE"
    --dest "$RELEASE_DIR"
    --name "$APP_NAME"
    --app-version "$VERSION"
    --vendor "$VENDOR"
    --description "$DESCRIPTION"
    --copyright "$COPYRIGHT"
    --license-file "$ROOT/LICENSE"
    --app-image "$IMAGE_PATH"
)
case "$PLATFORM" in
    macos)
        INSTALLER_ARGS+=(--mac-package-identifier "$APP_ID" --mac-package-name "$MAC_PACKAGE_NAME")
        ;;
    windows)
        INSTALLER_ARGS+=(
            --win-upgrade-uuid "$WINDOWS_UPGRADE_UUID"
            --win-dir-chooser
            --win-menu
            --win-menu-group "$DISPLAY_NAME"
            --win-shortcut
        )
        ;;
    linux)
        INSTALLER_ARGS+=(
            --linux-package-name "$APP_NAME"
            --linux-deb-maintainer "$VENDOR"
            --linux-app-category Development
            --linux-menu-group Development
            --linux-shortcut
        )
        ;;
esac
jpackage "${INSTALLER_ARGS[@]}"

INSTALLERS=("$RELEASE_DIR"/*."$NATIVE_TYPE")
if (( ${#INSTALLERS[@]} != 1 )); then
    echo "error: expected exactly one .$NATIVE_TYPE installer in $RELEASE_DIR" >&2
    exit 1
fi
INSTALLER="$RELEASE_DIR/$APP_NAME-$VERSION-$ASSET_PLATFORM.$NATIVE_TYPE"
mv "${INSTALLERS[0]}" "$INSTALLER"

case "$PLATFORM" in
    windows)
        (cd "$IMAGE_DIR" && jar --create --no-manifest \
            --file "$RELEASE_DIR/$APP_NAME-$VERSION-$ASSET_PLATFORM.zip" "$APP_NAME")
        ;;
    linux)
        tar -C "$IMAGE_DIR" -czf "$RELEASE_DIR/$APP_NAME-$VERSION-$ASSET_PLATFORM.tar.gz" "$APP_NAME"
        ;;
esac

# Every license that ships inside the package, the bundled Java runtime's included,
# as one archive beside the installers.
case "$PLATFORM" in
    macos)   RUNTIME_LEGAL="$IMAGE_PATH/Contents/runtime/Contents/Home/legal" ;;
    windows) RUNTIME_LEGAL="$IMAGE_PATH/runtime/legal" ;;
    linux)   RUNTIME_LEGAL="$IMAGE_PATH/lib/runtime/legal" ;;
esac
[[ -d "$RUNTIME_LEGAL" ]] || { echo "error: runtime legal directory missing: $RUNTIME_LEGAL" >&2; exit 1; }
LICENSE_NAME="$APP_NAME-$VERSION-$ASSET_PLATFORM-licenses"
LICENSE_ROOT="$PACKAGE_ROOT/license-artifact"
rm -rf "$LICENSE_ROOT"
mkdir -p "$LICENSE_ROOT/$LICENSE_NAME/runtime"
cp "$ROOT/LICENSE" "$ROOT/THIRD-PARTY.md" "$LICENSE_ROOT/$LICENSE_NAME/"
cp -R "$ROOT/licenses/." "$LICENSE_ROOT/$LICENSE_NAME/"
cp -RL "$RUNTIME_LEGAL/." "$LICENSE_ROOT/$LICENSE_NAME/runtime/"
jar --create --no-manifest --file "$RELEASE_DIR/$LICENSE_NAME.zip" -C "$LICENSE_ROOT" "$LICENSE_NAME"

echo "release artifacts:"
find "$RELEASE_DIR" -maxdepth 1 -type f -print
