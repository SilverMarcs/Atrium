import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#endif

/// The microphone makes one recording at a time, whichever composer it's for.
/// On iOS that recording carries on while its chat is closed or the app is in
/// the background, so the task list shows where it is.
@MainActor
@Observable
final class DictationMicrophone {
    static let shared = DictationMicrophone()

    /// The dictation recording, or starting to, if any.
    fileprivate(set) var owner: ComposerDictation?

    /// Whether this dictation is the one recording.
    func isRecording(_ dictation: ComposerDictation) -> Bool {
        owner === dictation && dictation.isRecording
    }
}

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
    private var recorder: DictationAudioRecorder?
    private var operation: Task<Void, Never>?
    /// Finishes a recording that reaches `maximumDuration`.
    @ObservationIgnored private var limit: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    private var microphone: DictationMicrophone { .shared }

    /// A recording finishes on its own after this long, and is transcribed
    /// into the draft like one finished by hand.
    static let maximumDuration = Duration.seconds(4 * 60)

    /// Stops recording and transcribes what was recorded into the draft.
    private func finishAndTranscribe() {
        guard isRecording else { return }
        finishRecording?()
    }

    func toggle(
        provider: any AudioTranscribing,
        feedback: @escaping @MainActor (ComposerFeedback.Kind) -> Void,
        append: @escaping @MainActor (String) -> Void
    ) {
        guard !isBusy else { return }
        if isRecording, let recorder {
            finishRecording = nil
            let url = recorder.url
            self.recorder = nil
            isRecording = false
            do {
                try recorder.finish()
            } catch {
                recordingEnded()
                try? FileManager.default.removeItem(at: url)
                self.error = error.localizedDescription
                return
            }
            recordingEnded()
            isBusy = true
            #if os(iOS)
            // Leaving the app right after finishing still gets the transcript.
            beginBackgroundTask()
            #endif
            operation = Task {
                defer {
                    try? FileManager.default.removeItem(at: url)
                    isBusy = false
                    #if os(iOS)
                    endBackgroundTask()
                    #endif
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
            takeMicrophone()
            finishRecording = { [weak self] in
                self?.toggle(provider: provider, feedback: feedback, append: append)
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
                    // Keep media playing quietly until the recording releases
                    // the session, including playback over Bluetooth.
                    try session.setCategory(
                        .playAndRecord, mode: .default,
                        options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP]
                    )
                    // Recording otherwise suppresses the microphone-ready and
                    // Send haptics while the audio session is active.
                    try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                    try session.setActive(true)
                    observeInterruptions()
                    #endif
                    let url = URL.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).m4a")
                    let recorder = try DictationAudioRecorder(url: url)
                    self.recorder = recorder
                    try recorder.start()
                    isRecording = true
                    recordingStarted()
                    feedback(.recordingStarted)
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
            recorder.cancel()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        recorder = nil
        isRecording = false
        recordingEnded()
    }

    private func recordingStarted() {
        let session = sessionID
        limit = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumDuration)
            guard let self, !Task.isCancelled, sessionID == session else { return }
            finishAndTranscribe()
        }
    }

    private func recordingEnded() {
        limit?.cancel()
        limit = nil
        releaseMicrophone()
    }

    /// Another composer's recording ends where this one starts: one still
    /// recording is transcribed into its own draft, one still starting is
    /// dropped.
    private func takeMicrophone() {
        if let other = microphone.owner, other !== self {
            if other.isRecording { other.finishRecording?() } else { other.cancel() }
        }
        microphone.owner = self
    }

    /// Only the recording composer gives up the audio session, so another
    /// composer's cancel can't stop its recording.
    private func releaseMicrophone() {
        guard microphone.owner === self else { return }
        microphone.owner = nil
        #if os(iOS)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS)
    /// A call, Siri or another app's recording pauses the recorder; it picks
    /// up in the same file once the system says it can.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            guard let type = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: type) == .ended,
                  let options = info?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else { return }
            MainActor.assumeIsolated { self?.resumeAfterInterruption() }
        }
    }

    private func resumeAfterInterruption() {
        guard isRecording, let recorder, !recorder.isRecording else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        recorder.resume()
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Transcribe Dictation") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}
