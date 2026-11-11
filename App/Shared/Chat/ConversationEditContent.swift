import SwiftUI

/// Original attachments and submission errors shown with the edit draft.
struct ConversationEditContent: View {
    let edit: ConversationMessageEdit

    var body: some View {
        if !edit.images.isEmpty || edit.errorMessage != nil {
            VStack(alignment: .leading) {
                if !edit.images.isEmpty {
                    HStack {
                        ForEach(edit.images.enumerated(), id: \.offset) { _, data in
                            PromptImageThumbnail(data: data)
                        }
                    }
                }
                if let error = edit.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
    }
}
