import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("hideSettingsButton") private var hideSettingsButton = false
    @AppStorage("editorWrapLines") private var editorWrapLines = true
    @AppStorage(EditorFontSize.key) private var editorFontSize: Double = EditorFontSize.default
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("sidebarRowSize") private var sidebarRowSize: SidebarRowSizePreference = .medium
    @AppStorage("editorPanelSidebarBehavior") private var editorPanelSidebarBehavior: EditorPanelSidebarBehavior = .default
    @AppStorage(TerminalProcessRegistry.fontSizeKey) private var terminalFontSize: Double = Double(TerminalProcessRegistry.defaultFontSize)

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Hide settings button from sidebar", isOn: $hideSettingsButton)
                // Picker("Sidebar row size", selection: $sidebarRowSize) {
                    // ForEach(SidebarRowSizePreference.allCases) { size in
                        // Text(size.displayName).tag(size)
                    // }
                // }
                Picker("When editor panel opens", selection: $editorPanelSidebarBehavior) {
                    ForEach(EditorPanelSidebarBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            }

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
                        Text(String(format: "%.1f", terminalFontSize))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 25, alignment: .trailing)
                    }
                } label: {
                    Text("Font size")
                }
            } header: {
                Text("Terminal")
            }
            .onChange(of: terminalFontSize) { _, newValue in
                TerminalProcessRegistry.applyFontSizeToAll(CGFloat(newValue))
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
