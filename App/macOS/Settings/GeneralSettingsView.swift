import AppKit
import AtriumProtocol
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("editorWrapLines") private var editorWrapLines = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default

    var body: some View {
        @Bindable var settings = app.integrationSettings
        Form {
            Section {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $chatFontSize, in: ChatFontSize.min...ChatFontSize.max, step: ChatFontSize.step)
                        Text(chatFontSize, format: .number.precision(.fractionLength(1)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 25, alignment: .trailing)
                    }
                }
            }

            SendModeSettingsSection()

            Section {
                Picker(selection: $settings.defaultSnooze) {
                    ForEach(SnoozeDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                } label: {
                    Text("Snooze for")
                    Text("When you swipe to snooze a task")
                }
            }

            Section {
                Toggle("Wrap long lines", isOn: $editorWrapLines)
                DiffLayoutPicker()
            } header: {
                Text("Editor")
            }

            DictationSettingsSection()

            #if DEBUG
            Section {
                LabeledContent("Reset Onboarding") {
                    Button("Launch") {
                        hasCompletedOnboarding = false
                    }
                }
            } header: {
                Text("Debug")
            } footer: {
                Text("Resets the onboarding flag so the welcome sheet appears again on next launch.")
            }
            #endif
        }
        .formStyle(.grouped)
    }
}
