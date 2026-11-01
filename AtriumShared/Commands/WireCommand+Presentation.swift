import AtriumProtocol

extension WireCommand {
    /// How the latest run is going, for a subtitle.
    var status: String? {
        if isRunning { return "Running" }
        guard let exitCode else { return nil }
        return exitCode == 0 ? "Finished" : "Exited with code \(exitCode)"
    }
}
