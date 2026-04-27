import AppKit
import Foundation
import SwiftTerm

/// Owns the live `LocalProcessTerminalView` for each terminal tab.
///
/// Keying the views off `Terminal.id` in a static registry decouples shell
/// process lifetime from the lifetime of any individual `Terminal` instance.
enum TerminalProcessRegistry {
    private static var views: [UUID: LocalProcessTerminalView] = [:]

    static let fontSizeKey = "terminalFontSize"
    static let defaultFontSize: CGFloat = NSFont.systemFontSize
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 20

    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: fontSizeKey) as? Double
            return stored.map { CGFloat($0) } ?? defaultFontSize
        }
        set {
            let clamped = min(max(newValue, minFontSize), maxFontSize)
            UserDefaults.standard.set(Double(clamped), forKey: fontSizeKey)
            applyFontSizeToAll(clamped)
        }
    }

    static func applyFontSizeToAll(_ size: CGFloat) {
        for view in views.values {
            view.font = NSFont(descriptor: view.font.fontDescriptor, size: size) ?? view.font
        }
    }

    static func view(for id: UUID) -> LocalProcessTerminalView? {
        views[id]
    }

    static func register(_ view: LocalProcessTerminalView, for id: UUID) {
        views[id] = view
    }

    static func remove(for id: UUID) {
        views.removeValue(forKey: id)
    }
}
