import Foundation

public enum ThemeName: String, Sendable, Equatable, CaseIterable {
    case dark, light, mono
}

/// `--color` / `"color"`. `auto` uses environment hints only; `NO_COLOR` still wins over every value.
public enum ColorSetting: String, Sendable, Equatable, CaseIterable {
    case auto, never
    case palette256 = "256"
    case truecolor
}

/// Every configurable value, each optional so "absent" is distinguishable from
/// "supplied". The CLI and the config file both parse into this type.
public struct PartialSettings: Sendable, Equatable {
    public var refreshMilliseconds: Int?
    public var sortKey: SortKey?
    public var descending: Bool?
    public var theme: ThemeName?
    public var color: ColorSetting?
    public var normalizeCPU: Bool?
    public var historySamples: Int?
    public var mouse: Bool?

    public init() {}
}

/// Fully resolved settings: CLI > config file > built-in defaults.
public struct Settings: Sendable, Equatable {
    public static let defaultHistorySamples = 60
    public static let maximumHistorySamples = HistoryBuffer<Double>.maximumCapacity

    public var refreshMilliseconds = Options.defaultRefreshMilliseconds
    public var sortKey: SortKey = .pid
    public var descending = false
    public var theme: ThemeName = .dark
    public var color: ColorSetting = .auto
    public var normalizeCPU = false
    public var historySamples = Settings.defaultHistorySamples
    /// Mouse support is not shipped; the value is accepted and has no effect.
    public var mouse = true

    public init() {}

    public static func resolve(cli: PartialSettings, file: PartialSettings) -> Settings {
        var s = Settings()
        s.refreshMilliseconds = cli.refreshMilliseconds ?? file.refreshMilliseconds ?? s.refreshMilliseconds
        s.sortKey = cli.sortKey ?? file.sortKey ?? s.sortKey
        s.descending = cli.descending ?? file.descending ?? s.descending
        s.theme = cli.theme ?? file.theme ?? s.theme
        s.color = cli.color ?? file.color ?? s.color
        s.normalizeCPU = cli.normalizeCPU ?? file.normalizeCPU ?? s.normalizeCPU
        s.historySamples = cli.historySamples ?? file.historySamples ?? s.historySamples
        s.mouse = cli.mouse ?? file.mouse ?? s.mouse
        return s
    }
}

/// Value parsing shared by the CLI and the config file so both enforce the same rules.
public enum SettingValue {
    public struct Failure: Error, Equatable {
        public var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// Plain decimal digits only; overflow and out-of-range values are rejected.
    public static func integer(_ text: String, range: ClosedRange<Int>) -> Result<Int, Failure> {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return .failure(Failure("expected a whole number"))
        }
        guard let value = Int(text) else { return .failure(Failure("number is too large")) }
        return integer(value, range: range)
    }

    public static func integer(_ value: Int, range: ClosedRange<Int>) -> Result<Int, Failure> {
        if value < range.lowerBound { return .failure(Failure("must be at least \(range.lowerBound)")) }
        if value > range.upperBound { return .failure(Failure("must be at most \(range.upperBound)")) }
        return .success(value)
    }

    public static let refreshRange = Options.minimumRefreshMilliseconds...Int(Int32.max)
    public static let historyRange = 1...Settings.maximumHistorySamples

    public static let sortNames = ["pid", "name", "user", "cpu", "memory", "status"]

    public static func sortKey(_ text: String) -> Result<SortKey, Failure> {
        switch text {
        case "pid": .success(.pid)
        case "name": .success(.name)
        case "user": .success(.user)
        case "cpu": .success(.cpu)
        case "memory": .success(.memory)
        case "status": .success(.state)
        default: .failure(Failure("expected one of \(sortNames.joined(separator: ", "))"))
        }
    }

    public static func theme(_ text: String) -> Result<ThemeName, Failure> {
        ThemeName(rawValue: text).map { .success($0) }
            ?? .failure(Failure("expected one of \(ThemeName.allCases.map(\.rawValue).joined(separator: ", "))"))
    }

    public static func color(_ text: String) -> Result<ColorSetting, Failure> {
        ColorSetting(rawValue: text).map { .success($0) }
            ?? .failure(Failure("expected one of \(ColorSetting.allCases.map(\.rawValue).joined(separator: ", "))"))
    }
}

/// The JSON configuration file.
///
/// Schema (all keys optional; see `Documentation/Configuration.md`):
/// `refreshMs` (int ≥ 250), `sort` (pid|name|user|cpu|memory|status),
/// `descending` (bool), `theme` (dark|light|mono), `color` (auto|never|"256"|truecolor),
/// `normalizeCpu` (bool), `historySamples` (int 1…3600), `mouse` (bool).
/// Any wrong type or out-of-range value makes the whole file invalid; unknown
/// keys are reported as warnings so misspellings are noticed.
public enum ConfigFile {
    public static let knownKeys = [
        "refreshMs", "sort", "descending", "theme", "color", "normalizeCpu", "historySamples", "mouse",
    ]
    /// A config file larger than this is rejected without being parsed.
    public static let maximumBytes = 64 * 1024

    public struct Parsed: Sendable, Equatable {
        public var settings = PartialSettings()
        public var unknownKeys: [String] = []
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case tooLarge
        case malformed
        case notAnObject
        case invalidValue(key: String, reason: String)

        public var description: String {
            switch self {
            case .tooLarge: "file is larger than \(ConfigFile.maximumBytes) bytes"
            case .malformed: "not valid JSON"
            case .notAnObject: "top level must be a JSON object"
            case .invalidValue(let key, let reason): "\"\(key)\": \(reason)"
            }
        }
    }

    public static func parse(_ data: Data) -> Result<Parsed, Failure> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else { return .failure(.malformed) }
        guard let dictionary = object as? [String: Any] else { return .failure(.notAnObject) }

        var parsed = Parsed()
        parsed.unknownKeys = dictionary.keys.filter { !knownKeys.contains($0) }.sorted()
        for key in knownKeys {
            guard let value = dictionary[key] else { continue }
            if let failure = apply(value, key: key, to: &parsed.settings) { return .failure(failure) }
        }
        return .success(parsed)
    }

    private static func apply(_ value: Any, key: String, to settings: inout PartialSettings) -> Failure? {
        func bad(_ reason: String) -> Failure { .invalidValue(key: key, reason: reason) }
        func integer() -> Int? {
            // JSONSerialization yields NSNumber; reject booleans and fractions.
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double == double.rounded(), abs(double) < 1e15 else { return nil }
            return number.intValue
        }
        func boolean() -> Bool? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }

        switch key {
        case "refreshMs":
            guard let n = integer() else { return bad("expected a whole number") }
            switch SettingValue.integer(n, range: SettingValue.refreshRange) {
            case .success(let v): settings.refreshMilliseconds = v
            case .failure(let f): return bad(f.reason)
            }
        case "historySamples":
            guard let n = integer() else { return bad("expected a whole number") }
            switch SettingValue.integer(n, range: SettingValue.historyRange) {
            case .success(let v): settings.historySamples = v
            case .failure(let f): return bad(f.reason)
            }
        case "sort":
            guard let s = value as? String else { return bad("expected a string") }
            switch SettingValue.sortKey(s) {
            case .success(let v): settings.sortKey = v
            case .failure(let f): return bad(f.reason)
            }
        case "theme":
            guard let s = value as? String else { return bad("expected a string") }
            switch SettingValue.theme(s) {
            case .success(let v): settings.theme = v
            case .failure(let f): return bad(f.reason)
            }
        case "color":
            guard let s = value as? String else { return bad("expected a string") }
            switch SettingValue.color(s) {
            case .success(let v): settings.color = v
            case .failure(let f): return bad(f.reason)
            }
        case "descending":
            guard let b = boolean() else { return bad("expected true or false") }
            settings.descending = b
        case "normalizeCpu":
            guard let b = boolean() else { return bad("expected true or false") }
            settings.normalizeCPU = b
        case "mouse":
            guard let b = boolean() else { return bad("expected true or false") }
            settings.mouse = b
        default: break
        }
        return nil
    }

    /// A sample file for the documentation; kept here so a test can prove it parses.
    public static let sample = """
        {
          "refreshMs": 1000,
          "sort": "cpu",
          "descending": true,
          "theme": "dark",
          "color": "auto",
          "normalizeCpu": false,
          "historySamples": 60,
          "mouse": false
        }
        """
}

/// Result of locating and reading the configuration file.
public struct LoadedConfiguration: Sendable, Equatable {
    public var settings = PartialSettings()
    /// User-visible warnings (invalid default file, unknown keys).
    public var warnings: [String] = []
}

public enum ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case invalid(path: String, ConfigFile.Failure)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason): "cannot read configuration \(path): \(reason)"
        case .invalid(let path, let failure): "invalid configuration \(path): \(failure)"
        }
    }
}

public enum ConfigLoader {
    /// `~/Library/Application Support/rtop/config.json` under `home`.
    public static func defaultURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/rtop/config.json", isDirectory: false)
    }

    /// An explicit path must exist and be valid (`throws`, exit 2). The default
    /// path may be missing (normal) and, if invalid, yields a warning and defaults.
    public static func load(explicitPath: String?, defaultURL: URL) throws(ConfigError) -> LoadedConfiguration {
        if let explicitPath {
            let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            switch read(url) {
            case .success(let parsed): return loaded(parsed, path: url.path)
            case .failure(let error): throw error
            }
        }
        switch read(defaultURL) {
        case .success(let parsed): return loaded(parsed, path: defaultURL.path)
        case .failure(.unreadable(_, "missing")): return LoadedConfiguration()
        case .failure(let error):
            return LoadedConfiguration(warnings: ["\(error); using defaults"])
        }
    }

    private static func loaded(_ parsed: ConfigFile.Parsed, path: String) -> LoadedConfiguration {
        var result = LoadedConfiguration(settings: parsed.settings)
        if !parsed.unknownKeys.isEmpty {
            let known = ConfigFile.knownKeys.joined(separator: ", ")
            result.warnings.append(
                "ignored unknown key\(parsed.unknownKeys.count == 1 ? "" : "s") "
                    + parsed.unknownKeys.map { "\"\($0)\"" }.joined(separator: ", ") + " in \(path) (known: \(known))")
        }
        return result
    }

    private static func read(_ url: URL) -> Result<ConfigFile.Parsed, ConfigError> {
        let path = url.path
        var info = stat()
        guard stat(path, &info) == 0 else {
            let reason = errno == ENOENT ? "missing" : String(cString: strerror(errno))
            return .failure(.unreadable(path: path, reason: reason))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.unreadable(path: path, reason: "not a regular file"))
        }
        guard info.st_size <= ConfigFile.maximumBytes else { return .failure(.invalid(path: path, .tooLarge)) }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable(path: path, reason: "read failed"))
        }
        switch ConfigFile.parse(data) {
        case .success(let parsed): return .success(parsed)
        case .failure(let failure): return .failure(.invalid(path: path, failure))
        }
    }
}
