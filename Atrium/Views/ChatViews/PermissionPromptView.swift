import SwiftUI

struct PermissionPromptView: View {
    let prompt: PermissionPrompt

    var body: some View {
        VStack(spacing: 8) {
            Text(prompt.toolName)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(prompt.options, id: \.id) { option in
                    let isAllow = option.isAllowed
                    Button {
                        prompt.respond(optionId: option.id)
                    } label: {
                        Text(option.name)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(isAllow ? .accentColor : .secondary)
                }

                Spacer()

                Button("Dismiss") {
                    prompt.respond(optionId: nil)
                }
                .controlSize(.small)
            }
        }
    }
}
