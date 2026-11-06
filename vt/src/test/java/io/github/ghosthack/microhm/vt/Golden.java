package io.github.ghosthack.microhm.vt;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.fail;

/**
 * Golden files under {@code src/test/resources/golden}: the emulator's expected state for
 * the corpus, fuzz and recording tests. They were first generated while jediterm-core was
 * still a test dependency, at a commit where every one of these cases agreed with it
 * (except the documented {@link KnownDifferencesTest} behaviour), so they freeze that
 * cross-check.
 *
 * <p>A deliberate behaviour change regenerates them: {@code mvn -pl vt test
 * -Dvt.golden.update=true}, then review the diff of {@code golden/} like any other change.
 */
final class Golden {

    static final boolean UPDATE = Boolean.getBoolean("vt.golden.update");

    private Golden() {
    }

    private static Path root() {
        return Path.of(System.getProperty("basedir", "."), "src", "test", "resources", "golden");
    }

    /** Asserts {@code actual} equals the golden file {@code name}, or rewrites it in update mode. */
    static void check(String name, String actual) {
        Path file = root().resolve(name);
        try {
            if (UPDATE) {
                Files.createDirectories(file.getParent());
                Files.writeString(file, actual, StandardCharsets.UTF_8);
                return;
            }
            if (!Files.isRegularFile(file)) {
                fail("missing golden file " + file + "; generate it with -Dvt.golden.update=true");
            }
            String expected = Files.readString(file, StandardCharsets.UTF_8);
            if (!expected.equals(actual)) {
                fail("differs from golden " + name + firstDifference(expected, actual)
                        + "\n(an intended change: rerun with -Dvt.golden.update=true and review the diff)");
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private static String firstDifference(String expected, String actual) {
        String[] a = expected.split("\n", -1);
        String[] b = actual.split("\n", -1);
        for (int i = 0; i < Math.max(a.length, b.length); i++) {
            String x = i < a.length ? a[i] : "<end>";
            String y = i < b.length ? b[i] : "<end>";
            if (!x.equals(y)) {
                return " at line " + (i + 1) + ":\n  expected: " + x + "\n  actual:   " + y;
            }
        }
        return "";
    }

    /** A file-name-safe form of a case name. */
    static String slug(String name) {
        return name.toLowerCase(java.util.Locale.ROOT).replaceAll("[^a-z0-9]+", "-").replaceAll("^-|-$", "");
    }
}
