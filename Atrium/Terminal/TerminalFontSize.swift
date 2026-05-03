import AppKit

enum TerminalFontSize {
    static let key = "terminalFontSize"
    static let defaultSize: CGFloat = NSFont.systemFontSize
    static let min: CGFloat = 8
    static let max: CGFloat = 20

    static var current: CGFloat {
        let stored = UserDefaults.standard.object(forKey: key) as? Double
        return stored.map { CGFloat($0) } ?? defaultSize
    }
}
