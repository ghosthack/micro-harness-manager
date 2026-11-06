package io.github.ghosthack.microhm.app.state;

/** Detector confidence. The manager doesn't gate any action on it, but it's useful in
 * the tooltip and in tests. */
public enum Confidence {
    LOW,
    MEDIUM,
    HIGH
}
