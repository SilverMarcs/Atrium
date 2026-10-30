import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class ComposerDictation {
    private(set) var isRecording = false {
        didSet {
            #if os(iOS)
            guard isRecording != oldValue else { return }
            UIApplication.shared.isIdleTimerDisabled = isRecording
            #endif
        }
    }
    private(set) var isBusy = false
    var error: String?
    var isActive: Bool { isRecording || isBusy }
    private(set) var sessionID = UUID()
    private var finishRecording: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var operation: Task<Void, Never>?

    func toggle(provider: any AudioTranscribing, append: @escaping @MainActor (String) -> Void) {
        guard !isBusy else { return }
        if isRecording, let recorder {
            finishRecording = nil
            let url = recorder.url
            recorder.stop()
            self.recorder = nil
            isRecording = false
            deactivateAudio()
            isBusy = true
            operation = Task {
                defer {
                    try? FileManager.default.removeItem(at: url)
                    isBusy = false
                }
                do {
                    let text = try await provider.transcribe(audio: url)
                    try Task.checkCancellation()
                    if !text.isEmpty { append(text) }
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        } else {
            error = nil
            sessionID = UUID()
            finishRecording = { [weak self] in
                self?.toggle(provider: provider, append: append)
            }
            isBusy = true
            operation = Task {
                defer { isBusy = false }
                do {
                    #if os(macOS)
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    #else
                    let allowed = await AVAudioApplication.requestRecordPermission()
                    #endif
                    guard allowed else {
                        throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in Settings to dictate."])
                    }
                    try Task.checkCancellation()
                    #if os(iOS)
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .default)
                    try session.setActive(true)
                    #endif
                    let url = URL.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).m4a")
                    let recorder = try AVAudioRecorder(url: url, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 24_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 64_000,
                    ])
                    self.recorder = recorder
                    guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
                    isRecording = true
                } catch {
                    let wasCancelled = Task.isCancelled
                    cancel()
                    if !wasCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }

    /// Stops recording if necessary, then waits until the transcript is appended.
    /// Cancellation or a failed transcription must never send a partial draft.
    func finish(session: UUID) async -> Bool {
        guard session == sessionID else { return false }
        // Permission/recorder startup may still be in flight.
        if isBusy, let operation { await operation.value }
        guard session == sessionID, error == nil else { return false }
        if isRecording { finishRecording?() }
        if let operation { await operation.value }
        return session == sessionID && error == nil && !isActive
    }

    func cancel() {
        sessionID = UUID()
        finishRecording = nil
        operation?.cancel()
        operation = nil
        if let recorder {
            recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        recorder = nil
        isRecording = false
        deactivateAudio()
    }

    private func deactivateAudio() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
