import AVFoundation
import Foundation

@main
enum DictationAudioRecorderChecks {
    struct Failure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func makeInputFormat(channels: AVAudioChannelCount, sampleRate: Double) throws -> AVAudioFormat {
        if channels > 2 {
            guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else {
                throw Failure(message: "Could not create discrete layout for \(channels) channels")
            }
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: false,
                channelLayout: layout
            )
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw Failure(message: "Could not create format for \(channels) ch @ \(sampleRate) Hz")
        }
        return format
    }

    static func makeToneBuffers(
        format: AVAudioFormat,
        activeChannels: [Int],
        count: Int = 8,
        chunkFrames: AVAudioFrameCount = 1024
    ) throws -> [AVAudioPCMBuffer] {
        var phase = 0.0
        let phaseStep = 2.0 * .pi * 440.0 / format.sampleRate
        let channels = Int(format.channelCount)
        var buffers: [AVAudioPCMBuffer] = []
        buffers.reserveCapacity(count)
        for _ in 0..<count {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
                  let channelData = buffer.floatChannelData else {
                throw Failure(message: "Could not allocate input buffer")
            }
            buffer.frameLength = chunkFrames
            for frame in 0..<Int(chunkFrames) {
                let sample = Float(sin(phase)) * 0.5
                phase += phaseStep
                for channel in 0..<channels {
                    channelData[channel][frame] = activeChannels.contains(channel) ? sample : 0
                }
            }
            buffers.append(buffer)
        }
        return buffers
    }

    static func decodeAndVerify(url: URL, expectedMinPeak: Float, label: String) throws {
        let reader = try AVAudioFile(forReading: url)
        try check(reader.fileFormat.channelCount == 1, "Output must be mono for \(label)")
        try check(reader.fileFormat.sampleRate == 24_000, "Output must be 24kHz for \(label)")
        try check(reader.length > 0, "Output must contain frames for \(label)")

        guard let decoded = AVAudioPCMBuffer(
            pcmFormat: reader.processingFormat,
            frameCapacity: AVAudioFrameCount(reader.length)
        ) else {
            throw Failure(message: "Could not allocate decode buffer for \(label)")
        }
        try reader.read(into: decoded)
        guard let samples = decoded.floatChannelData?[0] else {
            throw Failure(message: "Missing decoded samples for \(label)")
        }
        var peak: Float = 0
        for i in 0..<Int(decoded.frameLength) {
            peak = max(peak, abs(samples[i]))
        }
        try check(
            peak >= expectedMinPeak,
            "Expected audible output (peak >= \(expectedMinPeak), got \(peak)) for \(label)"
        )
    }

    static func verifyFormat(
        channels: AVAudioChannelCount,
        sampleRate: Double,
        activeChannels: [Int],
        expectedMinPeak: Float
    ) throws {
        let format = try makeInputFormat(channels: channels, sampleRate: sampleRate)
        let url = URL.temporaryDirectory.appending(path: "dictation-check-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try DictationAudioWriter(
            url: url,
            inputFormat: format,
            settings: DictationAudioRecorder.recordingSettings
        )
        for buffer in try makeToneBuffers(format: format, activeChannels: activeChannels) {
            try writer.write(buffer)
        }
        // Verify finish() explicitly closes and finalizes the file before deinit.
        try writer.finish()

        try decodeAndVerify(
            url: url,
            expectedMinPeak: expectedMinPeak,
            label: "\(channels)ch/\(sampleRate)Hz active=\(activeChannels)"
        )
    }

    static func verifyFormatSwitch(
        from initial: (channels: AVAudioChannelCount, sampleRate: Double),
        to next: (channels: AVAudioChannelCount, sampleRate: Double)
    ) throws {
        let firstFormat = try makeInputFormat(channels: initial.channels, sampleRate: initial.sampleRate)
        let secondFormat = try makeInputFormat(channels: next.channels, sampleRate: next.sampleRate)
        let url = URL.temporaryDirectory.appending(path: "dictation-switch-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try DictationAudioWriter(
            url: url,
            inputFormat: firstFormat,
            settings: DictationAudioRecorder.recordingSettings
        )
        for buffer in try makeToneBuffers(format: firstFormat, activeChannels: Array(0..<Int(initial.channels)), count: 4) {
            try writer.write(buffer)
        }
        for buffer in try makeToneBuffers(format: secondFormat, activeChannels: Array(0..<Int(next.channels)), count: 4) {
            try writer.write(buffer)
        }
        try writer.finish()

        try decodeAndVerify(
            url: url,
            expectedMinPeak: 0.25,
            label: "switch \(initial.channels)ch/\(initial.sampleRate)Hz -> \(next.channels)ch/\(next.sampleRate)Hz"
        )
    }

    static func main() throws {
        for sampleRate in [8_000.0, 16_000.0, 24_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for channels: AVAudioChannelCount in [1, 2, 3, 4, 9] {
                try verifyFormat(
                    channels: channels,
                    sampleRate: sampleRate,
                    activeChannels: Array(0..<Int(channels)),
                    expectedMinPeak: 0.25
                )
            }
        }
        // Stereo interface with microphone plugged into input 2 only.
        try verifyFormat(channels: 2, sampleRate: 48_000, activeChannels: [1], expectedMinPeak: 0.1)
        // 4-channel discrete voice processing with only a single active channel.
        try verifyFormat(channels: 4, sampleRate: 48_000, activeChannels: [0], expectedMinPeak: 0.05)
        try verifyFormat(channels: 4, sampleRate: 48_000, activeChannels: [3], expectedMinPeak: 0.05)
        // Mid-stream hardware/Bluetooth format changes (e.g., A2DP -> HFP).
        try verifyFormatSwitch(from: (4, 48_000), to: (1, 16_000))
        try verifyFormatSwitch(from: (1, 24_000), to: (2, 48_000))

        // Verify real macOS voice processing engine initialization when an audio input exists.
        let probeEngine = AVAudioEngine()
        if probeEngine.inputNode.outputFormat(forBus: 0).channelCount > 0 {
            let liveURL = URL.temporaryDirectory.appending(path: "dictation-live-check-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: liveURL) }
            let recorder = try DictationAudioRecorder(url: liveURL)
            try recorder.finish()
        }

        print("Dictation audio recorder checks passed")
    }
}
