/// Sending owns its progress indicator; finishing dictation on its own
/// shows progress in the dictation button instead.
nonisolated enum ComposerDictationButtonState {
    case ready, recording, transcribing

    init(isRecording: Bool, isBusy: Bool, isSending: Bool) {
        if isSending { self = .ready }
        else if isBusy { self = .transcribing }
        else if isRecording { self = .recording }
        else { self = .ready }
    }
}
