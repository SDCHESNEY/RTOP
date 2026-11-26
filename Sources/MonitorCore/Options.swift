import Foundation

/// One command-line option. The same table drives parsing and `--help`, so
/// they cannot drift apart; the man page and shell completions are generated
/// from it too (`rtop --generate-completions`, `--generate-man`).
public struct OptionSpec: Sendable, Equatable {
    public var name: String
    public var valueName: String?
    public var summary: String
    /// Fixed value set, used for completions and help.
    public var choices: [String] = []
    /// Hidden options parse normally but are left out of `--help`.
    public var hidden: Bool = false
}

public enum Options {
    public static let defaultRefreshMilliseconds = 1000
    public static let minimumRefreshMilliseconds = 250

    public static let specs: [OptionSpec] = [
        OptionSpec(name: "--refresh-ms", valueName: "N",
                   summary: "Refresh interval in milliseconds (default 1000, minimum 250)."),
        OptionSpec(name: "--sort", valueName: "KEY", summary: "Initial sort field (default pid).",
                   choices: SettingValue.sortNames),
        OptionSpec(name: "--descending", valueName: nil, summary: "Start with a descending sort."),
        OptionSpec(name: "--theme", valueName: "NAME", summary: "Color theme (default dark).",
                   choices: ThemeName.allCases.map(\.rawValue)),
        OptionSpec(name: "--color", valueName: "MODE",
                   summary: "Color mode (default auto). NO_COLOR always disables color.",
                   choices: ColorSetting.allCases.map(\.rawValue)),
        OptionSpec(name: "--normalize-cpu", valueName: nil,
                   summary: "Show process CPU as a share of all logical CPUs (default: 100% = one core)."),
        OptionSpec(name: "--history-samples", valueName: "N",
                   summary: "History length for the overview graphs (1-3600, default 60)."),
        OptionSpec(name: "--config", valueName: "PATH",
                   summary: "Read this configuration file (it must exist and be valid)."),
        OptionSpec(name: "--no-mouse", valueName: nil,
                   summary: "Disable mouse events (accepted; mouse support is not shipped)."),
        OptionSpec(name: "--help", valueName: nil, summary: "Print this help and exit."),
        OptionSpec(name: "--version", valueName: nil, summary: "Print the version and exit."),
        OptionSpec(name: "--generate-completions", valueName: "SHELL",
                   summary: "Print a shell completion script (zsh, bash, fish) and exit.",
                   choices: ["zsh", "bash", "fish"], hidden: true),
        OptionSpec(name: "--generate-man", valueName: nil, summary: "Print the man page and exit.", hidden: true),
        OptionSpec(name: "--spike-native", valueName: nil,
                   summary: "Phase 0: print one native-collection probe and exit.", hidden: true),
        OptionSpec(name: "--spike-terminal", valueName: nil,
                   summary: "Phase 0: enter/restore terminal mode; press q or Ctrl-C.", hidden: true),
    ]

    /// What was supplied on the command line; absent options stay `nil`.
    public struct RunRequest: Sendable, Equatable {
        public var settings = PartialSettings()
        public var configPath: String?
        public init() {}
    }

    public enum Command: Sendable, Equatable {
        case run(RunRequest)
        case help
        case version
        case generateCompletions(shell: String)
        case generateMan
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
        var request = RunRequest()
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

            var value = ""
            if spec.valueName != nil {
                if let inlineValue {
                    value = inlineValue
                } else if index < arguments.count {
                    value = arguments[index]
                    index += 1
                } else {
                    return .failure(.missingValue(name))
                }
            }
            func invalid(_ failure: SettingValue.Failure) -> Result<Command, ParseError> {
                .failure(.invalidValue(option: name, value: value, reason: failure.reason))
            }

            switch name {
            case "--help": command = .help
            case "--version": if command != .help { command = .version }
            case "--generate-completions":
                if command == nil { command = .generateCompletions(shell: value) }
            case "--generate-man": if command == nil { command = .generateMan }
            case "--spike-native": if command == nil { command = .spikeNative }
            case "--spike-terminal": if command == nil { command = .spikeTerminal }
            case "--refresh-ms":
                switch SettingValue.integer(value, range: SettingValue.refreshRange) {
                case .success(let v): request.settings.refreshMilliseconds = v
                case .failure(let f): return invalid(f)
                }
            case "--history-samples":
                switch SettingValue.integer(value, range: SettingValue.historyRange) {
                case .success(let v): request.settings.historySamples = v
                case .failure(let f): return invalid(f)
                }
            case "--sort":
                switch SettingValue.sortKey(value) {
                case .success(let v): request.settings.sortKey = v
                case .failure(let f): return invalid(f)
                }
            case "--theme":
                switch SettingValue.theme(value) {
                case .success(let v): request.settings.theme = v
                case .failure(let f): return invalid(f)
                }
            case "--color":
                switch SettingValue.color(value) {
                case .success(let v): request.settings.color = v
                case .failure(let f): return invalid(f)
                }
            case "--config":
                guard !value.isEmpty else { return invalid(SettingValue.Failure("path must not be empty")) }
                request.configPath = value
            case "--descending": request.settings.descending = true
            case "--normalize-cpu": request.settings.normalizeCPU = true
            case "--no-mouse": request.settings.mouse = false
            default: break
            }
        }
        if case .generateCompletions(let shell)? = command, !["zsh", "bash", "fish"].contains(shell) {
            return .failure(.invalidValue(option: "--generate-completions", value: shell, reason: "expected zsh, bash, or fish"))
        }
        return .success(command ?? .run(request))
    }

    public static func usage() -> String {
        var lines = ["usage: rtop [options]", "", "A terminal system monitor for macOS.", "", "options:"]
        for spec in specs where !spec.hidden {
            let left = spec.valueName.map { "\(spec.name) <\($0)>" } ?? spec.name
            lines.append("  " + left.padding(toLength: 24, withPad: " ", startingAt: 0) + " " + spec.summary)
            if !spec.choices.isEmpty {
                lines.append(String(repeating: " ", count: 27) + "(" + spec.choices.joined(separator: " | ") + ")")
            }
        }
        lines += ["", "Precedence: command-line options, then the configuration file, then defaults.",
                  "Configuration: ~/Library/Application Support/rtop/config.json (see Documentation/Configuration.md).",
                  "Exit status: 0 normal, 1 startup or runtime failure, 2 invalid options or configuration."]
        return lines.joined(separator: "\n")
    }
}
