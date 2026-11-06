package io.github.ghosthack.microhm.app.registry;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class SessionNamingTest {

    @Test
    void derivesFromBasename() {
        String name = SessionNaming.deriveUnique(Path.of("/Users/x/Projects/foo"), taken -> false);
        assertEquals("mhm-foo", name);
    }

    @Test
    void sanitizesUnsafeCharacters() {
        String name = SessionNaming.deriveUnique(Path.of("/Users/x/Projects/my project!"), taken -> false);
        assertEquals("mhm-my-project-", name);
    }

    @Test
    void suffixesOnCollision() {
        Set<String> existing = Set.of("mhm-foo", "mhm-foo-2");
        String name = SessionNaming.deriveUnique(Path.of("/Users/x/Projects/foo"), existing::contains);
        assertEquals("mhm-foo-3", name);
    }
}
