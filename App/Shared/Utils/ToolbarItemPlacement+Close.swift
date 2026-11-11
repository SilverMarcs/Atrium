import SwiftUI

extension ToolbarItemPlacement {
    /// Where a sheet's close button goes: with Escape on Mac, top trailing on iPhone and iPad.
    static var close: Self {
        #if os(macOS)
        .cancellationAction
        #else
        .topBarTrailing
        #endif
    }
}
