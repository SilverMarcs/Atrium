import SwiftUI

/// Replaces the search icon, hides the clear button, and keeps body text and
/// typing suggestions suitable for composing messages.
/// UIKit refreshes the search field during toolbar and focus transitions, so
/// enforce its styling synchronously instead of waiting for a SwiftUI update.
final class ComposerSearchFieldStyle: UIView {
    private weak var textField: UISearchTextField?
    private let trailingSpacer = UIView(frame: .zero)
    private var observations: [NSKeyValueObservation] = []
    private var isApplyingStyle = false

    init(textField: UISearchTextField) {
        self.textField = textField
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        trailingSpacer.isUserInteractionEnabled = false
        textField.adjustsFontForContentSizeCategory = true
        let updateStyle: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.applyStyle()
            }
        }
        observations = [
            textField.observe(\.font) { _, _ in updateStyle() },
            textField.observe(\.defaultTextAttributes) { _, _ in updateStyle() },
            textField.observe(\.attributedText) { _, _ in updateStyle() },
            textField.observe(\.attributedPlaceholder) { _, _ in updateStyle() },
            textField.observe(\.clearButtonMode) { _, _ in updateStyle() },
            textField.observe(\.rightView) { _, _ in updateStyle() },
            textField.observe(\.rightViewMode) { _, _ in updateStyle() },
            textField.observe(\.autocorrectionType) { _, _ in updateStyle() }
        ]
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) {
            (view: ComposerSearchFieldStyle, _: UITraitCollection) in
            view.applyStyle()
        }
        applyStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func applyStyle() {
        guard !isApplyingStyle, let textField else { return }
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: textField.traitCollection)
        isApplyingStyle = true
        defer { isApplyingStyle = false }
        if textField.clearButtonMode != .never {
            textField.clearButtonMode = .never
        }
        // Without a trailing view, UISearchTextField extends its editing rect
        // to the edge when the clear button is hidden. An empty overlay keeps
        // UIKit's native trailing inset for both the text and the caret.
        if textField.rightView !== trailingSpacer {
            textField.rightView = trailingSpacer
        }
        if textField.rightViewMode != .always {
            textField.rightViewMode = .always
        }
        // SwiftUI's toolbar search field is a separate clone and can restore
        // the search default of `.no` after the environment is applied.
        if textField.autocorrectionType != .yes {
            textField.autocorrectionType = .yes
            if textField.isFirstResponder {
                textField.reloadInputViews()
            }
        }
        if textField.font != font {
            textField.font = font
        }
        // UIKit can replace the placeholder's attributes without changing `font`.
        if let placeholder = textField.attributedPlaceholder, placeholder.length > 0,
           placeholder.attribute(.font, at: 0, effectiveRange: nil) as? UIFont != font {
            let styledPlaceholder = NSMutableAttributedString(attributedString: placeholder)
            styledPlaceholder.addAttribute(.font, value: font, range: NSRange(location: 0, length: placeholder.length))
            textField.attributedPlaceholder = styledPlaceholder
        }
    }
}
