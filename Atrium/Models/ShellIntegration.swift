import Foundation

/// Writes zsh init files into a private ZDOTDIR so the spawned shell will
/// install `preexec`/`precmd` hooks that emit OSC 2 (window title) sequences.
/// SwiftTerm surfaces those as `setTerminalTitle`, which we use to drive
/// `Terminal.foregroundProcessName` instantly — no polling, no pid scans.
enum ShellIntegration {
    /// Returns the path to use as `ZDOTDIR` for spawned zsh sessions, ensuring
    /// the integration files exist on disk first. Returns nil if the support
    /// directory can't be created.
    static func zdotdir() -> String? {
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
            .appendingPathComponent("zsh", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        write(zshrc, to: dir.appendingPathComponent(".zshrc"))
        write(passthrough(name: ".zshenv"), to: dir.appendingPathComponent(".zshenv"))
        write(passthrough(name: ".zprofile"), to: dir.appendingPathComponent(".zprofile"))
        write(passthrough(name: ".zlogin"), to: dir.appendingPathComponent(".zlogin"))

        return dir.path
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

    /// `\e]2;<command>\a` sets the window title to `<command>`. The shell sends
    /// the running command on `preexec` and clears it on `precmd`, which lands
    /// in `LocalProcessTerminalViewDelegate.setTerminalTitle`.
    private static let zshrc = #"""
    # Atrium shell integration: forward to the user's .zshrc, then install hooks.
    if [ -f "$HOME/.zshrc" ]; then
        . "$HOME/.zshrc"
    fi

    autoload -Uz add-zsh-hook 2>/dev/null

    __atrium_preexec() {
        printf '\e]2;%s\a' "$1"
    }
    __atrium_precmd() {
        printf '\e]2;\a'
    }

    if (( $+functions[add-zsh-hook] )); then
        add-zsh-hook preexec __atrium_preexec
        add-zsh-hook precmd __atrium_precmd
    fi
    """#
}
