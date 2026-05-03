import Foundation

/// Generates a per-shell integration plan that injects OSC 133 (FinalTerm semantic
/// prompt) sequences. Those sequences are the authoritative signal for whether a
/// foreground command is running — they don't depend on the shell's window title,
/// which programs like vim/ssh/tmux freely overwrite.
///
/// Sequences emitted by the integration:
///   - `\e]133;C;<command>\a` — command started (preexec)
///   - `\e]133;D;<exit>\a`    — command finished (precmd)
///
/// Atrium parses these in `TerminalRepresentable` via `Terminal.registerOscHandler`.
enum ShellIntegration {
    struct Plan {
        var args: [String]
        var env: [String: String]
    }

    static func plan(forShellPath shellPath: String) -> Plan {
        let basename = (shellPath as NSString).lastPathComponent
        guard let dir = supportDirectory() else { return Plan(args: [], env: [:]) }

        switch basename {
        case "zsh":
            return zshPlan(in: dir)
        case "bash":
            return bashPlan(in: dir)
        case "fish":
            return fishPlan(in: dir)
        default:
            return Plan(args: [], env: [:])
        }
    }

    // MARK: - Per-shell plans

    private static func zshPlan(in dir: URL) -> Plan {
        let zdotdir = dir.appendingPathComponent("zsh", isDirectory: true)
        ensureDirectory(zdotdir)
        write(zshrc, to: zdotdir.appendingPathComponent(".zshrc"))
        write(passthrough(name: ".zshenv"), to: zdotdir.appendingPathComponent(".zshenv"))
        write(passthrough(name: ".zprofile"), to: zdotdir.appendingPathComponent(".zprofile"))
        write(passthrough(name: ".zlogin"), to: zdotdir.appendingPathComponent(".zlogin"))
        return Plan(args: [], env: ["ZDOTDIR": zdotdir.path, "ATRIUM_SHELL_INTEGRATION": "1"])
    }

    private static func bashPlan(in dir: URL) -> Plan {
        let bashDir = dir.appendingPathComponent("bash", isDirectory: true)
        ensureDirectory(bashDir)
        let rc = bashDir.appendingPathComponent("bashrc")
        write(bashrc, to: rc)
        // bash --rcfile only honors the file for non-login interactive shells, so
        // we drop the login leading-dash convention. The wrapper script sources
        // the user's profile/rc files explicitly to compensate.
        return Plan(args: ["--rcfile", rc.path, "-i"], env: ["ATRIUM_SHELL_INTEGRATION": "1"])
    }

    private static func fishPlan(in dir: URL) -> Plan {
        let fishDir = dir.appendingPathComponent("fish", isDirectory: true)
        ensureDirectory(fishDir)
        let initFile = fishDir.appendingPathComponent("atrium.fish")
        write(fishInit, to: initFile)
        let escaped = initFile.path.replacingOccurrences(of: "'", with: "\\'")
        return Plan(
            args: ["--init-command", "source '\(escaped)'"],
            env: ["ATRIUM_SHELL_INTEGRATION": "1"]
        )
    }

    // MARK: - Filesystem

    private static func supportDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let bundleName = Bundle.main.bundleIdentifier ?? "Atrium"
        let dir = support
            .appendingPathComponent(bundleName, isDirectory: true)
            .appendingPathComponent("shell", isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    private static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func write(_ contents: String, to url: URL) {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            return
        }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func passthrough(name: String) -> String {
        """
        # Atrium shell integration: forward to the user's \(name)
        if [ -f "$HOME/\(name)" ]; then
            . "$HOME/\(name)"
        fi
        """
    }

    // MARK: - Shell snippets

    private static let zshrc = #"""
    # Atrium shell integration (OSC 133). Forwards to the user's .zshrc, then
    # installs preexec/precmd hooks that emit semantic-prompt sequences.
    if [ -f "$HOME/.zshrc" ]; then
        . "$HOME/.zshrc"
    fi

    autoload -Uz add-zsh-hook 2>/dev/null

    __atrium_preexec() {
        printf '\e]133;C;%s\a' "$1"
    }
    __atrium_precmd() {
        local exit=$?
        printf '\e]133;D;%d\a' "$exit"
    }

    if (( $+functions[add-zsh-hook] )); then
        add-zsh-hook preexec __atrium_preexec
        add-zsh-hook precmd __atrium_precmd
    fi
    """#

    /// Bash integration uses the bash-preexec pattern: a DEBUG trap fires for
    /// every command, but a sentinel ensures we only emit OSC 133;C once per
    /// prompt cycle (the first command after PROMPT_COMMAND ran).
    private static let bashrc = #"""
    # Atrium shell integration (OSC 133). Source the user's bash startup files
    # first so PATH and aliases are intact, then install the hooks.
    if [ -f /etc/profile ]; then . /etc/profile; fi
    if [ -f "$HOME/.bash_profile" ]; then
        . "$HOME/.bash_profile"
    elif [ -f "$HOME/.bash_login" ]; then
        . "$HOME/.bash_login"
    elif [ -f "$HOME/.profile" ]; then
        . "$HOME/.profile"
    fi
    if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi

    __atrium_preexec_invoke() {
        local ret=$?
        if [ "$__atrium_preexec_ran" = "1" ]; then return $ret; fi
        if [ -n "$COMP_LINE" ]; then return $ret; fi
        if [ "$BASH_COMMAND" = "$PROMPT_COMMAND" ]; then return $ret; fi
        __atrium_preexec_ran=1
        printf '\e]133;C;%s\a' "$BASH_COMMAND"
        return $ret
    }
    __atrium_precmd_invoke() {
        local ret=$?
        printf '\e]133;D;%d\a' "$ret"
        __atrium_preexec_ran=0
        return $ret
    }

    trap '__atrium_preexec_invoke' DEBUG
    case "$PROMPT_COMMAND" in
      *__atrium_precmd_invoke*) ;;
      *) PROMPT_COMMAND="__atrium_precmd_invoke${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac
    """#

    private static let fishInit = #"""
    # Atrium shell integration (OSC 133). fish_preexec/fish_postexec are
    # built-in events; no patching of prompt or traps required.
    function __atrium_preexec --on-event fish_preexec
        printf '\e]133;C;%s\a' "$argv"
    end
    function __atrium_postexec --on-event fish_postexec
        printf '\e]133;D;%d\a' $status
    end
    """#
}
