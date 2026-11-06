package io.github.ghosthack.microhm.mux;

import io.github.ghosthack.microhm.mux.cli.Cli;

import java.io.InputStream;
import java.io.PrintStream;

/** Entry point of the CLI jar and of the daemon ({@code serve --daemon}). */
public final class Main {

    public static void main(String[] args) {
        System.exit(run(args, System.in, System.out, System.err));
    }

    /** The whole program minus {@code System.exit}, so tests can drive it. */
    public static int run(String[] args, InputStream stdin, PrintStream out, PrintStream err) {
        return new Cli(stdin, out, err).run(args);
    }

    private Main() {
    }
}
