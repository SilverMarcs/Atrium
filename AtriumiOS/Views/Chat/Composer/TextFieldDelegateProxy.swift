import UIKit

/// Answers Return itself and forwards every other delegate call to the field's
/// original (SwiftUI-owned) delegate.
final class TextFieldDelegateProxy: NSObject, UITextFieldDelegate {
    weak var originalDelegate: UITextFieldDelegate?
    var shouldReturn: ((UITextField) -> Bool)?

    init(originalDelegate: UITextFieldDelegate?) {
        self.originalDelegate = originalDelegate
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(textFieldShouldReturn(_:)) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        originalDelegate
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let shouldReturn {
            return shouldReturn(textField)
        }
        return originalDelegate?.textFieldShouldReturn?(textField) ?? true
    }
}
