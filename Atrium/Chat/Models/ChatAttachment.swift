import Foundation
import AppKit
import UniformTypeIdentifiers

struct ChatAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let data: Data
    let mimeType: String
    let fileName: String

    init(id: UUID = UUID(), data: Data, mimeType: String, fileName: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }

}
