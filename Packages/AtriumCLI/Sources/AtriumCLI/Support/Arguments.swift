import Foundation

/// One command's arguments: positionals in order, options by name. Options
/// are `--name value` or `--name=value` and may repeat; flags are `--name`.
/// Everything after `--` is positional, so a prompt can start with a dash.
struct Arguments {
    private(set) var positionals: [String] = []
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String], options: Set<String>, flags known: Set<String>) throws {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            guard argument.hasPrefix("--"), argument.count > 2 else {
                if argument == "--" {
                    positionals += remaining
                    return
                }
                positionals.append(argument)
                continue
            }
            var name = String(argument.dropFirst(2))
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if known.contains(name) {
                guard value == nil else { throw CLIError(.invalidArgument, "--\(name) takes no value.") }
                flags.insert(name)
            } else if options.contains(name) {
                guard let given = value ?? remaining.popFirst() else { throw CLIError(.invalidArgument, "--\(name) needs a value.") }
                values[name, default: []].append(given)
            } else {
                throw CLIError(.invalidArgument, "Unknown option --\(name). `atrium help` lists each command's options.")
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }

    func values(_ name: String) -> [String] { values[name] ?? [] }

    /// The option's value; the last one when it's given more than once.
    func value(_ name: String) -> String? { values[name]?.last }

    /// A flag that can be turned on with `--name` or off with `--no-name`.
    func toggle(_ name: String) throws -> Bool? {
        switch (flag(name), flag("no-" + name)) {
        case (true, true): throw CLIError(.invalidArgument, "Use either --\(name) or --no-\(name).")
        case (true, false): true
        case (false, true): false
        case (false, false): nil
        }
    }

    func number(_ name: String) throws -> Double? {
        guard let text = value(name) else { return nil }
        guard let number = Double(text), number >= 0 else { throw CLIError(.invalidArgument, "--\(name) must be a number of 0 or more.") }
        return number
    }

    func count(_ name: String) throws -> Int? {
        guard let text = value(name) else { return nil }
        guard let count = Int(text), count >= 0 else { throw CLIError(.invalidArgument, "--\(name) must be a whole number of 0 or more.") }
        return count
    }

    /// The positional at `index`, which must be there.
    func required(_ index: Int, _ name: String) throws -> String {
        guard positionals.indices.contains(index) else { throw CLIError(.invalidArgument, "Missing \(name).") }
        return positionals[index]
    }

    func optional(_ index: Int) -> String? {
        positionals.indices.contains(index) ? positionals[index] : nil
    }

    func allowPositionals(_ count: Int) throws {
        guard positionals.count <= count else {
            throw CLIError(.invalidArgument, "Unexpected argument “\(positionals[count])”. Quote a prompt that has spaces.")
        }
    }
}
