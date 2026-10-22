import AppKit
import Foundation
import SwiftTerm

/// Retains running task and inspector terminal views across navigation.
enum TerminalProcessRegistry {
    private static var views: [UUID: (view: LocalProcessTerminalView, isTaskTerminal: Bool)] = [:]

    static let fontSizeKey = "terminalFontSize"
    static let defaultFontSize: CGFloat = NSFont.systemFontSize
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 20
    static let commandFontSize: CGFloat = 12

    static let scrollbackKey = "terminalScrollback"
    static let defaultScrollback: Int = 2000
    static let scrollbackOptions: [Int] = [1000, 2000, 3000, 4000]

    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: fontSizeKey) as? Double
            return stored.map { CGFloat($0) } ?? defaultFontSize
        }
        set {
            let clamped = min(max(newValue, minFontSize), maxFontSize)
            UserDefaults.standard.set(Double(clamped), forKey: fontSizeKey)
            applyFontSizeToTaskTerminals(clamped)
        }
    }

    static var scrollback: Int {
        let stored = UserDefaults.standard.object(forKey: scrollbackKey) as? Int
        return stored ?? defaultScrollback
    }

    static func applyFontSizeToTaskTerminals(_ size: CGFloat) {
        for entry in views.values where entry.isTaskTerminal {
            let view = entry.view
            view.font = NSFont(descriptor: view.font.fontDescriptor, size: size) ?? view.font
        }
    }

    static func view(for id: UUID) -> LocalProcessTerminalView? {
        views[id]?.view
    }

    static func register(_ view: LocalProcessTerminalView, for id: UUID, isTaskTerminal: Bool) {
        views[id] = (view, isTaskTerminal)
    }

    static func remove(for id: UUID) {
        views.removeValue(forKey: id)
    }
}
