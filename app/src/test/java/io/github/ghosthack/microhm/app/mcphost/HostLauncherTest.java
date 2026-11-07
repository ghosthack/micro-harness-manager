package io.github.ghosthack.microhm.app.mcphost;

import io.github.ghosthack.microhm.app.MicroHarnessManagerApp;
import org.junit.jupiter.api.Test;

import java.io.File;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class HostLauncherTest {

    @Test
    void aPackagedAppStartsTheHostThroughItsOwnLauncher() {
        List<String> command = HostLauncher.command("/Applications/mhm.app/Contents/MacOS/mhm", "/jdk", "x.jar",
                Path.of("/home/u/.micro-harness-manager/sessions.json"), Path.of("/home/u/.micro-harness-manager/mux"));
        assertEquals(List.of("/Applications/mhm.app/Contents/MacOS/mhm", McpHost.FLAG,
                "--registry=/home/u/.micro-harness-manager/sessions.json",
                "--mux-home=/home/u/.micro-harness-manager/mux"), command);
    }

    @Test
    void aJvmLaunchKeepsTheClasspathAbsoluteAndPassesTheStateLocations() {
        List<String> command = HostLauncher.command(null, "/jdk", "app.jar" + File.pathSeparator + "/abs/lib.jar",
                Path.of("/tmp/r/sessions.json"), Path.of("/tmp/m"));
        assertTrue(command.getFirst().startsWith(Path.of("/jdk", "bin").toString()), command.toString());
        assertTrue(command.contains("--enable-native-access=ALL-UNNAMED"));
        assertTrue(command.contains("--registry=/tmp/r/sessions.json"));
        assertTrue(command.contains("--mux-home=/tmp/m"));
        String classPath = command.get(command.indexOf("-cp") + 1);
        for (String entry : classPath.split(File.pathSeparator)) {
            assertTrue(Path.of(entry).isAbsolute(), entry);
        }
        assertEquals(List.of(MicroHarnessManagerApp.class.getName(), McpHost.FLAG),
                command.subList(command.size() - 4, command.size() - 2));
    }
}
