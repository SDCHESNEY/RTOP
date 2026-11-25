import Foundation

/// One command-line option. The same table drives parsing and `--help`, so
/// they cannot drift apart. Phase 4 extends it with the remaining options.
public struct OptionSpec: Sendable, Equatable {
    public var name: String
    public var valueName: String?
    public var summary: String
    /// Hidden options parse normally but are left out of `--help`.
    public var hidden: Bool = false
}

public enum Options {
    public static let defaultRefreshMilliseconds = 1000
    public static let minimumRefreshMilliseconds = 250

    public static let specs: [OptionSpec] = [
        OptionSpec(name: "--refresh-ms", valueName: "N",
                   summary: "Refresh interval in milliseconds (default 1000, minimum 250)."),
        OptionSpec(name: "--help", valueName: nil, summary: "Print this help and exit."),
        OptionSpec(name: "--version", valueName: nil, summary: "Print the version and exit."),
        OptionSpec(name: "--spike-native", valueName: nil,
                   summary: "Phase 0: print one native-collection probe and exit.", hidden: true),
        OptionSpec(name: "--spike-terminal", valueName: nil,
                   summary: "Phase 0: enter/restore terminal mode; press q or Ctrl-C.", hidden: true),
    ]

    public enum Command: Sendable, Equatable {
        case run(refreshMilliseconds: Int)
        case help
        case version
        case spikeNative
        case spikeTerminal
    }

    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case unknownOption(String)
        case missingValue(String)
        case invalidValue(option: String, value: String, reason: String)
        case unexpectedArgument(String)

        public var description: String {
            switch self {
            case .unknownOption(let o): "unknown option \(o)"
            case .missingValue(let o): "option \(o) requires a value"
            case .invalidValue(let o, let v, let reason): "invalid value '\(v)' for \(o): \(reason)"
            case .unexpectedArgument(let a): "unexpected argument '\(a)'"
            }
        }
    }

    /// Parses arguments (without the program name). `--help` and `--version`
    /// win over everything else so they never need a terminal.
    public static func parse(_ arguments: [String]) -> Result<Command, ParseError> {
        var refresh = defaultRefreshMilliseconds
        var command: Command?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            var name = argument
            var inlineValue: String?
            if argument.hasPrefix("--"), let eq = argument.firstIndex(of: "=") {
                name = String(argument[..<eq])
                inlineValue = String(argument[argument.index(after: eq)...])
            }
            if name == "-h" { name = "--help" }

            guard name.hasPrefix("-") else { return .failure(.unexpectedArgument(argument)) }
            guard let spec = specs.first(where: { $0.name == name }) else {
                return .failure(.unknownOption(argument))
            }
            if spec.valueName == nil, inlineValue != nil {
                return .failure(.invalidValue(option: name, value: inlineValue ?? "", reason: "option takes no value"))
            }

            switch name {
            case "--help": command = .help
            case "--version": if command != .help { command = .version }
            case "--spike-native": if command == nil { command = .spikeNative }
            case "--spike-terminal": if command == nil { command = .spikeTerminal }
            case "--refresh-ms":
                let value: String
                if let inlineValue {
                    value = inlineValue
                } else if index < arguments.count {
                    value = arguments[index]
                    index += 1
                } else {
                    return .failure(.missingValue(name))
                }
                switch parseRefresh(value) {
                case .success(let ms): refresh = ms
                case .failure(let error): return .failure(.invalidValue(option: name, value: value, reason: error.reason))
                }
            default: break
            }
        }
        return .success(command ?? .run(refreshMilliseconds: refresh))
    }

    /// Plain decimal digits only; overflow and values below the minimum are rejected.
    static func parseRefresh(_ text: String) -> Result<Int, ValueError> {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return .failure(ValueError("expected a whole number of milliseconds"))
        }
        guard let value = Int(text) else { return .failure(ValueError("number is too large")) }
        guard value >= minimumRefreshMilliseconds else {
            return .failure(ValueError("must be at least \(minimumRefreshMilliseconds)"))
        }
        return .success(value)
    }

    struct ValueError: Error, Equatable {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    public static func usage() -> String {
        var lines = ["usage: rtop [options]", "", "A terminal system monitor for macOS.", "", "options:"]
        for spec in specs where !spec.hidden {
            let left = spec.valueName.map { "\(spec.name) <\($0)>" } ?? spec.name
            lines.append("  " + left.padding(toLength: 20, withPad: " ", startingAt: 0) + " " + spec.summary)
        }
        return lines.joined(separator: "\n")
    }
}
