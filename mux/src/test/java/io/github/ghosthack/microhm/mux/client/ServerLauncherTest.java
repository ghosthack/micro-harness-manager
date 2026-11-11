package io.github.ghosthack.microhm.mux.client;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Every resolution branch of {@link ServerLauncher}, parameterised so nothing spawns. */
class ServerLauncherTest {

    private static final boolean WINDOWS = System.getProperty("os.name", "").startsWith("Windows");
    private static final String EXE = WINDOWS ? ".exe" : "";
    private static final String JAVA = "java" + EXE;

    @Test
    void javaBinaryIsUnderJavaHome() {
        assertEquals(Path.of("/jdk", "bin", JAVA), ServerLauncher.javaBinary("/jdk"));
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
        Path launcher = dir.resolve(ServerLauncher.NATIVE_LAUNCHER + EXE);
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
        List<String> expected = new ArrayList<>();
        expected.add(Path.of("/jdk", "bin", JAVA).toString());
        expected.addAll(JvmOptions.RESIDENT);
        expected.addAll(List.of(
                "--enable-native-access=ALL-UNNAMED",
                "-cp",
                Path.of("target/classes").toAbsolutePath().normalize() + File.pathSeparator
                        + Path.of("/abs/lib.jar").toAbsolutePath().normalize(),
                ServerLauncher.MAIN_CLASS,
                "serve", "--daemon"));
        assertEquals(expected, command.orElseThrow());
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
        assertEquals(ServerLauncher.javaBinary(), Path.of(System.getProperty("java.home"), "bin", JAVA));
    }

    @Test
    @EnabledOnOs({OS.MAC, OS.LINUX})
    void spawnCreatesTheHomeAndTheLogPrivateToTheOwner(@TempDir Path dir) throws Exception {
        Path home = dir.resolve("mux");
        String before = System.getProperty(ServerLauncher.LAUNCHER_PROPERTY);
        // Any executable stands in for the daemon: the redirect is what creates the log.
        System.setProperty(ServerLauncher.LAUNCHER_PROPERTY, "/bin/sh");
        try {
            ServerLauncher.spawn(home).waitFor();
        } finally {
            if (before == null) {
                System.clearProperty(ServerLauncher.LAUNCHER_PROPERTY);
            } else {
                System.setProperty(ServerLauncher.LAUNCHER_PROPERTY, before);
            }
        }
        assertEquals("rwx------", PosixFilePermissions.toString(Files.getPosixFilePermissions(home)));
        assertEquals("rw-------",
                PosixFilePermissions.toString(Files.getPosixFilePermissions(home.resolve("server.log"))));
    }
}
