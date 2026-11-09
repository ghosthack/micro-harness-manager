#!/usr/bin/env bash
# Smoke-test a jpackage app image: its files, the trimmed runtime's modules, the
# app's --package-smoke, and a real session through the packaged daemon launcher
# (daemon start, a PTY or ConPTY shell, typed input, capture, shutdown).
#
#   scripts/smoke-package.sh PATH/TO/APP-IMAGE
set -euo pipefail
IMAGE="${1:?pass the jpackage app-image path}"
APP_NAME="micro-harness-manager"
case "$(uname -s)" in
    Darwin) BIN="$IMAGE/Contents/MacOS"; APP="$IMAGE/Contents/app"; HOME_DIR="$IMAGE/Contents/runtime/Contents/Home"; EXT= ;;
    Linux) BIN="$IMAGE/bin"; APP="$IMAGE/lib/app"; HOME_DIR="$IMAGE/lib/runtime"; EXT= ;;
    MINGW*|MSYS*|CYGWIN*) BIN="$IMAGE"; APP="$IMAGE/app"; HOME_DIR="$IMAGE/runtime"; EXT=.exe ;;
    *) echo "unsupported host" >&2; exit 2 ;;
esac

for path in "$BIN/$APP_NAME$EXT" "$BIN/microhm-mux$EXT" "$HOME_DIR/bin/java$EXT" \
            "$APP/LICENSE" "$APP/THIRD-PARTY.md" "$APP/THIRD-PARTY-LICENSES/README.md"; do
    [[ -f "$path" ]] || { echo "missing from the package: $path" >&2; exit 1; }
done

MODULES="$(sed -n 's/^MODULES="\(.*\)"$/\1/p' "$HOME_DIR/release" | tr ' ' '\n')"
for required in java.desktop java.management jdk.management java.net.http java.sql jdk.httpserver; do
    grep -Fxq "$required" <<< "$MODULES" || { echo "runtime lacks module: $required" >&2; exit 1; }
done

# The app launcher names its AOT cache under the user's home (the app makes it on the
# first launch); the launcher must expand the home variable, or the cache is never used.
SMOKE_OUTPUT="$("$BIN/$APP_NAME$EXT" --package-smoke)"
printf '%s\n' "$SMOKE_OUTPUT"
AOT_PATH="$(sed -n 's/^aot cache: //p' <<< "$SMOKE_OUTPUT")"
if [[ -z "$AOT_PATH" || "$AOT_PATH" == "none" ]]; then
    echo "warning: the app launcher's AOT cache path did not expand; the app will start without a cache" >&2
fi

MUX="$BIN/microhm-mux$EXT"
SCRATCH="$(mktemp -d)"
export MICROHM_MUX_HOME="$SCRATCH/mux"
unset MICROHM_MUX_LAUNCHER
cleanup() {
    "$MUX" shutdown >/dev/null 2>&1 || true
    # a stopping daemon still holds its log open for a moment, and Windows refuses
    # to delete an open file
    for _ in $(seq 1 20); do
        rm -rf "$SCRATCH" 2>/dev/null && return 0
        sleep 0.5
    done
    echo "note: could not remove $SCRATCH" >&2
    return 0
}
trap cleanup EXIT

"$MUX" version
"$MUX" new pkg-smoke --dir "$SCRATCH" --size 100x30
for _ in $(seq 1 40); do
    "$MUX" capture pkg-smoke | grep -q '[$>#%] *$' && break
    sleep 0.5
done
"$MUX" send-keys pkg-smoke "echo package-$((6 * 7))"
for _ in $(seq 1 40); do
    if "$MUX" capture pkg-smoke | grep -q 'package-42'; then
        echo "daemon session: OK"
        exit 0
    fi
    sleep 0.5
done
echo "the packaged daemon's session never echoed the typed command:" >&2
"$MUX" capture pkg-smoke >&2 || true
exit 1
