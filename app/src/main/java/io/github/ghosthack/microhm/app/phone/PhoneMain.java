package io.github.ghosthack.microhm.app.phone;

import io.github.ghosthack.microhm.app.daemon.SessionServerHost;
import io.github.ghosthack.microhm.app.mcphost.McpHost;
import io.github.ghosthack.microhm.app.mcphost.McpStack;
import io.github.ghosthack.microhm.app.registry.RegistryPaths;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;

import java.util.concurrent.CountDownLatch;

/**
 * The phone page on its own: no window, no background host, no instance lock. It serves the
 * page on a port with a secret, over the same controller the app builds ({@link McpStack}),
 * until the process is stopped. For working on the page and for its end-to-end tests
 * ({@code app/src/test/e2e}), which point it at a scratch registry and daemon home so it never
 * sees the user's sessions.
 *
 * <pre>
 * java --enable-native-access=ALL-UNNAMED -cp microhm-app.jar \
 *     io.github.ghosthack.microhm.app.phone.PhoneMain --port=7393 --token=SECRET \
 *     [--registry=/tmp/x/sessions.json] [--mux-home=/tmp/x/mux]
 * </pre>
 *
 * Prints {@code phone page ready on port N} once it is serving. Without {@code --registry} and
 * {@code --mux-home} it uses the app's own, like the background host; it does not check that
 * the app is closed.
 */
public final class PhoneMain {

    static final String READY = "phone page ready on port ";

    public static void main(String[] args) throws Exception {
        System.setProperty("java.awt.headless", "true");
        McpHost.applyStateOptions(args);
        int port = Integer.parseInt(option(args, "--port=", null));
        String token = option(args, "--token=", null);
        if (token.isBlank()) {
            throw new IllegalArgumentException("--token= must not be blank");
        }
        SessionRegistry registry = SessionRegistry.load(RegistryPaths.resolve());
        McpStack stack = McpStack.create(registry, SessionServerHost.forDefaultHome());
        stack.phone().start(port, token);
        CountDownLatch stopped = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(Thread.ofPlatform().unstarted(() -> {
            stack.phone().stop();
            stopped.countDown();
        }));
        System.out.println(READY + port);
        System.out.flush();
        stopped.await();
    }

    private static String option(String[] args, String prefix, String fallback) {
        for (String arg : args) {
            if (arg.startsWith(prefix)) {
                return arg.substring(prefix.length());
            }
        }
        if (fallback == null) {
            throw new IllegalArgumentException("missing " + prefix + "…");
        }
        return fallback;
    }

    private PhoneMain() {
    }
}
