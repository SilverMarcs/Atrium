import SwiftUI

/// Relay's inline dictation control, shown inside the prompt field once an
/// OpenAI key is saved in Settings.
struct SessionChatDictationButton: View {
  let composer: ComposerDraft
  @ScaledMetric(relativeTo: .body) private var symbolSize = 20
  @Environment(DictationSettings.self) private var settings

  var body: some View {
    if settings.isEnabled {
      Button {
        composer.toggleDictation(using: settings)
      } label: {
        // Use the field's natural line height so this control cannot
        // make the single-line composer taller, including while busy.
        Text("M")
          .hidden()
          .accessibilityHidden(true)
          .overlay {
            Group {
              if composer.dictation.isBusy {
                ProgressView()
                  .progressViewStyle(.circular)
                  .controlSize(.small)
              } else {
                Label(composer.dictation.isRecording ? "Finish Dictation" : "Dictate", systemImage: "waveform")
                  .labelStyle(.iconOnly)
                  .imageScale(.small)
              }
            }
          }
          .frame(width: symbolSize)
          .foregroundStyle(composer.dictation.isRecording ? Color.accentColor : .secondary)
          .frame(width: 44)
          .padding(.vertical, 8)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(composer.dictation.isBusy || composer.isSubmittingDictation)
      .accessibilityLabel(composer.dictation.isBusy ? "Transcribing" : composer.dictation.isRecording ? "Finish Dictation" : "Dictate")
      .accessibilityValue(composer.dictation.isRecording ? "Recording" : composer.dictation.isBusy ? "Processing" : "Ready")
      .help(composer.dictation.isRecording ? "Finish dictation and transcribe" : "Dictate a message")
    }
  }
}
