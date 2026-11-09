@echo off
rem The session daemon's CLI on Windows (see microhm-mux). Keeps the caller's directory.
setlocal
set "ROOT=%~dp0"
set "JAR=%ROOT%app\target\microhm-app-0.1.0-SNAPSHOT.jar"
if not exist "%JAR%" (
  pushd "%ROOT%" && call mvn -q -pl app -am package -DskipTests & popd
)
java -XX:+UseSerialGC -Xms16m -Xmx2g -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 --enable-native-access=ALL-UNNAMED -cp "%JAR%" io.github.ghosthack.microhm.mux.Main %*
exit /b %errorlevel%
