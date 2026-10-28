import UIKit
import UniformTypeIdentifiers

/// Adapts native paste events to the same attachment decoder used on Mac.
/// UIKit inserts text results at the original selection and maintains undo.
final class ComposerPasteDelegate: NSObject, UITextPasteDelegate {
    private weak var composer: TaskComposer?

    init(composer: TaskComposer) {
        self.composer = composer
    }

    func configure(_ field: some UIView & UITextPasteConfigurationSupporting) {
        guard field.pasteDelegate !== self else { return }
        let originalTypes = field.pasteConfiguration?.acceptableTypeIdentifiers
            ?? [UTType.text.identifier, UTType.url.identifier]
        let attachmentTypes = [UTType.image.identifier, UTType.fileURL.identifier]
        field.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers:
            originalTypes + attachmentTypes.filter { !originalTypes.contains($0) }
        )
        field.pasteDelegate = self
    }

    func textPasteConfigurationSupporting(
        _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
        transform item: any UITextPasteItem
    ) {
        Task {
            do {
                guard let content = try await ComposerPasteContent.load(from: item.itemProvider) else {
                    item.setDefaultResult()
                    return
                }
                guard let composer else {
                    item.setNoResult()
                    return
                }
                switch content {
                case .text(let text):
                    item.setResult(string: text)
                case .image(let image):
                    try composer.attachPastedImage(image)
                    item.setNoResult()
                }
            } catch {
                composer?.pasteError = error.localizedDescription
                item.setNoResult()
            }
        }
    }
}
