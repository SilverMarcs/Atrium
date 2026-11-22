import AVFoundation
#if os(macOS)
import Synchronization

/// Voice processing provides system audio ducking on macOS while capturing
/// the microphone. The engine and tap live only for the recording's duration.
@MainActor
final class DictationAudioRecorder {
    let url: URL
    private let engine = AVAudioEngine()
    private let output: Output
    private var hasTap = false

    private final class Output: Sendable {
        struct State {
            var file: AVAudioFile?
            var error: (any Error)?
        }
        let state: Mutex<State>

        init(file: AVAudioFile) {
            state = Mutex(State(file: file))
        }
    }

    var recordingError: (any Error)? { output.state.withLock { $0.error } }

    init(url: URL, settings: [String: Any]) throws {
        self.url = url
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false,
            duckingLevel: .mid
        )
        let format = input.outputFormat(forBus: 0)
        // Keep the microphone's native sample rate for the tap and encoder.
        var settings = settings
        settings[AVSampleRateKey] = format.sampleRate
        settings[AVNumberOfChannelsKey] = Int(format.channelCount)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        output = Output(file: file)
    }

    func record() throws -> Bool {
        let output = output
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            output.state.withLock { state in
                guard state.error == nil else { return }
                do { try state.file?.write(from: buffer) }
                catch { state.error = error }
            }
        }
        hasTap = true
        engine.prepare()
        try engine.start()
        return engine.isRunning
    }

    func stop() {
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        // Finalize the encoded file before transcription opens it.
        output.state.withLock { $0.file = nil }
    }
}
#else
typealias DictationAudioRecorder = AVAudioRecorder
#endif
