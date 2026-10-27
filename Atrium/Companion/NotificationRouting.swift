import AppKit
import CoreGraphics

/// One decision shared by Mac alerts and companion pushes: alerts go to the
/// device in the foreground that was used last, unless it's already showing the
/// task, and to every device when none is in the foreground.
///
/// Nothing is recorded per event. The Mac's last input is read from the system
/// when an alert is routed, and a companion counts as used when it comes to the
/// foreground, opens a task, or sends any request.
@MainActor
final class NotificationRouting {
    static let shared = NotificationRouting()

    private init() {}

    /// Companions in the foreground, by connection.
    private var companions: [UUID: NotificationPresence] = [:]
    var macTaskID: String?
    /// Both alert paths require current provider metadata, including for retained tasks.
    var isMainTask: (String) -> Bool = { _ in false }

    func update(_ activity: CompanionActivity, deviceID: UUID, connectionID: UUID) {
        companions[connectionID] = activity.isActive
            ? NotificationPresence(deviceID: deviceID, taskID: activity.taskID, usedAt: .now)
            : nil
    }

    /// Marks a companion in the foreground as just used.
    func used(connectionID: UUID) {
        companions[connectionID]?.usedAt = .now
    }

    func remove(connectionID: UUID) {
        companions[connectionID] = nil
    }

    func shouldNotifyMac(taskID: String) -> Bool {
        guard isMainTask(taskID) else { return false }
        guard let active = activeDevice() else { return true }
        return active.deviceID == nil && active.taskID != taskID
    }

    func shouldNotify(_ deviceID: UUID, taskID: String) -> Bool {
        guard isMainTask(taskID) else { return false }
        guard let active = activeDevice() else { return true }
        return active.deviceID == deviceID && active.taskID != taskID
    }

    private func activeDevice() -> (deviceID: UUID?, taskID: String?)? {
        let companion = companions.values.max { $0.usedAt < $1.usedAt }
        if let macUsedAt, macUsedAt >= companion?.usedAt ?? .distantPast {
            return (nil, macTaskID)
        }
        if let companion { return (companion.deviceID, companion.taskID) }
        return nil
    }

    /// When the Mac last had keyboard or pointer input, if Atrium is frontmost
    /// on an unlocked screen.
    private var macUsedAt: Date? {
        guard NSApplication.shared.isActive, !isScreenLocked,
              let anyInput = CGEventType(rawValue: ~0) else { return nil }
        return .now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Atrium stays the active app while the screen is locked.
    private var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool == true
    }
}
