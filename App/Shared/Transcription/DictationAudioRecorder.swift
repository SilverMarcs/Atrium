import AVFoundation
#if os(macOS)
import Synchronization
#endif

/// Encodes dictation recordings to a compact mono AAC file.
/// On macOS, voice processing provides system audio ducking while capturing
/// the microphone, and tapped buffers are downmixed and resampled to the target
/// format because voice processing can expose 4+ discrete channels.
@MainActor
final class DictationAudioRecorder {
    nonisolated static var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
    }

    let url: URL

    #if os(macOS)
    private let engine = AVAudioEngine()
    private let output: Output
    private var hasTap = false

    private nonisolated final class Output: Sendable {
        /// Serialized by `state`'s mutex; `write(_:)` does not retain tap buffers.
        struct State: @unchecked Sendable {
            var writer: DictationAudioWriter?
            var error: (any Error)?
        }
        let state: Mutex<State>

        init(url: URL, inputFormat: AVAudioFormat, settings: [String: Any]) throws {
            let writer = try DictationAudioWriter(url: url, inputFormat: inputFormat, settings: settings)
            state = Mutex(State(writer: writer))
        }

        /// Must stay `nonisolated`: `AVAudioNodeTapBlock` is non-`@Sendable`
        /// and runs off the main thread, so forming the closure on `@MainActor`
        /// would trap under `MainActor` default isolation.
        func makeTapBlock() -> AVAudioNodeTapBlock {
            { buffer, _ in
                self.state.withLock { state in
                    guard state.error == nil else { return }
                    do { try state.writer?.write(buffer) }
                    catch { state.error = error }
                }
            }
        }

        func finish() -> (any Error)? {
            state.withLock { state in
                if state.error == nil {
                    do { try state.writer?.finish() }
                    catch { state.error = error }
                }
                state.writer = nil
                return state.error
            }
        }
    }

    init(url: URL, settings: [String: Any] = DictationAudioRecorder.recordingSettings) throws {
        self.url = url
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false,
            duckingLevel: .mid
        )
        let format = input.outputFormat(forBus: 0)
        output = try Output(url: url, inputFormat: format, settings: settings)
    }

    func start() throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: output.makeTapBlock())
        hasTap = true
        engine.prepare()
        try engine.start()
        guard engine.isRunning else { throw CocoaError(.fileWriteUnknown) }
    }

    func finish() throws {
        if let error = tearDown() { throw error }
    }

    func cancel() {
        _ = tearDown()
    }

    private func tearDown() -> (any Error)? {
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        // Flush resampler tail and close the encoded file before transcription opens it.
        let error = output.finish()
        engine.reset()
        return error
    }
    #else
    private let recorder: AVAudioRecorder

    var isRecording: Bool { recorder.isRecording }

    init(url: URL, settings: [String: Any] = DictationAudioRecorder.recordingSettings) throws {
        self.url = url
        self.recorder = try AVAudioRecorder(url: url, settings: settings)
    }

    func start() throws {
        guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
    }

    func finish() throws {
        recorder.stop()
    }

    func cancel() {
        recorder.stop()
    }

    func resume() {
        recorder.record()
    }
    #endif
}

#if os(macOS)
/// Downmixes and resamples tapped microphone buffers into the target audio file.
/// macOS voice processing can expose 4+ discrete channels at the device's native
/// sample rate, which AAC rejects at speech bitrates if passed straight through.
nonisolated final class DictationAudioWriter {
    private let file: AVAudioFile
    private var inputFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var isClosed = false

    init(url: URL, inputFormat: AVAudioFormat, settings: [String: Any]) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "Dictation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No audio input device is available."]
            )
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        var initialized = false
        defer {
            if !initialized {
                file.close()
                try? FileManager.default.removeItem(at: url)
            }
        }
        self.file = file
        try configurePipeline(for: inputFormat)
        initialized = true
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard !isClosed, buffer.frameLength > 0 else { return }
        if buffer.format != inputFormat {
            try flushConverter()
            try configurePipeline(for: buffer.format)
        }
        let source = try mixToMonoIfNeeded(buffer)
        guard let converter else {
            try file.write(from: source)
            return
        }
        let ratio = file.processingFormat.sampleRate / source.format.sampleRate
        let capacity = max(AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 64, 1024)
        var pending: AVAudioPCMBuffer? = source
        try convert(using: converter, capacity: capacity) { _, outStatus in
            if let next = pending {
                pending = nil
                outStatus.pointee = .haveData
                return next
            }
            outStatus.pointee = .noDataNow
            return nil
        }
    }

    func finish() throws {
        guard !isClosed else { return }
        isClosed = true
        defer {
            converter = nil
            file.close()
        }
        try flushConverter()
    }

    private func configurePipeline(for format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let outputFormat = file.processingFormat
        let needsMonoMix = outputFormat.channelCount == 1
            && format.channelCount > 1
            && format.commonFormat == .pcmFormatFloat32
            && !format.isInterleaved

        let converterInputFormat: AVAudioFormat
        if needsMonoMix {
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            monoFormat = mono
            converterInputFormat = mono
        } else {
            monoFormat = nil
            converterInputFormat = format
        }

        if converterInputFormat == outputFormat {
            converter = nil
        } else {
            guard let created = AVAudioConverter(from: converterInputFormat, to: outputFormat) else {
                throw CocoaError(.fileWriteUnknown)
            }
            converter = created
        }
        inputFormat = format
    }

    private func flushConverter() throws {
        guard let converter else { return }
        try convert(using: converter, capacity: 1024) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
    }

    private func mixToMonoIfNeeded(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let monoFormat else { return buffer }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0,
              let sourceChannels = buffer.floatChannelData,
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = monoBuffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        monoBuffer.frameLength = buffer.frameLength
        let scale = 1.0 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += sourceChannels[channel][frame]
            }
            destination[frame] = sum * scale
        }
        return monoBuffer
    }

    private func convert(
        using converter: AVAudioConverter,
        capacity: AVAudioFrameCount,
        input: AVAudioConverterInputBlock
    ) throws {
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw CocoaError(.fileWriteUnknown)
        }
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: input)
            if status == .error {
                throw conversionError ?? CocoaError(.fileWriteUnknown)
            }
            if outputBuffer.frameLength > 0 {
                try file.write(from: outputBuffer)
            }
            if status != .haveData || outputBuffer.frameLength == 0 {
                break
            }
        }
    }
}
#endif
