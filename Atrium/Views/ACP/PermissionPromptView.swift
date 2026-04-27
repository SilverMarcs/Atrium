import SwiftUI
import ACPModel

struct PermissionPromptView: View {
    let prompt: PermissionPrompt

    var body: some View {
        VStack(spacing: 8) {
            Text(prompt.toolName)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(prompt.options, id: \.optionId) { option in
                    let isAllow = option.kind == "allow_always" || option.kind == "allow_once"
                    Button {
                        prompt.respond(optionId: option.optionId)
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
