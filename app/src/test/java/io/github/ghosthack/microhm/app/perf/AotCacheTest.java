package io.github.ghosthack.microhm.app.perf;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.time.Instant;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;

class AotCacheTest {

    @TempDir
    Path dir;

    @Test
    void noOptionMeansNotConfigured() {
        assertEquals(AotCache.State.NOT_CONFIGURED, AotCache.detect(List.of("-Xmx2g"), Instant.now()).state());
    }

    @Test
    void anUnexpandedLauncherVariableIsIgnored() {
        assertEquals(Optional.empty(), AotCache.configuredPath(List.of("-XX:AOTCache=$HOME/x.aot")));
        assertEquals(Optional.empty(), AotCache.configuredPath(List.of("-XX:AOTCache=%USERPROFILE%/x.aot")));
        assertEquals(Optional.empty(), AotCache.configuredPath(List.of("-XX:AOTCache=relative.aot")));
    }

    @Test
    void theLastOptionWins() {
        Path a = dir.resolve("a.aot");
        Path b = dir.resolve("b.aot");
        assertEquals(Optional.of(b), AotCache.configuredPath(List.of("-XX:AOTCache=" + a, "-XX:AOTCache=" + b)));
    }

    @Test
    void aMissingCacheIsMadeLater() {
        AotCache cache = AotCache.detect(List.of("-XX:AOTCache=" + dir.resolve("m.aot")), Instant.now());
        assertEquals(AotCache.State.MISSING, cache.state());
        assertEquals(-1, cache.size());
    }

    @Test
    void aCacheFromBeforeTheLaunchWasUsed() throws Exception {
        Path path = dir.resolve("c.aot");
        Files.write(path, new byte[]{1, 2, 3});
        Files.setLastModifiedTime(path, FileTime.from(Instant.now().minusSeconds(60)));
        AotCache cache = AotCache.detect(List.of("-XX:AOTCache=" + path), Instant.now());
        assertEquals(AotCache.State.USED, cache.state());
        assertEquals(3, cache.size());
    }

    @Test
    void aVersionWhoseCachesWouldNotStartIsNotTriedAgain() throws Exception {
        Path path = dir.resolve("f.aot");
        Files.writeString(AotCache.failedMarker(path), "no");
        assertEquals(AotCache.State.FAILED, AotCache.detect(List.of("-XX:AOTCache=" + path), Instant.now()).state());
    }

    @Test
    void aCacheWrittenAfterTheLaunchWasNot() throws Exception {
        Path path = dir.resolve("c.aot");
        Files.write(path, new byte[]{1});
        Instant launch = Instant.now().minusSeconds(60);
        assertEquals(AotCache.State.MISSING, AotCache.detect(List.of("-XX:AOTCache=" + path), launch).state());
    }
}
