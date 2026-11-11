package io.github.ghosthack.microhm.pty;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

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

    // --- batch files: cmd.exe's rules, not the C runtime's ---------------------------------

    private static final String CMD = "C:\\Windows\\System32\\cmd.exe";

    private static String batch(String... arguments) throws IOException {
        String line = ConPty.batchCommandLine(CMD, "C:\\bin\\tool.cmd", List.of(arguments));
        String prefix = CMD + " /e:ON /v:OFF /d /c \"\"C:\\bin\\tool.cmd\"";
        assertEquals(prefix, line.substring(0, prefix.length()));
        assertEquals('"', line.charAt(line.length() - 1));
        return line.substring(prefix.length(), line.length() - 1);
    }

    /** True when {@code line} leaves a cmd.exe metacharacter outside double quotes, where
     * cmd would act on it (cmd toggles quoting at every quote; nothing escapes one). */
    private static boolean metacharacterOutsideQuotes(String line) {
        boolean quoted = false;
        for (char c : line.toCharArray()) {
            if (c == '"') {
                quoted = !quoted;
            } else if (!quoted && "&|<>^()".indexOf(c) >= 0) {
                return true;
            }
        }
        return quoted; // an unbalanced quote would swallow the closing one
    }

    @Test
    void plainBatchArgumentsAreLeftAlone() throws IOException {
        assertEquals(" plain -v C:\\dir\\a.txt résumé", batch("plain", "-v", "C:\\dir\\a.txt", "résumé"));
        assertEquals(" \"--flag=1\"", batch("--flag=1"), "'=' separates arguments for cmd: quoted");
        assertEquals(" \"\"", batch(""));
    }

    @Test
    void commandSeparatorsAreQuoted() throws IOException {
        assertEquals(" \"a&calc\"", batch("a&calc"));
        assertEquals(" \"a|b\" \"x^y\" \"<in\" \">out\" \"(p)\"", batch("a|b", "x^y", "<in", ">out", "(p)"));
        for (String hostile : List.of("a&calc", "a|b", "x^y", "a&&b", "1>2", "(x)", "a b&c")) {
            assertEquals(false, metacharacterOutsideQuotes(batch(hostile)), hostile);
        }
    }

    @Test
    void anInnerQuoteCannotEndTheQuoting() throws IOException {
        // C-runtime quoting would give "fix \"b & c\" d", leaving the & outside quotes for cmd.
        assertEquals(" \"fix \"\"b & c\"\" d\"", batch("fix \"b & c\" d"));
        assertEquals(true, metacharacterOutsideQuotes(ConPty.quote("fix \"b & c\" d")), "what the old quoting did");
        for (String hostile : List.of("fix \"b & c\" d", "\"&calc", "a\"&calc&\"", "\\\"&calc", "\"\"&calc")) {
            assertEquals(false, metacharacterOutsideQuotes(batch(hostile)), hostile);
        }
        assertEquals(" \"a\\\\\"\"b\"", batch("a\\\"b"), "backslashes before a quote double");
    }

    @Test
    void percentCannotOpenAVariable() throws IOException {
        assertEquals(" \"%%cd:~,%PATH%%cd:~,%\"", batch("%PATH%"));
        assertEquals(" \"100%%cd:~,%\"", batch("100%"));
    }

    @Test
    void aTrailingBackslashCannotEscapeTheClosingQuote() throws IOException {
        assertEquals(" \"C:\\dir\\\\\"", batch("C:\\dir\\"));
        assertEquals(" \"a b\\\\\"", batch("a b\\"));
        assertEquals(" C:\\dir\\file", batch("C:\\dir\\file"), "inner backslashes are left alone");
    }

    @Test
    void whatCannotBePassedSafelyIsRefused() {
        assertThrows(IOException.class, () -> batch("a\nb"));
        assertThrows(IOException.class, () -> batch("a\rb"));
        assertThrows(IOException.class, () -> batch("a\0b"));
        assertThrows(IOException.class, () -> ConPty.batchCommandLine(CMD, "C:\\x\"&calc\".cmd", List.of()));
        assertThrows(IOException.class, () -> ConPty.batchCommandLine(CMD, "C:\\dir\\", List.of()));
    }

    @Test
    void aCommandInterpreterPathWithSpacesIsQuoted() throws IOException {
        assertEquals("\"C:\\Program Files\\cmd.exe\" /e:ON /v:OFF /d /c \"\"C:\\a b\\t.bat\" x\"",
                ConPty.batchCommandLine("C:\\Program Files\\cmd.exe", "C:\\a b\\t.bat", List.of("x")));
    }
}
