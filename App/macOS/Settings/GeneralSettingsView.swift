import AppKit
import AtriumHost
import AtriumProtocol
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("editorWrapLines") private var editorWrapLines = true
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
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }

            Section {
                SendModePicker(showsSubtitle: false)
                TaskRowHostLabelPicker(title: "Host indicator", showsSubtitle: false)
                Picker("Swipe snooze duration", selection: $settings.defaultSnooze) {
                    ForEach(SnoozeDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
            }

            Section("Editor") {
                Toggle("Wrap long lines", isOn: $editorWrapLines)
                DiffLayoutPicker()
            }

            DictationSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .toolbar {
            if chatFontSize != ChatFontSize.default {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset Font Size", systemImage: "arrow.counterclockwise") {
                        chatFontSize = ChatFontSize.default
                    }
                    .help("Reset chat font size to default")
                }
            } else {
                ToolbarHeightPlaceholder()
            }
        }
    }
}
