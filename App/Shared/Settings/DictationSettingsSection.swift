import SwiftUI

struct DictationSettingsSection: View {
    @Environment(DictationSettings.self) private var settings
    @State private var key = ""

    var body: some View {
        Section {
            SecureField("OpenAI API key", text: $key)
                .textContentType(.password)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            Button("Save API Key") { settings.save(key) }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines) == settings.apiKey)
            if let error = settings.error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("Enables dictation in the composer using gpt-transcribe")
        }
        .onAppear { key = settings.apiKey }
    }
}
