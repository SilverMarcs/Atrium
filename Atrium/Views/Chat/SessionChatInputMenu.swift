import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Attaches images to the prompt from Photos or from files.
struct SessionChatInputMenu: View {
  let composer: TaskComposer
  @State private var showPhotosPicker = false
  @State private var showFileImporter = false
  @State private var selectedPhotos: [PhotosPickerItem] = []

  var body: some View {
    Menu {
      Button("Photos Library", systemImage: "photo.on.rectangle.angled") { showPhotosPicker = true }
      Divider()
      Button("Attach Images", systemImage: "paperclip") { showFileImporter = true }
    } label: {
      Label("Attachments", systemImage: "plus.circle.fill")
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary, .clear)
        .font(.largeTitle)
        .glassEffect()
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(composer.remainingImageSlots == 0)
    .photosPicker(
      isPresented: $showPhotosPicker,
      selection: $selectedPhotos,
      maxSelectionCount: max(composer.remainingImageSlots, 1),
      matching: .images
    )
    .onChange(of: selectedPhotos) { _, items in
      guard !items.isEmpty else { return }
      selectedPhotos = []
      Task { await composer.attach(items) }
    }
    .fileImporter(
      isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        Task { await composer.attach(contentsOf: urls) }
      case .failure(let error):
        composer.attachmentError = error.localizedDescription
      }
    }
  }
}
