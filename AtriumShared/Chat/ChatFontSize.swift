/// The desktop chat size uses the existing Markdown preference, so saved sizes
/// continue to apply to replies, prompt bubbles, and the composer together.
nonisolated enum ChatFontSize {
    static let key = "fontSize"
    static let `default`: Double = 13
    static let min: Double = 9
    static let max: Double = 24
    static let step: Double = 0.5
}
