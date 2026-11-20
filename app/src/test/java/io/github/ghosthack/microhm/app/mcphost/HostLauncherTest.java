package io.github.ghosthack.microhm.app.mcphost;

import io.github.ghosthack.microhm.app.MicroHarnessManagerApp;
import org.junit.jupiter.api.Test;

import java.io.File;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class HostLauncherTest {

    @Test
    void aPackagedAppStartsTheHostThroughItsOwnLauncher() {
        // Paths as the platform spells them (backslashes on Windows), as the app passes them.
        Path registry = Path.of("/home/u/.micro-harness-manager/sessions.json");
        Path muxHome = Path.of("/home/u/.micro-harness-manager/mux");
        List<String> command = HostLauncher.command(
                HostLauncher.launcher("/Applications/mhm.app/Contents/MacOS/mhm", "/jdk", "x.jar"),
                registry, muxHome, McpHost.FLAG);
        assertEquals(List.of("/Applications/mhm.app/Contents/MacOS/mhm", McpHost.FLAG,
                "--registry=" + registry, "--mux-home=" + muxHome), command);
    }

    @Test
    void aJvmLaunchKeepsTheClasspathAbsoluteAndPassesTheStateLocations() {
        Path registry = Path.of("/tmp/r/sessions.json");
        Path muxHome = Path.of("/tmp/m");
        List<String> command = HostLauncher.command(
                HostLauncher.launcher(null, "/jdk", "app.jar" + File.pathSeparator + "/abs/lib.jar"),
                registry, muxHome, McpHost.FLAG);
        assertTrue(command.getFirst().startsWith(Path.of("/jdk", "bin").toString()), command.toString());
        assertTrue(command.contains("--enable-native-access=ALL-UNNAMED"));
        assertTrue(command.containsAll(io.github.ghosthack.microhm.mux.client.JvmOptions.RESIDENT), command.toString());
        assertTrue(command.contains("--registry=" + registry), command.toString());
        assertTrue(command.contains("--mux-home=" + muxHome), command.toString());
        String classPath = command.get(command.indexOf("-cp") + 1);
        for (String entry : classPath.split(File.pathSeparator)) {
            assertTrue(Path.of(entry).isAbsolute(), entry);
        }
        assertEquals(List.of(MicroHarnessManagerApp.class.getName(), McpHost.FLAG),
                command.subList(command.size() - 4, command.size() - 2));
    }

    @Test
    void openingTheAppPassesTheStateButNoMode() {
        Path registry = Path.of("/tmp/r/sessions.json");
        Path muxHome = Path.of("/tmp/m");
        List<String> command = HostLauncher.command(List.of("/opt/mhm/bin/mhm"), registry, muxHome);
        assertEquals(List.of("/opt/mhm/bin/mhm", "--registry=" + registry, "--mux-home=" + muxHome), command);
    }

    @Test
    void aDaemonThatDoesNotAnswerStillGetsAHost() {
        java.util.concurrent.CountDownLatch never = new java.util.concurrent.CountDownLatch(1);
        long start = System.nanoTime();
        assertTrue(HostLauncher.anyLive(() -> {
            try {
                never.await();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            return 0;
        }, java.time.Duration.ofMillis(200)));
        assertTrue(System.nanoTime() - start < java.time.Duration.ofSeconds(2).toNanos());
    }

    @Test
    void anAnswerDecides() {
        assertTrue(HostLauncher.anyLive(() -> 2, java.time.Duration.ofSeconds(5)));
        assertFalse(HostLauncher.anyLive(() -> 0, java.time.Duration.ofSeconds(5)));
        assertFalse(HostLauncher.anyLive(() -> {
            throw new IllegalStateException("boom");
        }, java.time.Duration.ofSeconds(5)));
    }
}
