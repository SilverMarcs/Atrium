import Foundation

/// Apple's private simulator frameworks, which Xcode installs: CoreSimulator
/// lists and runs the simulators, SimulatorKit shows their screens. Neither
/// is linked; both load from the selected Xcode the first time a simulator
/// is needed and are reached through the Objective-C runtime.
///
/// Loading and lookup follow serve-sim (https://github.com/EvanBacon/serve-sim,
/// Apache-2.0), adapted for Atrium.
nonisolated enum SimulatorKit {
    /// Whether the frameworks loaded, which needs Xcode.
    static var isAvailable: Bool { serviceContext != nil }

    /// The selected Xcode's Developer folder, as `xcode-select -p` prints it.
    static let developerDir: String = {
        let fallback = "/Applications/Xcode.app/Contents/Developer"
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return fallback }
        process.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Command line tools alone have no simulators.
        return path.isEmpty || path.hasPrefix("/Library/Developer/CommandLineTools") ? fallback : path
    }()

    /// CoreSimulator's service for the selected Xcode, loading the frameworks once.
    private static let serviceContext: NSObject? = {
        let candidates = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(developerDir)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            // Xcode 27 moved SimulatorKit next to the Developer folder.
            "\(developerDir)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(developerDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            _ = dlopen(path, RTLD_NOW)
        }
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard contextClass.responds(to: selector) else { return nil }
        return contextClass.perform(selector, with: developerDir, with: nil)?.takeUnretainedValue() as? NSObject
    }()

    private static var deviceSet: NSObject? {
        serviceContext?.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?.takeUnretainedValue() as? NSObject
    }

    private static var simDevices: [NSObject] {
        deviceSet?.value(forKey: "devices") as? [NSObject] ?? []
    }

    /// Every simulator in Xcode's set, booted ones first, then by name.
    /// CoreSimulator can hold its lock for seconds while one shuts down, so
    /// call this off the main thread.
    static func devices() -> [SimulatorDevice] {
        simDevices.compactMap(SimulatorDevice.init(device:)).sorted {
            ($0.state == .booted ? 0 : 1, $0.family.order, $0.name, $0.runtime)
                < ($1.state == .booted ? 0 : 1, $1.family.order, $1.name, $1.runtime)
        }
    }

    /// The `SimDevice` with this UDID.
    static func simDevice(udid: String) -> NSObject? {
        simDevices.first { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid }
    }

    /// `xcrun simctl` with these arguments, for the Xcode the frameworks load from.
    static func simctlProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developerDir
        process.environment = environment
        return process
    }

    /// Runs `xcrun simctl` with these arguments and returns what it prints.
    @discardableResult
    static func simctl(_ arguments: [String], input: Data? = nil) async throws -> String {
        try await Task.detached {
            let process = simctlProcess(arguments)
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            let stdin = Pipe()
            if input != nil { process.standardInput = stdin }
            try process.run()
            if let input {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            let failure = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: failure, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SimulatorError(message.isEmpty ? "simctl \(arguments.first ?? "") failed." : message)
            }
            return String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

nonisolated struct SimulatorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A simulator as CoreSimulator lists it.
nonisolated struct SimulatorDevice: Identifiable, Hashable, Sendable {
    enum State: Int, Sendable {
        case creating, shutdown, booting, booted, shuttingDown

        var title: String {
            switch self {
            case .creating: "Creating"
            case .shutdown: "Shut Down"
            case .booting: "Booting"
            case .booted: "Booted"
            case .shuttingDown: "Shutting Down"
            }
        }
    }

    enum Family: Int, Sendable {
        case iPhone = 1, iPad = 2, tv = 3, watch = 4, vision = 7, other = 0

        var order: Int {
            switch self {
            case .iPhone: 0
            case .iPad: 1
            case .watch: 2
            case .vision: 3
            case .tv: 4
            case .other: 5
            }
        }

        var symbol: String {
            switch self {
            case .iPhone: "iphone"
            case .iPad: "ipad"
            case .tv: "appletv"
            case .watch: "applewatch"
            case .vision: "visionpro"
            case .other: "rectangle.portrait"
            }
        }
    }

    let udid: String
    let name: String
    /// Such as "iOS 27.0".
    let runtime: String
    let state: State
    let family: Family

    var id: String { udid }

    init?(device: NSObject) {
        guard let uuid = device.value(forKey: "UDID") as? NSUUID else { return nil }
        let type = device.value(forKey: "deviceType") as? NSObject
        udid = uuid.uuidString
        name = device.value(forKey: "name") as? String ?? "Simulator"
        runtime = (device.value(forKey: "runtime") as? NSObject)?.value(forKey: "name") as? String ?? ""
        state = (device.value(forKey: "state") as? NSNumber).flatMap { State(rawValue: $0.intValue) } ?? .shutdown
        family = (type?.value(forKey: "productFamilyID") as? NSNumber).flatMap { Family(rawValue: $0.intValue) } ?? .other
    }
}
