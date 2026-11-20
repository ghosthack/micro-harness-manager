import Darwin
import MicrohmMux

// The CLI and the daemon (`microhm-mux serve --daemon --home DIR`, how a client starts it;
// see ServerLauncher). The Java original's entry point was mux/Main.
exit(Cli().run(Array(CommandLine.arguments.dropFirst())))
