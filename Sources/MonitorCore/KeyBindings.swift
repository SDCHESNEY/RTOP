/// Input contexts, highest precedence first (see `KeyBindings.precedence`).
public enum KeyContext: Sendable, Equatable, CaseIterable {
    case filterEditor, signalModal, help, details, main

    public var title: String {
        switch self {
        case .main: "Process list"
        case .details: "Details"
        case .filterEditor: "Filter editor"
        case .signalModal: "Signal dialog"
        case .help: "Help"
        }
    }
}

public struct KeyBinding: Sendable, Equatable {
    public var keys: String
    public var summary: String
    public var context: KeyContext
    /// Short form for the footer; nil keeps the binding out of the footer.
    public var footer: String?
}

/// The single source for footer hints and the help overlay. The reducer
/// implements these bindings; `KeyBindingsTests` keeps the two in step.
///
/// Precedence: an open filter editor consumes keys first, then the signal
/// dialog, then help, then the detail pane, then the process list. Ctrl-C
/// quits from every context. Escape closes the innermost context and quits
/// only when none is open.
public enum KeyBindings {
    public static let precedence: [KeyContext] = [.filterEditor, .signalModal, .help, .details, .main]

    public static let all: [KeyBinding] = [
        KeyBinding(keys: "q, Ctrl-C", summary: "Quit", context: .main, footer: "q quit"),
        KeyBinding(keys: "Esc", summary: "Close the innermost dialog or pane; quit if none", context: .main, footer: nil),
        KeyBinding(keys: "Up/Down, j/k", summary: "Move selection", context: .main, footer: nil),
        KeyBinding(keys: "PgUp/PgDn", summary: "Move by a page", context: .main, footer: nil),
        KeyBinding(keys: "Home/End", summary: "First / last process", context: .main, footer: nil),
        KeyBinding(keys: "s", summary: "Cycle sort field", context: .main, footer: "s sort"),
        KeyBinding(keys: "r", summary: "Reverse sort order", context: .main, footer: nil),
        KeyBinding(keys: "/", summary: "Edit filter", context: .main, footer: "/ filter"),
        KeyBinding(keys: "Space", summary: "Pause / resume display", context: .main, footer: nil),
        KeyBinding(keys: "t", summary: "Toggle process tree", context: .main, footer: "t tree"),
        KeyBinding(keys: "d, Enter", summary: "Show process details", context: .main, footer: "d details"),
        KeyBinding(keys: "x", summary: "Send a signal (asks first)", context: .main, footer: "x signal"),
        KeyBinding(keys: "?", summary: "Show this help", context: .main, footer: "? help"),

        KeyBinding(keys: "Esc, d", summary: "Close details", context: .details, footer: "Esc close"),
        KeyBinding(keys: "Up/Down", summary: "Details follow the selection", context: .details, footer: "↑↓ select"),
        KeyBinding(keys: "x", summary: "Send a signal (asks first)", context: .details, footer: "x signal"),

        KeyBinding(keys: "text", summary: "Letters are filter text, not commands", context: .filterEditor, footer: nil),
        KeyBinding(keys: "Enter", summary: "Keep a valid filter", context: .filterEditor, footer: "Enter keep"),
        KeyBinding(keys: "Esc", summary: "Restore the previous filter", context: .filterEditor, footer: "Esc cancel"),
        KeyBinding(keys: "Ctrl-U", summary: "Clear the text", context: .filterEditor, footer: nil),

        KeyBinding(keys: "Left/Right", summary: "Change signal (resets confirmation)", context: .signalModal, footer: "←→ signal"),
        KeyBinding(keys: "Enter, y", summary: "Confirm; protected targets need a second y", context: .signalModal, footer: "y confirm"),
        KeyBinding(keys: "n, Esc", summary: "Cancel", context: .signalModal, footer: "n cancel"),

        KeyBinding(keys: "Esc, ?, q", summary: "Close help", context: .help, footer: "Esc close"),
    ]

    public static func bindings(for context: KeyContext) -> [KeyBinding] {
        all.filter { $0.context == context }
    }

    /// Two-space-separated footer hints for a context.
    public static func footer(for context: KeyContext) -> String {
        bindings(for: context).compactMap(\.footer).joined(separator: "  ")
    }

    /// Help text lines: a heading per context, then `keys  summary`.
    public static func helpLines() -> [String] {
        var lines = [String]()
        for context in KeyContext.allCases.reversed() where !bindings(for: context).isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(context.title)
            let width = bindings(for: context).map { $0.keys.count }.max() ?? 0
            for b in bindings(for: context) {
                lines.append("  " + b.keys + String(repeating: " ", count: width - b.keys.count + 2) + b.summary)
            }
        }
        return lines
    }
}
