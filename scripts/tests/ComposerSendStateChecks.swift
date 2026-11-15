import Foundation

@main
enum ComposerSendStateChecks {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func main() throws {
        try check(ComposerSendState(isBusy: false, offersStop: false) == .send, "Idle composer offers Send")
        try check(ComposerSendState(isBusy: true, offersStop: false) == .sending, "Dictation, edits and delivery show progress")
        try check(ComposerSendState(isBusy: true, offersStop: true) == .sending, "A pending send must finish before offering Stop")
        try check(ComposerSendState(isBusy: false, offersStop: true) == .stop, "The same action becomes Stop once sending finishes")
        try check(ComposerDictationButtonState(isRecording: false, isBusy: false, isSending: false) == .ready, "Idle dictation is ready")
        try check(ComposerDictationButtonState(isRecording: true, isBusy: false, isSending: false) == .recording, "Active dictation animates")
        try check(ComposerDictationButtonState(isRecording: false, isBusy: true, isSending: false) == .transcribing, "Manual stop shows dictation progress")
        try check(ComposerDictationButtonState(isRecording: false, isBusy: true, isSending: true) == .ready, "Dictate to Send leaves progress to Send")
        try check(ComposerDictationButtonState(isRecording: true, isBusy: false, isSending: true) == .ready, "Sending immediately resets the dictation symbol")
        print("Composer send and dictation state checks passed")
    }
}
