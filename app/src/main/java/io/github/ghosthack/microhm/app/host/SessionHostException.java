package io.github.ghosthack.microhm.app.host;

/**
 * A session-host operation failed: the daemon could not be reached or refused a
 * request. Kept separate from the daemon client's own exception so nothing above the
 * {@link SessionHost} seam has to depend on the client library to report a failure.
 */
public class SessionHostException extends RuntimeException {

    public SessionHostException(String message) {
        super(message);
    }

    public SessionHostException(String message, Throwable cause) {
        super(message, cause);
    }
}
