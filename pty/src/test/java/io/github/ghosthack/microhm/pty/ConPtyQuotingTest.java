package io.github.ghosthack.microhm.pty;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** The Windows command-line quoting, checked against the C runtime's parsing rules (any OS). */
final class ConPtyQuotingTest {

    @Test
    void plainArgumentsAreLeftAlone() {
        assertEquals("plain", ConPty.quote("plain"));
        assertEquals("C:\\dir\\a.exe", ConPty.quote("C:\\dir\\a.exe"));
        assertEquals("trailing\\", ConPty.quote("trailing\\"), "backslashes only matter before a quote");
    }

    @Test
    void whitespaceQuotesAndEmptyAreQuoted() {
        assertEquals("\"with space\"", ConPty.quote("with space"));
        assertEquals("\"\"", ConPty.quote(""));
        assertEquals("\"a\\\"b\"", ConPty.quote("a\"b"));
        assertEquals("\"x y\\\\\"", ConPty.quote("x y\\"), "a trailing backslash before the closing quote doubles");
        assertEquals("\"q\\\\\\\"r\"", ConPty.quote("q\\\"r"), "backslashes before a quote double, plus one");
    }

    @Test
    void commandLineJoinsTheProgramAndArguments() {
        assertEquals("\"C:\\Program Files\\x.exe\" -a \"b c\"",
                ConPty.commandLine("C:\\Program Files\\x.exe", List.of("-a", "b c")));
    }
}
