import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SessionChatInputMenu: View {
  @Binding var images: [ComposerImage]
  @State private var showPhotosPicker = false
  @State private var showFileImporter = false
  @State private var selectedPhotos: [PhotosPickerItem] = []
  @State private var selectedFiles: [URL] = []
  @State private var importError: String?

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
    .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPhotos, matching: .images)
    .task(id: selectedPhotos) {
      for item in selectedPhotos {
        do {
          try checkImageLimit()
          guard let data = try await item.loadTransferable(type: Data.self) else {
            throw IntegrationError(message: "This image could not be read.")
          }
          let image = await ComposerImage.prepare(data)
          try Task.checkCancellation()
          try appendImage(image)
        } catch is CancellationError {
          return
        } catch { importError = error.localizedDescription }
      }
      selectedPhotos = []
    }
    .fileImporter(
      isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true
    ) { result in
      do {
        selectedFiles = try result.get()
      } catch { importError = error.localizedDescription }
    }
    .task(id: selectedFiles) {
      do {
        for url in selectedFiles {
          try checkImageLimit()
          let image = try await ComposerImage.prepare(contentsOf: url)
          try Task.checkCancellation()
          try appendImage(image)
        }
      } catch is CancellationError {
        return
      } catch { importError = error.localizedDescription }
      selectedFiles = []
    }
    .alert(
      "Couldn’t Attach Image",
      isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    ) {
      Button("OK") { importError = nil }
    } message: {
      Text(importError ?? "")
    }
  }

  private func checkImageLimit() throws {
    guard images.count < TaskComposer.maxImages else {
      throw IntegrationError(message: "Attach up to \(TaskComposer.maxImages) images at a time.")
    }
  }

  private func appendImage(_ image: ComposerImage?) throws {
    try checkImageLimit()
    guard let image else {
      throw IntegrationError(message: "This image could not be read.")
    }
    images.append(image)
  }
}
