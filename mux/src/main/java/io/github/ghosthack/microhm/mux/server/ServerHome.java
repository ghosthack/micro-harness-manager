package io.github.ghosthack.microhm.mux.server;

import java.io.IOException;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.ValueLayout;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermission;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Set;

/**
 * Where one server lives: a directory holding the socket, the lock and the log. One
 * server per home; the app and the CLI share the default home, and tests use a
 * temporary one so they never touch (or spawn) the user's real server.
 *
 * <p>Default: {@code ~/.micro-harness-manager/mux}. Override with
 * {@code -Dmicrohm.mux.home=DIR} or {@code MICROHM_MUX_HOME}.
 * Unix-domain socket paths have a small length ceiling (104 bytes on macOS, 108 on Linux), so a deeply nested override may fail to bind with a clear error; the
 * default is well inside the limit for any sane home directory.
 *
 * <p>Access control (POSIX): whoever can connect to the socket can run commands as the
 * daemon's user, so the home is the trust boundary. It is private to its owner
 * ({@code 0700}, as are the socket and the log at {@code 0600}), and neither side uses a
 * home that belongs to someone else: a directory another user created could hold their
 * socket in place of ours. Nothing here applies on Windows.
 */
public final class ServerHome {

    public static final String HOME_PROPERTY = "microhm.mux.home";
    public static final String HOME_ENV = "MICROHM_MUX_HOME";
    public static final String SOCKET_FILE = "server.sock";
    public static final String LOCK_FILE = "server.lock";
    public static final String LOG_FILE = "server.log";

    public static Path resolve() {
        String configured = System.getProperty(HOME_PROPERTY);
        if (configured == null || configured.isBlank()) {
            configured = System.getenv(HOME_ENV);
        }
        if (configured != null && !configured.isBlank()) {
            return Path.of(configured).toAbsolutePath().normalize();
        }
        return Path.of(System.getProperty("user.home"), ".micro-harness-manager", "mux");
    }

    public static Path socket(Path home) {
        return home.resolve(SOCKET_FILE);
    }

    public static Path lock(Path home) {
        return home.resolve(LOCK_FILE);
    }

    public static Path log(Path home) {
        return home.resolve(LOG_FILE);
    }

    private static final boolean POSIX = FileSystems.getDefault().supportedFileAttributeViews().contains("posix");
    private static final Set<PosixFilePermission> OWNER_DIRECTORY = PosixFilePermissions.fromString("rwx------");
    private static final Set<PosixFilePermission> OWNER_FILE = PosixFilePermissions.fromString("rw-------");

    /** Creates {@code home} private to the current user, or makes an existing one of theirs
     * private (a home an earlier build created with the umask's permissions). Throws when it
     * belongs to someone else. Used by whoever is about to create something in the home:
     * the daemon, and the client that launches it. */
    public static void secure(Path home) throws IOException {
        if (!POSIX) {
            Files.createDirectories(home);
            return;
        }
        if (!Files.isDirectory(home)) {
            if (home.getParent() != null) {
                Files.createDirectories(home.getParent());
            }
            try {
                // Created private rather than tightened afterwards: no moment in between.
                Files.createDirectory(home, PosixFilePermissions.asFileAttribute(OWNER_DIRECTORY));
            } catch (FileAlreadyExistsException e) {
                // Lost a race with a peer doing the same; the checks below still apply.
            }
        }
        requireOwned(home);
        if (!Files.getPosixFilePermissions(home).equals(OWNER_DIRECTORY)) {
            Files.setPosixFilePermissions(home, OWNER_DIRECTORY);
        }
    }

    /** Throws when {@code home} exists and belongs to another user; a missing home is fine
     * (no server there). What a client checks before it connects. */
    public static void requireOwned(Path home) throws IOException {
        if (POSIX && Files.exists(home)) {
            requireOwnedBy(home, currentUserId());
        }
    }

    /** {@link #requireOwned} against an explicit user id (-1 = unknown: compare names). */
    static void requireOwnedBy(Path home, int userId) throws IOException {
        boolean owned = userId >= 0
                ? ((Number) Files.getAttribute(home, "unix:uid")).intValue() == userId
                : Files.getOwner(home).getName().equals(System.getProperty("user.name"));
        if (!owned) {
            throw new IOException("the session server home " + home + " belongs to another user ("
                    + Files.getOwner(home).getName() + "); refusing to use it. Set " + HOME_ENV
                    + " (or -D" + HOME_PROPERTY + ") to a directory of your own");
        }
    }

    /** Creates the log private to its owner if it is missing, and makes an existing one
     * private: it records every session's command line. Call after {@link #secure}. */
    public static void createLog(Path log) throws IOException {
        if (!POSIX) {
            return;
        }
        try {
            Files.createFile(log, PosixFilePermissions.asFileAttribute(OWNER_FILE));
        } catch (FileAlreadyExistsException e) {
            restrict(log);
        }
    }

    /** Makes a file of ours in the home ({@code server.sock}, {@code server.log})
     * readable and writable by its owner only. */
    static void restrict(Path file) throws IOException {
        if (POSIX && !Files.getPosixFilePermissions(file).equals(OWNER_FILE)) {
            Files.setPosixFilePermissions(file, OWNER_FILE);
        }
    }

    /** The process's real user id, or -1 where it cannot be asked. Asked of the OS rather
     * than derived from {@code user.name}: a uid without a passwd entry (containers) has no
     * name to compare. */
    private static int currentUserId() {
        return CurrentUser.ID;
    }

    private static final class CurrentUser {
        static final int ID = lookup();

        private static int lookup() {
            try {
                Linker linker = Linker.nativeLinker();
                return (int) linker.downcallHandle(linker.defaultLookup().find("getuid").orElseThrow(),
                        FunctionDescriptor.of(ValueLayout.JAVA_INT)).invoke();
            } catch (Throwable e) {
                return -1;
            }
        }
    }

    private ServerHome() {
    }
}
