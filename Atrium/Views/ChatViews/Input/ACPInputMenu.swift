import SwiftUI
import PhotosUI
import ACPModel

struct ACPInputMenu: View {
    @Bindable var chat: Chat
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    private var commands: [AvailableCommand] { chat.session.availableCommands }

    var body: some View {
        Menu {
            if !commands.isEmpty {
                Menu {
                    ForEach(commands, id: \.name) { command in
                        Button {
                            chat.prompt += ("/\(command.name)")
                        } label: {
                            Text("/\(command.name)")
                        }
                    }
                } label: {
                    Label("Commands", systemImage: "command")
                }

                Divider()
            }

            Button {
                showPhotosPicker = true
            } label: {
                Label("Photos Library", systemImage: "photo.on.rectangle.angled")
            }

            Button {
                showFileImporter = true
            } label: {
                Label("Attach Images", systemImage: "paperclip")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary, .clear)
                .font(.largeTitle).fontWeight(.semibold)
                .glassEffect()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $selectedPhotos,
            matching: .images
        )
        .task(id: selectedPhotos) {
            await loadSelectedPhotos()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    if let attachment = AttachmentLoader.load(url: url) {
                        chat.pendingAttachments.append(attachment)
                    }
                }
            }
        }
    }

    private func loadSelectedPhotos() async {
        guard !selectedPhotos.isEmpty else { return }
        for item in selectedPhotos {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .image
            let ext = type.preferredFilenameExtension ?? "img"
            let name = "photo_\(UUID().uuidString.prefix(8)).\(ext)"
            if let attachment = AttachmentLoader.make(data: data, type: type, fileName: name) {
                await MainActor.run {
                    chat.pendingAttachments.append(attachment)
                }
            }
        }
        await MainActor.run { selectedPhotos.removeAll() }
    }
}
