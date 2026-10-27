import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("editorWrapLines") private var editorWrapLines = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(TerminalProcessRegistry.fontSizeKey) private var terminalFontSize: Double = Double(TerminalProcessRegistry.defaultFontSize)
    @AppStorage(TerminalProcessRegistry.scrollbackKey) private var terminalScrollback: Int = TerminalProcessRegistry.defaultScrollback
    @AppStorage(EditorFontSize.key) private var editorFontSize: Double = EditorFontSize.default
    @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { terminalFontSize },
                                set: { terminalFontSize = (($0 * 2).rounded()) / 2 }
                            ),
                            in: Double(TerminalProcessRegistry.minFontSize)...Double(TerminalProcessRegistry.maxFontSize)
                        )
                        Text(terminalFontSize, format: .number.precision(.fractionLength(1)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 25, alignment: .trailing)
                    }
                } label: {
                    Text("Font size")
                    Text("Applies to the main AI terminals")
                }

                Picker(selection: $terminalScrollback) {
                    ForEach(TerminalProcessRegistry.scrollbackOptions, id: \.self) { value in
                        Text("\(value, format: .number.grouping(.never)) lines").tag(value)
                    }
                } label: {
                    Text("Scrollback")
                    Text("How many lines of history each terminal keeps")
                }
            } header: {
                Text("Terminal")
            }
            .onChange(of: terminalFontSize) { _, newValue in
                TerminalProcessRegistry.applyFontSizeToTaskTerminals(CGFloat(newValue))
            }

            Section("Chat") {
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

            Section {
                LabeledContent {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { editorFontSize },
                                set: { editorFontSize = (($0 * 2).rounded()) / 2 }
                            ),
                            in: EditorFontSize.min...EditorFontSize.max
                        )
                        Text(String(format: "%.1f", editorFontSize))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 25, alignment: .trailing)
                    }
                } label: {
                    Text("Font size")
                }

                Toggle("Wrap long lines", isOn: $editorWrapLines)
            } header: {
                Text("Editor")
            }

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

#Preview {
    GeneralSettingsView()
}
