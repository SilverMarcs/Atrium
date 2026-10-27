import Foundation
import ImageIO
import Intents
import UniformTypeIdentifiers
import UserNotifications

/// Adds Apple's native communication avatar without rebuilding notification content.
nonisolated enum ProjectNotificationContent {
    nonisolated(nonsending) static func updating(
        content: UNNotificationContent,
        title: String,
        imageData: Data,
        conversationID: String
    ) async throws -> UNNotificationContent {
        // Bound decoded dimensions as well as the compressed PNG size.
        guard !imageData.isEmpty, imageData.count <= 64 * 1024,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1024).contains(width), (1...1024).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) != nil,
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()

        let sender = INPerson(
            personHandle: INPersonHandle(value: conversationID, type: .unknown),
            nameComponents: nil,
            displayName: title,
            image: INImage(imageData: imageData),
            contactIdentifier: nil,
            customIdentifier: conversationID
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            // Communication notifications derive their subtitle from the group name.
            speakableGroupName: content.subtitle.isEmpty ? nil : INSpeakableString(spokenPhrase: content.subtitle),
            conversationIdentifier: conversationID,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try await interaction.donate()
        try Task.checkCancellation()

        // Pass the system's result through unchanged to retain its communication metadata.
        return try content.updating(from: intent)
    }
}
