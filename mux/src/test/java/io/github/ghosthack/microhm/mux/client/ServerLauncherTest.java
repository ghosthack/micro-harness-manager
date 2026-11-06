package io.github.ghosthack.microhm.mux.client;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Every resolution branch of {@link ServerLauncher}, parameterised so nothing spawns. */
class ServerLauncherTest {

    @Test
    void javaBinaryIsUnderJavaHome() {
        assertEquals(Path.of("/jdk", "bin", "java"), ServerLauncher.javaBinary("/jdk"));
    }

    @Test
    void explicitPropertyWinsAndIsUsedAsGiven() {
        Optional<List<String>> command = ServerLauncher.resolveCommand("/opt/microhm/bin/launcher", "/ignored/env",
                Optional.of(Path.of("/apps/micro-harness-manager")), "/jdk", "a.jar", true);
        assertEquals(List.of(Path.of("/opt/microhm/bin/launcher").toAbsolutePath().normalize().toString(),
                "serve", "--daemon"), command.orElseThrow());
    }

    @Test
    void environmentVariableIsUsedWhenThePropertyIsBlank() {
        Optional<List<String>> command = ServerLauncher.resolveCommand("  ", "relative/launcher.sh",
                Optional.empty(), "/jdk", "a.jar", true);
        assertEquals(List.of(Path.of("relative/launcher.sh").toAbsolutePath().normalize().toString(), "serve", "--daemon"),
                command.orElseThrow());
    }

    @Test
    void siblingPackagedLauncherIsFound(@TempDir Path dir) throws Exception {
        Path launcher = dir.resolve(ServerLauncher.NATIVE_LAUNCHER);
        Files.writeString(launcher, "#!/bin/sh\n");
        Optional<List<String>> command = ServerLauncher.resolveCommand(null, null,
                Optional.of(dir.resolve("micro-harness-manager")), "/jdk", "a.jar", true);
        assertEquals(List.of(launcher.toString(), "serve", "--daemon"), command.orElseThrow());
    }

    @Test
    void classpathFallbackAbsolutizesEntriesAndNamesTheMainClass() {
        String classpath = "target/classes" + File.pathSeparator + "/abs/lib.jar";
        Optional<List<String>> command = ServerLauncher.resolveCommand(null, null,
                Optional.of(Path.of("/apps/micro-harness-manager")), "/jdk", classpath, true);
        assertEquals(List.of(
                Path.of("/jdk", "bin", "java").toString(),
                "--enable-native-access=ALL-UNNAMED",
                "-cp",
                Path.of("target/classes").toAbsolutePath().normalize() + File.pathSeparator
                        + Path.of("/abs/lib.jar").toAbsolutePath().normalize(),
                ServerLauncher.MAIN_CLASS,
                "serve", "--daemon"), command.orElseThrow());
    }

    @Test
    void nothingResolvesWithoutMainClassOrClasspath() {
        assertTrue(ServerLauncher.resolveCommand(null, null, Optional.empty(), "/jdk", "a.jar", false).isEmpty());
        assertTrue(ServerLauncher.resolveCommand(null, null, Optional.empty(), "/jdk", "", true).isEmpty());
        assertTrue(ServerLauncher.resolveCommand(null, null, Optional.empty(), null, "a.jar", true).isEmpty());
        assertTrue(ServerLauncher.resolveCommand(null, null, Optional.of(Path.of("/apps/micro-harness-manager")),
                "/jdk", "", true).isEmpty());
    }

    @Test
    void realResolutionFindsThisProjectOnTheClasspath() {
        List<String> command = ServerLauncher.resolveCommand().orElseThrow();
        assertTrue(command.contains(ServerLauncher.MAIN_CLASS) || command.size() == 3, String.valueOf(command));
        assertEquals(List.of("serve", "--daemon"), command.subList(command.size() - 2, command.size()));
        assertEquals(ServerLauncher.javaBinary(), Path.of(System.getProperty("java.home"), "bin", "java"));
    }
}
