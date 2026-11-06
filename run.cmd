@echo off
rem Build (if needed) and launch micro-harness-manager on Windows (see run.sh).
setlocal
cd /d "%~dp0"
set "JAR=app\target\microhm-app-0.1.0-SNAPSHOT.jar"
call :stale
if errorlevel 1 (
  call mvn -q -pl app -am package -DskipTests || exit /b 1
)
java --enable-native-access=ALL-UNNAMED -jar "%JAR%" %*
exit /b %errorlevel%

:stale
rem Exit 1 when the jar is missing or any module's sources or POM are newer than it.
powershell -NoProfile -Command "$j = Get-Item -LiteralPath '%JAR%' -ErrorAction SilentlyContinue; if (-not $j) { exit 1 }; $newer = Get-ChildItem pom.xml, app, vt, pty, mux -Recurse -File | Where-Object { ($_.FullName -match '\\src\\' -or $_.Name -eq 'pom.xml') -and $_.LastWriteTime -gt $j.LastWriteTime } | Select-Object -First 1; if ($newer) { exit 1 } else { exit 0 }"
exit /b %errorlevel%
