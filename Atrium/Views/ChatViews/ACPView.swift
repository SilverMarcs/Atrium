import SwiftUI

struct ACPView: View {
    let chat: Chat

    @State private var isPreparingInitialScroll = true
    @State private var scrollAnchor = ScrollAnchor()
    @Environment(EditorPanel.self) private var panel

    private var session: ACPSession { chat.session }
    private var messages: [Message] { chat.messages }

    private var modelBinding: Binding<String> {
        Binding(
            get: { chat.model },
            set: { newModel in
                chat.model = newModel
                session.applyModel(newModel)
            }
        )
    }

    private var availableModels: [AgentModel] {
        ModelCatalog.shared.models(for: chat.provider)
    }

    private var currentModelName: String {
        if let match = availableModels.first(where: { $0.rawValue == chat.model }) {
            return match.name
        }
        return chat.model.isEmpty ? "Model" : chat.model
    }

    private var currentModelImage: String {
        availableModels.first(where: { $0.rawValue == chat.model })?.imageName
            ?? chat.provider.imageName
    }

    private var permissionModeBinding: Binding<PermissionMode> {
        Binding(
            get: { chat.permissionMode },
            set: { newMode in
                chat.permissionMode = newMode
                session.applyPermissionMode(newMode)
            }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(messages) { message in
                    MessageRow(message: message)
                        .listRowSeparator(.hidden)
                }

                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .listRowSeparator(.hidden)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.red)
                        .padding(.vertical)
                }

                Color.clear
                    .frame(height: 1)
                    .id("bottom")
                    .listRowSeparator(.hidden)
            }
            .bottomScrollAnchor(scrollAnchor, proxy: proxy)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Picker(selection: permissionModeBinding) {
                        ForEach(PermissionMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    } label: {
                        Label("Permission Mode", systemImage: "lock.shield")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .help(chat.permissionMode.description)
                }

                ToolbarItem(placement: .automatic) {
                    Picker(selection: modelBinding) {
                        ForEach(availableModels) { model in
                            Label(model.name, image: model.imageName)
                                .labelStyle(.titleAndIcon)
                                .tag(model.rawValue)
                        }
                    } label: {
                        Label(currentModelName, image: currentModelImage)
                            .labelStyle(.titleAndIcon)
                    }
                    .pickerStyle(.menu)
                    .menuOrder(.fixed)
                    .frame(maxWidth: 125)
                }
            }
            .overlay {
                if isPreparingInitialScroll {
                    ZStack {
                        Rectangle()
                            .fill(.background)
                        ProgressView()
                            .controlSize(.large)
                    }
                } else if messages.isEmpty {
                    Image(chat.provider.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .foregroundStyle(chat.provider.color.gradient)
                        .saturation(0)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    if let prompt = session.delegate.pendingPermission {
                        Divider()
                        PermissionPromptView(prompt: prompt)
                            .padding(.horizontal, 16)
                    }
                    if !chat.plan.isEmpty {
                        Divider()
                        PlanView(entries: chat.plan) {
                            chat.plan.removeAll()
                            session.plan.removeAll()
                        }
                        .padding(.horizontal, 16)
                    }
                    ACPInputArea(chat: chat)
                    .id(chat.id)
                }
            }
            .imageDropHandler(chat: chat)
            .environment(\.scrollAnchor, scrollAnchor)
            .onChange(of: messages.count) {
                guard !isPreparingInitialScroll else { return }
                scrollAnchor.scrollToBottom()
            }
            .task(id: chat.id) {
                isPreparingInitialScroll = true
                scrollAnchor.isEnabled = false
                try? await Task.sleep(for: .milliseconds(50))
                scrollAnchor.scrollToBottom(animated: false)
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                isPreparingInitialScroll = false
                scrollAnchor.isEnabled = true
            }
        }
    }
}
