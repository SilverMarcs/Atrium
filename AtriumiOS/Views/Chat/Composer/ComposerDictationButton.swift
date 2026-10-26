import SwiftUI

struct ComposerDictationButton: View {
    var isInline = false
    @ScaledMetric(relativeTo: .body) private var symbolSize = 20
    @Environment(DictationSettings.self) private var settings
    @Environment(TaskComposer.self) private var composer

    private var idleColor: Color { .secondary }

    var body: some View {
        if settings.isEnabled {
            Button {
                composer.dictation.toggle(provider: OpenAITranscriber(apiKey: settings.apiKey)) { text in
                    composer.appendTranscription(text)
                }
            } label: {
                Group {
                    if composer.dictation.isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Label(composer.dictation.isRecording ? "Finish Dictation" : "Dictate", systemImage: "waveform")
                            .labelStyle(.iconOnly)
                            .imageScale(.small)
                    }
                }
                .frame(width: symbolSize, height: symbolSize)
                .foregroundStyle(composer.dictation.isRecording ? Color.accentColor : idleColor)
                .frame(width: isInline ? 44 : nil)
                .padding(.vertical, isInline ? 8 : 0)
                .contentShape(.rect)
            }
            // Native toolbar buttons use tint; the label style also covers
            // the plain button inside the iPad composer.
            .tint(composer.dictation.isRecording ? Color.accentColor : idleColor)
            .disabled(composer.dictation.isBusy || composer.isSubmittingDictation)
            .accessibilityLabel(composer.dictation.isBusy ? "Transcribing" : composer.dictation.isRecording ? "Finish Dictation" : "Dictate")
            .accessibilityValue(composer.dictation.isRecording ? "Recording" : composer.dictation.isBusy ? "Processing" : "Ready")
        }
    }
}
