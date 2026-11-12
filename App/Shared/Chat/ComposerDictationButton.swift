import SwiftUI

/// Dictates into the composer, shown once an OpenAI key is saved in
/// Settings: inside the prompt field when inline, or as a toolbar button.
struct ComposerDictationButton: View {
    let composer: TaskComposer
    var isInline = false
    /// The waveform's scale, which the iPhone composer enlarges to match
    /// the toolbar buttons it replaced.
    var symbolScale: Image.Scale = .small
    @Environment(DictationSettings.self) private var settings

    #if os(macOS)
    private static let inlineWidth: CGFloat = 36
    #else
    /// A comfortable touch target beside the field's text.
    private static let inlineWidth: CGFloat = 44
    #endif

    private var color: Color { composer.dictation.isRecording ? .accentColor : .secondary }

    var body: some View {
        if settings.isEnabled {
            Button {
                composer.toggleDictation(using: settings)
            } label: {
                if isInline {
                    // The field's own line height, so this control can't make a
                    // one-line composer taller, including while busy.
                    Text("M")
                        .hidden()
                        .accessibilityHidden(true)
                        .overlay { DictationSymbol(dictation: composer.dictation, scale: symbolScale) }
                        .frame(width: Self.inlineWidth)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                } else {
                    DictationSymbol(dictation: composer.dictation, scale: symbolScale)
                }
            }
            .foregroundStyle(color)
            // Toolbar buttons take their color from the tint.
            .tint(color)
            .disabled(composer.dictation.isBusy || composer.isSubmittingDictation)
            .accessibilityLabel(composer.dictation.isBusy ? "Transcribing" : composer.dictation.isRecording ? "Finish Dictation" : "Dictate")
            .accessibilityValue(composer.dictation.isRecording ? "Recording" : composer.dictation.isBusy ? "Processing" : "Ready")
            .help(composer.dictation.isRecording ? "Finish dictation and transcribe" : "Dictate a message")
        }
    }
}

/// A waveform, or a spinner while the recording is transcribed.
private struct DictationSymbol: View {
    let dictation: ComposerDictation
    let scale: Image.Scale
    @ScaledMetric(relativeTo: .body) private var size = 20

    var body: some View {
        Group {
            if dictation.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(dictation.isRecording ? "Finish Dictation" : "Dictate", systemImage: "waveform")
                    .labelStyle(.iconOnly)
                    .imageScale(scale)
                    // The waveform ripples while it listens.
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: dictation.isRecording)
            }
        }
        .frame(width: size, height: size)
    }
}
