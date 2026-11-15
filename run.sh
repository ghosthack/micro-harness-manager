#!/usr/bin/env bash
# Build (if needed) and launch micro-harness-manager.
set -euo pipefail

cd "$(dirname "$0")"

JAR=app/target/microhm-app-0.1.0-SNAPSHOT.jar

# Rebuild when any module's sources or POM are newer than the jar. The reactor build
# (-am) compiles vt, pty and mux alongside the app, so the shaded jar always carries the
# daemon matching this checkout — the client starts it from this same jar.
if [[ ! -f "$JAR" ]] || [[ -n "$(find app vt pty mux pom.xml \( -path '*/src/*' -o -name pom.xml \) \
        -newer "$JAR" -print -quit 2>/dev/null)" ]]; then
  mvn -q -pl app -am package -DskipTests
fi

# Launch from a copy named after its content. The session daemon starts from the jar the
# app runs and outlives it; a rebuild that overwrote that file under a running daemon would
# fail its next lazily loaded class (an exiting session then never leaves the list). Each
# build gets its own copy instead; old copies are removed, which a daemon still reading one
# survives (its open file stays readable).
RUN_DIR=app/target/run
mkdir -p "$RUN_DIR"
RUN_JAR="$RUN_DIR/microhm-app-$(shasum "$JAR" | cut -c1-12).jar"
[[ -f "$RUN_JAR" ]] || cp "$JAR" "$RUN_JAR"
ls -t "$RUN_DIR"/microhm-app-*.jar | tail -n +4 | while read -r old; do rm -f "$old"; done

# Same JVM options as the packaged app (see mux JvmOptions): a small, shrinking heap.
exec java -XX:+UseSerialGC -Xms16m -Xmx2g -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 --enable-native-access=ALL-UNNAMED \
  -Dapple.awt.application.name=micro-harness-manager \
  -jar "$RUN_JAR" "$@"
