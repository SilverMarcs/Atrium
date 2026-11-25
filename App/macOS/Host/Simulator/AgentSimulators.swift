import Foundation
import Observation

/// The simulator each chat on this Mac shows, by task ID, which its agent
/// opens with `simulator_open` or the user picks in the inspector. A chat
/// only points at a simulator: closing the chat or taking the simulator out
/// of it never shuts the simulator down, since agents and tools such as
/// `agent-sim` hand simulators out and take them back themselves.
@MainActor
@Observable
final class AgentSimulators {
    /// The simulators Xcode has, as last listed.
    private(set) var devices: [SimulatorDevice] = []
    /// Whether Xcode's simulator frameworks loaded, once listed.
    private(set) var isAvailable = true
    private(set) var shown: [String: String] = [:]
    /// Chats whose agent has used their simulator in its current turn.
    private(set) var agentUsing: Set<String> = []
    @ObservationIgnored private var sessions: [String: SimulatorSession] = [:]
    @ObservationIgnored private var turnEnds: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var listing: Task<Void, Never>?
    /// A chat's agent showed a simulator, by task ID, for the window to show it.
    @ObservationIgnored var onOpen: ((String) -> Void)?

    /// The simulator a chat shows.
    func session(for taskID: String) -> SimulatorSession? {
        shown[taskID].flatMap(session(udid:))
    }

    /// The session for a simulator, starting one when none is open.
    func session(udid: String) -> SimulatorSession? {
        if let session = sessions[udid] { return session }
        guard let session = SimulatorSession(udid: udid) else { return nil }
        releaseUnused()
        sessions[udid] = session
        return session
    }

    /// Shows a simulator in a chat; an agent showing one brings the
    /// inspector's Simulator tab forward.
    @discardableResult
    func show(_ udid: String, in taskID: String, byAgent: Bool = false) -> SimulatorSession? {
        guard let session = session(udid: udid) else { return nil }
        let changed = shown[taskID] != udid
        shown[taskID] = udid
        if changed { releaseUnused() }
        if byAgent {
            noteAgentUse(by: taskID)
            onOpen?(taskID)
        }
        return session
    }

    /// Takes the chat's simulator out of it, leaving the simulator running.
    func close(_ taskID: String) {
        guard shown.removeValue(forKey: taskID) != nil else { return }
        agentUsing.remove(taskID)
        releaseUnused()
    }

    /// Sessions no chat shows, no agent has used for a while and nothing
    /// records go, checked whenever a session starts or a chat lets one go.
    private func releaseUnused() {
        let used = Set(shown.values)
        let recent = Date.now.addingTimeInterval(-10 * 60)
        for (udid, session) in sessions where !used.contains(udid) && session.lastAgentUse < recent && !session.isRecording {
            sessions[udid] = nil
        }
    }

    // MARK: - Listing

    /// Lists Xcode's simulators again, off the main thread: CoreSimulator can
    /// hold its lock for seconds while one shuts down.
    func refreshDevices() async {
        if let listing { return await listing.value }
        let task = Task {
            let found = await Task.detached { (SimulatorKit.isAvailable, SimulatorKit.devices()) }.value
            isAvailable = found.0
            if found.1 != devices { devices = found.1 }
            listing = nil
        }
        listing = task
        await task.value
    }

    // MARK: - Agent use

    /// The chat's agent used its simulator: it stays marked for the rest of its turn.
    func noteAgentUse(by taskID: String) {
        turnEnds[taskID]?.cancel()
        agentUsing.insert(taskID)
    }

    /// A chat's agent started or stopped working, which ends its mark.
    func observe(_ thread: AgentThread) {
        let taskID = thread.id
        turnEnds[taskID]?.cancel()
        guard !thread.status.isWorking, agentUsing.contains(taskID) else { return }
        turnEnds[taskID] = Task { [weak self] in
            guard (try? await Task.sleep(for: AgentBrowsers.turnEndGrace)) != nil else { return }
            self?.agentUsing.remove(taskID)
        }
    }
}
