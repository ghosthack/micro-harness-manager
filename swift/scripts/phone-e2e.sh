#!/bin/sh
# The phone page's end-to-end tests (app/src/test/e2e/phone.test.mjs, unmodified) against
# the Swift servers. Builds microhm-host and microhm-mux, then runs the tests with a `java`
# shim first on PATH that turns the test's two Java invocations into the Swift ones:
#   java … io.github.ghosthack.microhm.app.phone.PhoneMain --port= --token= --registry= --mux-home=
#       -> microhm-host --phone-only (same options)
#   java … io.github.ghosthack.microhm.mux.Main shutdown --home DIR
#       -> microhm-mux shutdown --home DIR
# The tests start the page with a scratch home and daemon, so your own sessions are never
# touched. Needs node 20+ and the e2e folder's node_modules (playwright-core).
# Extra args go to node --test (e.g. --test-name-pattern=close).
# MHM_KEEP_WORK=1 keeps the scratch folder; MHM_CHROMIUM picks another Chromium;
# MHM_WEB_DIR serves the page from a folder on disk (default: the bundled Resources/web).
set -e
cd "$(dirname "$0")/.."
SWIFT=$(pwd)
REPO=$(cd .. && pwd)
SCRATCH=${MHM_SCRATCH_PATH:-.build-svc}
swift build --scratch-path "$SCRATCH" --product microhm-mux >/dev/null
swift build --scratch-path "$SCRATCH" --product microhm-host >/dev/null
BIN=$(swift build --scratch-path "$SCRATCH" --show-bin-path)

SHIM=$(mktemp -d "${TMPDIR:-/tmp}/mhm-e2e-shim-XXXXXX")
trap 'rm -rf "$SHIM"' EXIT
cat > "$SHIM/java" <<SHIM
#!/bin/sh
# Stand-in for java in phone.test.mjs: maps its main classes onto the Swift executables.
main=""
for arg in "\$@"; do
  case "\$arg" in
    io.github.ghosthack.microhm.app.phone.PhoneMain) main=phone ;;
    io.github.ghosthack.microhm.mux.Main) main=mux ;;
  esac
done
case "\$main" in
  phone)
    skip=1
    for arg in "\$@"; do
      if [ \$skip = 1 ]; then
        [ "\$arg" = io.github.ghosthack.microhm.app.phone.PhoneMain ] && skip=0
        shift; continue
      fi
      break
    done
    exec "$BIN/microhm-host" --phone-only "\$@" ;;
  mux)
    while [ "\$1" != io.github.ghosthack.microhm.mux.Main ]; do shift; done
    shift
    exec "$BIN/microhm-mux" "\$@" ;;
  *) echo "java shim: unexpected invocation: \$*" >&2; exit 2 ;;
esac
SHIM
chmod +x "$SHIM/java"

export PATH="$SHIM:$PATH"
# the test only checks that this is set; the shim ignores the jar
export MHM_JAR="$BIN/microhm-host"
cd "$REPO/app/src/test/e2e"
[ -d node_modules/playwright-core ] || npm ci --no-audit --no-fund
[ -n "$MHM_CHROMIUM" ] || npx --no-install playwright-core install chromium-headless-shell >/dev/null
node --test --test-concurrency=1 "$@" phone.test.mjs
