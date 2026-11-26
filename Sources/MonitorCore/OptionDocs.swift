/// Shell completions and the man page, generated from `Options.specs` so the
/// documented interface cannot drift from the parsed one.
public enum OptionDocs {
    private static var visible: [OptionSpec] { Options.specs.filter { !$0.hidden } }

    public static func completions(shell: String) -> String? {
        switch shell {
        case "zsh": zsh()
        case "bash": bash()
        case "fish": fish()
        default: nil
        }
    }

    // MARK: zsh

    private static func zsh() -> String {
        var lines = ["#compdef rtop", "", "_arguments -s \\"]
        for spec in visible {
            let summary = quoteZsh(spec.summary)
            var line = "  '\(spec.name)"
            if spec.valueName != nil {
                line += "=[\(summary)]:\(spec.valueName ?? ""):"
                if spec.choices.isEmpty {
                    line += spec.name == "--config" ? "_files" : " "
                } else {
                    line += "(\(spec.choices.joined(separator: " ")))"
                }
                line += "'"
            } else {
                line += "[\(summary)]'"
            }
            lines.append(line + " \\")
        }
        lines[lines.count - 1] = String(lines[lines.count - 1].dropLast(2))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoteZsh(_ text: String) -> String {
        text.replacing("'", with: "'\\''").replacing("[", with: "(").replacing("]", with: ")")
    }

    // MARK: bash

    private static func bash() -> String {
        var cases = ""
        for spec in visible where spec.valueName != nil {
            if !spec.choices.isEmpty {
                cases += "        \(spec.name)) COMPREPLY=($(compgen -W \"\(spec.choices.joined(separator: " "))\" -- \"$cur\")); return ;;\n"
            } else if spec.name == "--config" {
                cases += "        --config) COMPREPLY=($(compgen -f -- \"$cur\")); return ;;\n"
            } else {
                cases += "        \(spec.name)) return ;;\n"
            }
        }
        let words = visible.map(\.name).joined(separator: " ")
        return """
            _rtop() {
                local cur prev
                cur="${COMP_WORDS[COMP_CWORD]}"
                prev="${COMP_WORDS[COMP_CWORD-1]}"
                case "$prev" in
            \(cases)    esac
                COMPREPLY=($(compgen -W "\(words)" -- "$cur"))
            }
            complete -F _rtop rtop

            """
    }

    // MARK: fish

    private static func fish() -> String {
        var out = ""
        for spec in visible {
            var line = "complete -c rtop -l \(spec.name.dropFirst(2))"
            if spec.valueName != nil {
                if !spec.choices.isEmpty {
                    line += " -x -a '\(spec.choices.joined(separator: " "))'"
                } else {
                    line += spec.name == "--config" ? " -r -F" : " -r"
                }
            }
            line += " -d '\(spec.summary.replacing("'", with: "\\'"))'"
            out += line + "\n"
        }
        return out
    }

    // MARK: man page

    /// `date` is the page date, e.g. "2026-11-26".
    public static func manPage(version: String, date: String) -> String {
        var out = """
            .TH RTOP 1 "\(date)" "rtop \(version)" "User Commands"
            .SH NAME
            rtop \\- terminal system monitor for macOS
            .SH SYNOPSIS
            .B rtop
            [\\fIoptions\\fR]
            .SH DESCRIPTION
            .B rtop
            shows processes, CPU, memory, swap, and memory pressure in the terminal.
            It needs a terminal on both standard input and standard output.
            Values the operating system does not reveal are shown as a dash, never as zero.
            Press \\fB?\\fR for the key bindings.
            .SH OPTIONS

            """
        for spec in visible {
            let value = spec.valueName.map { " \\fI\($0)\\fR" } ?? ""
            out += ".TP\n.B \(spec.name)\(value)\n\(escapeRoff(spec.summary))"
            if !spec.choices.isEmpty { out += " Values: \(spec.choices.joined(separator: ", "))." }
            out += "\n"
        }
        out += """
            .SH CONFIGURATION
            Settings are read from
            .I ~/Library/Application Support/rtop/config.json
            unless
            .B \\-\\-config
            names another file. Command-line options override the file, and the file overrides the defaults.
            A missing default file is normal; an invalid default file produces a warning and defaults.
            A missing or invalid explicit file is an error. Keys: refreshMs, sort, descending, theme, color,
            normalizeCpu, historySamples, mouse.
            .SH ENVIRONMENT
            .TP
            .B NO_COLOR
            A non-empty value disables color.
            .TP
            .B TERM
            An empty or "dumb" value disables color.
            .SH FILES
            .TP
            .I ~/Library/Logs/rtop/rtop.log
            Diagnostic log (owner-only, size-rotated). It never contains command lines or environment.
            .SH EXIT STATUS
            0 normal exit; 1 startup or runtime failure; 2 invalid options or configuration.
            .SH SEE ALSO
            top(1), ps(1), vm_stat(1), stty(1), reset(1)

            """
        return out
    }

    private static func escapeRoff(_ text: String) -> String {
        text.replacing("\\", with: "\\\\").replacing("-", with: "\\-")
    }
}
