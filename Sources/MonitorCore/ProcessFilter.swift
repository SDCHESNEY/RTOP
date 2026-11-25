import Foundation

/// A parsed filter: whitespace-separated terms combined with AND.
///
/// - plain term: case-insensitive substring of the process name. (The command
///   line joins in once Phase 3 collects it; only already-available data is used.)
/// - `pid:N`: exact, positive PID.
/// - `user:X`: user name (case-insensitive, exact) or exact numeric UID.
/// - `path:X`: case-insensitive substring of the available executable path.
/// Predicate prefixes are case-insensitive. No quoting or regular expressions.
public struct ProcessFilter: Sendable, Equatable {
    public enum Term: Sendable, Equatable {
        case text(String)
        case pid(Int32)
        case user(String)
        case path(String)
    }

    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case emptyValue(predicate: String)
        case invalidPID(String)

        public var description: String {
            switch self {
            case .emptyValue(let p): "\(p): needs a value"
            case .invalidPID(let v): "pid: needs a positive whole number, got '\(v)'"
            }
        }
    }

    public var terms: [Term]

    public init(terms: [Term] = []) { self.terms = terms }

    public static let empty = ProcessFilter()
    public var isEmpty: Bool { terms.isEmpty }

    public static func parse(_ text: String) -> Result<ProcessFilter, ParseError> {
        var terms = [Term]()
        for word in text.split(whereSeparator: \.isWhitespace) {
            let word = String(word)
            if let (predicate, value) = splitPredicate(word) {
                guard !value.isEmpty else { return .failure(.emptyValue(predicate: predicate)) }
                switch predicate {
                case "pid":
                    guard value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                          let pid = Int32(value), pid > 0
                    else { return .failure(.invalidPID(value)) }
                    terms.append(.pid(pid))
                case "user": terms.append(.user(value))
                default: terms.append(.path(value))
                }
            } else {
                terms.append(.text(word))
            }
        }
        return .success(ProcessFilter(terms: terms))
    }

    /// Recognises `pid:`, `user:` and `path:` in any letter case. Any other
    /// `word:` is an ordinary text term.
    private static func splitPredicate(_ word: String) -> (String, String)? {
        guard let colon = word.firstIndex(of: ":") else { return nil }
        let name = word[..<colon].lowercased()
        guard ["pid", "user", "path"].contains(name) else { return nil }
        return (name, String(word[word.index(after: colon)...]))
    }

    public func matches(_ row: ProcessSummary) -> Bool {
        terms.allSatisfy { matches($0, row) }
    }

    public func apply(to rows: [ProcessSummary]) -> [ProcessSummary] {
        isEmpty ? rows : rows.filter(matches)
    }

    private func matches(_ term: Term, _ row: ProcessSummary) -> Bool {
        switch term {
        case .text(let needle):
            return Self.contains(row.name, needle)
        case .pid(let pid):
            return row.identity.pid == pid
        case .user(let value):
            if let name = row.userName.value, name.lowercased() == value.lowercased() { return true }
            if value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let uid = UInt32(value) {
                return row.uid.value == uid
            }
            return false
        case .path(let needle):
            guard let path = row.executablePath.value else { return false }
            return Self.contains(path, needle)
        }
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.lowercased().contains(needle.lowercased())
    }
}
