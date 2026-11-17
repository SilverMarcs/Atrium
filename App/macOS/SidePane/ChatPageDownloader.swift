import SwiftUI

/// Saves a page as HTML or as a picture straight into Downloads, where a
/// browser would.
@MainActor
@Observable
final class ChatPageDownloader {
    /// The format just saved, shown with a checkmark for a moment.
    private(set) var savedFormat: ChatPageExport.Format?
    var exportError: String?

    func download(_ format: ChatPageExport.Format, of model: ChatPageModel, title: String) {
        Task {
            do {
                _ = try await model.export(format, title: title).saveToDownloads()
                savedFormat = format
                try? await Task.sleep(for: .seconds(2))
                if savedFormat == format { savedFormat = nil }
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}
