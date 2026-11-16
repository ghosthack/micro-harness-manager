#!/bin/sh
# End-to-end tests for the phone page (app/src/test/e2e/phone.test.mjs): builds the app
# jar, installs the pinned playwright-core and its headless Chromium on first use, then
# runs the tests with node --test. They start the phone page on its own (PhoneMain) with a
# scratch home and daemon, so your own sessions are never touched.
# Needs node 20+, JDK 26 and Maven; Unix only (the shell under test is /bin/sh).
# Extra args go to node --test (e.g. --test-name-pattern=close).
# MHM_KEEP_WORK=1 keeps the scratch folder; MHM_CHROMIUM picks another Chromium.
set -e
cd "$(dirname "$0")/.."
REPO=$(pwd)
mvn -q -pl app -am package -DskipTests
# The scratch daemon runs from this jar; a copy, so a rebuild mid-run cannot pull it away.
mkdir -p app/target/e2e
cp app/target/microhm-app-0.1.0-SNAPSHOT.jar app/target/e2e/microhm-app.jar
export MHM_JAR="$REPO/app/target/e2e/microhm-app.jar"
export MHM_WEB_DIR="$REPO/app/src/main/resources/web"
cd app/src/test/e2e
[ -d node_modules/playwright-core ] || npm ci --no-audit --no-fund
[ -n "$MHM_CHROMIUM" ] || npx --no-install playwright-core install chromium-headless-shell >/dev/null
exec node --test --test-concurrency=1 "$@" phone.test.mjs
