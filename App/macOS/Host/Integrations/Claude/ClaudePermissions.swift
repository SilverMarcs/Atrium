import AtriumProtocol
import Foundation

/// How Atrium's permission modes map to Claude's `--permission-mode`, and
/// what a background job's saved launch options say about its mode.
nonisolated enum ClaudePermissions {
    /// Lets a session switch to bypassing permissions later, which Claude
    /// otherwise allows only to a session launched bypassing them.
    static let allowBypassFlag = "--allow-dangerously-skip-permissions"
    private static let modeFlag = "--permission-mode"
    /// Shift+Tab steps through at most this many modes before coming back around.
    static let cycleLength = 6

    static func value(for mode: PermissionMode) -> String {
        switch mode {
        case .supervised: "default"
        case .acceptEdits: "acceptEdits"
        case .auto: "auto"
        case .fullAccess: "bypassPermissions"
        }
    }

    /// Nil for Claude's modes Atrium doesn't offer, such as plan mode.
    static func mode(_ value: String?) -> PermissionMode? {
        switch value {
        case "default", "manual": .supervised
        case "acceptEdits": .acceptEdits
        case "auto": .auto
        case "bypassPermissions": .fullAccess
        default: nil
        }
    }

    /// The mode a job's options launch it in, which Claude also saves there when Shift+Tab changes it.
    static func launchedMode(_ options: [String]) -> PermissionMode? {
        var value: String?
        for (index, option) in options.enumerated() {
            if option == modeFlag, options.indices.contains(index + 1) { value = options[index + 1] }
            else if option.hasPrefix(modeFlag + "=") { value = String(option.dropFirst(modeFlag.count + 1)) }
        }
        return mode(value)
    }

    /// Whether a job launched with these options can switch to bypassing permissions.
    static func canBypass(_ options: [String]) -> Bool {
        options.contains(allowBypassFlag) || options.contains("--dangerously-skip-permissions") || launchedMode(options) == .fullAccess
    }

    /// The options that relaunch a job in a mode, able to bypass permissions later.
    static func options(_ options: [String], launchingIn mode: PermissionMode) -> [String] {
        var kept: [String] = []
        var skipsValue = false
        for option in options {
            if skipsValue { skipsValue = false; continue }
            if option == modeFlag { skipsValue = true; continue }
            if option.hasPrefix(modeFlag + "=") || option == allowBypassFlag { continue }
            kept.append(option)
        }
        return kept + [modeFlag, value(for: mode), allowBypassFlag]
    }
}
