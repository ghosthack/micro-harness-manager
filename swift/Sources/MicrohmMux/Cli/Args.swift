import Foundation

/// The whole option grammar the CLI needs: `--flag`, `--option VALUE` or `--option=VALUE`,
/// anywhere on the line, and positionals in order. Each subcommand declares which names it
/// accepts; anything else is a usage error, so a typo never silently becomes a session
/// name.
struct Args {

    /// A malformed command line; the message is what the user sees.
    struct UsageException: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    private(set) var positionals: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    static func parse(_ argv: [String], _ valueOptions: Set<String>, _ flagOptions: Set<String>) throws -> Args {
        var args = Args()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            defer { i += 1 }
            if !arg.hasPrefix("--") || arg.count == 2 {
                args.positionals.append(arg)
                continue
            }
            var name = arg
            var inline: String?
            if let eq = arg.firstIndex(of: "="), eq != arg.startIndex {
                name = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }
            if flagOptions.contains(name) {
                if inline != nil {
                    throw UsageException("\(name) takes no value")
                }
                args.flags.insert(name)
            } else if valueOptions.contains(name) {
                var value = inline
                if value == nil {
                    if i + 1 >= argv.count {
                        throw UsageException("\(name) needs a value")
                    }
                    i += 1
                    value = argv[i]
                }
                args.values[name] = value
            } else {
                throw UsageException("unknown option \(name)")
            }
        }
        return args
    }

    /// The positional at `index`, or a usage error naming what was expected.
    func positional(_ index: Int, _ what: String) throws -> String {
        if index >= positionals.count {
            throw UsageException("\(what) is required")
        }
        return positionals[index]
    }

    func value(_ option: String) -> String? {
        values[option]
    }

    func flag(_ option: String) -> Bool {
        flags.contains(option)
    }

    func intValue(_ option: String, _ fallback: Int) throws -> Int {
        guard let v = value(option) else { return fallback }
        guard let n = Int32(v.trimmingCharacters(in: .whitespaces)) else {
            throw UsageException("\(option) must be an integer, not '\(v)'")
        }
        return Int(n)
    }

    func longValue(_ option: String, _ fallback: Int64) throws -> Int64 {
        guard let v = value(option) else { return fallback }
        guard let n = Int64(v.trimmingCharacters(in: .whitespaces)) else {
            throw UsageException("\(option) must be an integer, not '\(v)'")
        }
        return n
    }

    /// `--size CxR` as (columns, rows).
    static func size(_ value: String) throws -> (Int, Int) {
        let parts = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        if parts.count == 2,
           let columns = Int32(parts[0].trimmingCharacters(in: .whitespaces)),
           let rows = Int32(parts[1].trimmingCharacters(in: .whitespaces)),
           columns > 0, rows > 0 {
            return (Int(columns), Int(rows))
        }
        throw UsageException("--size must be COLUMNSxROWS, e.g. 120x40, not '\(value)'")
    }
}
