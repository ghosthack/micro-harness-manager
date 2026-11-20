import Foundation

/// `java.time.Instant` text: `Instant.toString()` (ISO_INSTANT — UTC, `Z`, seconds always
/// printed, fraction in groups of three digits only as needed) and a parser for ISO-8601
/// instants with `Z` or a numeric offset (what `OffsetDateTime.parse` and Jackson's
/// `InstantDeserializer` accept).
public enum IsoInstant {

    private static let pattern = JRegex(
        #"(-?\d{4,})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?(Z|z|[+-]\d{2}(?::?\d{2}(?::?\d{2})?)?)"#)

    /// Parses an instant; nil when the text isn't one.
    public static func parse(_ text: String) -> Date? {
        guard pattern.matches(text), let g = pattern.firstGroups(text) else { return nil }
        guard let year = Int(g[1]!), let month = Int(g[2]!), let day = Int(g[3]!),
              let hour = Int(g[4]!), let minute = Int(g[5]!) else { return nil }
        let second = g[6].flatMap { Int($0) } ?? 0
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var offsetSeconds = 0
        let zone = g[8]!
        if zone != "Z" && zone != "z" {
            let sign = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            let chars = Array(digits)
            let hh = Int(String(chars[0..<2])) ?? 0
            let mm = chars.count >= 4 ? Int(String(chars[2..<4])) ?? 0 : 0
            let ss = chars.count >= 6 ? Int(String(chars[4..<6])) ?? 0 : 0
            offsetSeconds = sign * (hh * 3600 + mm * 60 + ss)
        }
        let days = daysFromCivil(year, month, day)
        let epochSeconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        guard let fraction = g[7] else {
            return Date(timeIntervalSince1970: Double(epochSeconds))
        }
        // Built the same way format() reads it back, so a value round-trips exactly.
        if fraction.count <= 3 {
            let ms = Int64(fraction.padding(toLength: 3, withPad: "0", startingAt: 0))!
            return Date(timeIntervalSince1970: Double(epochSeconds * 1000 + ms) / 1000)
        }
        if fraction.count <= 6 {
            let us = Int64(fraction.padding(toLength: 6, withPad: "0", startingAt: 0))!
            return Date(timeIntervalSince1970: Double(epochSeconds * 1_000_000 + us) / 1_000_000)
        }
        let ns = Int64(fraction.padding(toLength: 9, withPad: "0", startingAt: 0))!
        return Date(timeIntervalSince1970: Double(epochSeconds) + Double(ns) / 1_000_000_000)
    }

    /// `Instant.toString()`, at microsecond resolution (what a Date carries reliably).
    public static func format(_ date: Date) -> String {
        let totalMicros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        var seconds = totalMicros / 1_000_000
        var micros = totalMicros % 1_000_000
        if micros < 0 {
            micros += 1_000_000
            seconds -= 1
        }
        var days = seconds / 86_400
        var secOfDay = seconds % 86_400
        if secOfDay < 0 {
            secOfDay += 86_400
            days -= 1
        }
        let (y, m, d) = civilFromDays(Int(days))
        var out = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", y, m, d,
                         Int(secOfDay / 3600), Int(secOfDay % 3600 / 60), Int(secOfDay % 60))
        if micros != 0 {
            if micros % 1000 == 0 {
                out += String(format: ".%03d", Int(micros / 1000))
            } else {
                out += String(format: ".%06d", Int(micros))
            }
        }
        return out + "Z"
    }

    // Howard Hinnant's civil-date algorithms (proleptic Gregorian).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
