import AppIntents

/// The Live Activity's Finish button: stops the recording and transcribes it
/// into its chat's draft. The system runs it in the app, which is recording.
struct FinishDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish Dictation"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        DictationMicrophone.shared.finishRecording()
        #endif
        return .result()
    }
}
