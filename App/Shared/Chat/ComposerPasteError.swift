import Foundation

nonisolated enum ComposerPasteError: LocalizedError {
    case unreadableImage
    case unreadableItem
    case textFileTooLarge
    case imageLimit(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "This image could not be read."
        case .unreadableItem: "This attachment could not be read."
        case .textFileTooLarge: "Text files must be 10 MB or smaller."
        case .imageLimit(let limit): "Attach up to \(limit) images at a time."
        }
    }
}
