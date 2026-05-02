import SwiftUI

struct ACPView: View {
    let chat: Chat

    @State private var isPreparingInitialScroll = true
    @State private var isAtBottom = true
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
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let maxOffset = geometry.contentSize.height - geometry.containerSize.height
                return geometry.contentOffset.y >= maxOffset - 2
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onChange(of: panel.isOpen) {
                guard !isPreparingInitialScroll, isAtBottom else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
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
                }
            }
            .imageDropHandler(chat: chat)
            .onChange(of: messages.count) {
                guard !isPreparingInitialScroll else { return }
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .task(id: chat.id) {
                isPreparingInitialScroll = true
                try? await Task.sleep(for: .milliseconds(50))
                proxy.scrollTo("bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                isPreparingInitialScroll = false
            }
        }
    }
}
