import SwiftUI

struct QuickPanelSettingsView: View {
    @AppStorage("quickPanelProvider") private var quickPanelProvider: AgentProvider = .claude
    @AppStorage("quickPanelModel") private var quickPanelModel: String = ""

    private let catalog = ModelCatalog.shared

    var body: some View {
        Form {
            Section("Defaults") {
                Picker(selection: $quickPanelProvider) {
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        Label(provider.rawValue, image: provider.imageName)
                            .tag(provider)
                    }
                } label: {
                    Text("Provider")
                    Text("Used by the ⌃Space quick panel")
                }
                .onChange(of: quickPanelProvider) { _, newValue in
                    let models = catalog.models(for: newValue)
                    if !models.contains(where: { $0.rawValue == quickPanelModel }) {
                        quickPanelModel = models.first?.rawValue ?? ""
                    }
                }

                Picker(selection: $quickPanelModel) {
                    let models = catalog.models(for: quickPanelProvider)
                    if models.isEmpty {
                        Text("No models loaded").tag("")
                    } else {
                        ForEach(models) { model in
                            Text(model.name).tag(model.rawValue)
                        }
                    }
                } label: {
                    Text("Model")
                }
                .disabled(catalog.models(for: quickPanelProvider).isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    QuickPanelSettingsView()
}
