package io.github.ghosthack.microhm.app.session;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class SessionEventsTest {

    @Test
    void killFiresKilledListenersThenAChangeAndAThrowingListenerIsIsolated() {
        SessionEvents events = new SessionEvents();
        List<String> seen = new ArrayList<>();
        events.addSessionsChangedListener(created -> {
            throw new IllegalStateException("broken listener");
        });
        SessionEvents.SessionsChangedListener changed = created -> seen.add("changed " + created);
        events.addSessionsChangedListener(changed);
        events.addSessionKilledListener(session -> seen.add("killed " + session));

        events.fireSessionsChanged("mhm-new");
        events.fireSessionKilled("mhm-old");
        events.removeSessionsChangedListener(changed);
        events.fireSessionsChanged(null);

        assertEquals(List.of("changed mhm-new", "killed mhm-old", "changed null"), seen);
    }
}
