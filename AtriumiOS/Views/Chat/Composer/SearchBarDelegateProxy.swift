import UIKit

/// Answers the Close button itself and forwards every other delegate call to
/// the search bar's original (SwiftUI-owned) delegate.
final class SearchBarDelegateProxy: NSObject, UISearchBarDelegate {
    weak var originalDelegate: UISearchBarDelegate?
    var cancelButtonClicked: ((UISearchBar) -> Void)?

    init(originalDelegate: UISearchBarDelegate?) {
        self.originalDelegate = originalDelegate
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(searchBarCancelButtonClicked(_:)) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        originalDelegate
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        if let cancelButtonClicked {
            cancelButtonClicked(searchBar)
        } else {
            originalDelegate?.searchBarCancelButtonClicked?(searchBar)
        }
    }
}
