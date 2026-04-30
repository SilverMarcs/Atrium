import BackgroundTasks
import Foundation
import UserNotifications
import os

/// Keeps the iOS process alive while a chat the user just sent a prompt to is
/// processing. Submits an iOS 26 `BGContinuedProcessingTask` per `sendPrompt`
/// so the system renders a Live Activity in the Dynamic Island and the
/// existing `NWConnection` to the Mac doesn't get torn down the moment the
/// user backgrounds the app. The task ends as soon as the matching session's
/// `isProcessing` flips back to `false` — or the system expires us, in which
/// case the Live Activity disappears and the user has to reopen the app to
/// resync.
///
/// Constraints worth remembering:
///  - Apple requires submission to be a result of a person's action;
///    `sendPrompt` qualifies. Do NOT call `begin(...)` from system-driven
///    paths (auto-reconnect, sessionsList diff, etc.).
///  - The system terminates tasks reporting "minimal or no progress." Claude
///    often thinks silently between tool calls, so we bump the progress unit
///    count on every `sessionUpdate` patch — even a no-op patch counts as
///    "we're still alive."
@MainActor
final class LiveSessionTracker {
    static let shared = LiveSessionTracker()

    /// Bundle-scoped identifier. Must appear in the
    /// `BGTaskSchedulerPermittedIdentifiers` array in `Info.plist`.
    static let taskIdentifier = "com.SilverMarcs.Atrium.session.live"

    private static let logger = Logger(
        subsystem: "com.SilverMarcs.Atrium",
        category: "LiveSessionTracker"
    )

    private struct Active {
        let sessionId: UUID
        let workspaceId: UUID
        let task: BGContinuedProcessingTask
    }

    private var active: Active?
    /// Submitted-but-not-yet-started request. Cleared when the system grants
    /// us runtime via the registered launch handler — or overwritten by a
    /// later `begin(...)` call (rare: requires two prompts within the
    /// scheduling window).
    private var pendingSessionId: UUID?
    private var pendingWorkspaceId: UUID?
    private var pendingTitle: String?
    private var pendingSubtitle: String?
    /// Records the most-recent successful completion so the local
    /// "finished" notification can dedup against it — the Live Activity
    /// dismissing already showed the user the chat is done.
    private var lastSuccessfulCompletion: (sessionId: UUID, at: Date)?
    /// Window during which a completed Live Activity suppresses the matching
    /// "finished" local notification. Generous so a `sessionsList` push
    /// debounced behind the BG task's completion still hits the dedup.
    private static let completionDedupWindow: TimeInterval = 10

    private init() {}

    /// Register the BG task launch handler. Must be called before
    /// `applicationDidFinishLaunching` returns — the natural place is the
    /// app's `init()`. Apple kills the app on a second registration of the
    /// same identifier, so guard accordingly.
    static func registerHandler() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                shared.handle(task: task)
            }
        }
    }

    /// Submit a continued-processing task tied to the chat the user just
    /// prompted. No-op if a task is already active for this session — the
    /// existing one keeps running across the new prompt's response, which is
    /// what we want.
    func begin(sessionId: UUID, workspaceId: UUID, title: String, subtitle: String = "Working…") {
        if active?.sessionId == sessionId { return }
        // Switching sessions: end the prior task so iOS will schedule a new
        // one. We only ever run one continued-processing task at a time —
        // simpler accounting and the user only watches one chat at a time
        // in practice.
        endActive(success: true)

        pendingSessionId = sessionId
        pendingWorkspaceId = workspaceId
        pendingTitle = title
        pendingSubtitle = subtitle

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: title.isEmpty ? "Atrium" : title,
            subtitle: subtitle
        )
        // Fail-fast rather than queue: if iOS can't schedule the task right
        // now, the chat will likely be done by the time it would start, and
        // we'd be showing a Live Activity for an already-finished response.
        request.strategy = .fail

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.logger.error(
                "BGTaskScheduler.submit failed: \(error.localizedDescription, privacy: .public)"
            )
            pendingSessionId = nil
            pendingWorkspaceId = nil
            pendingTitle = nil
            pendingSubtitle = nil
        }
    }

    /// Heartbeat from `sessionUpdate` patches (rich, frequent, only arrives
    /// while the user is subscribed to the tracked chat). Bumps progress so
    /// the system doesn't terminate us as stalled, refreshes the subtitle,
    /// and ends the task when the chat finishes.
    func observe(sessionId: UUID, isProcessing: Bool, subtitle: String?) {
        guard let active, active.sessionId == sessionId else { return }

        bumpProgress()

        if let subtitle, !subtitle.isEmpty {
            active.task.updateTitle(active.task.title, subtitle: subtitle)
        }

        if !isProcessing {
            endActive(success: true)
        }
    }

    /// Heartbeat from `sessionsList` — fires regardless of which chat is
    /// subscribed, so the BG task survives the user navigating away from
    /// the chat detail screen (which drops the per-session subscription).
    /// Sparser than `sessionUpdate` (debounced metadata-only), but for
    /// active streaming the tool-call / turnCount changes generate enough
    /// pushes to count as alive.
    func observeSessionList(_ workspaces: [WireWorkspace]) {
        guard let active else { return }
        guard let session = workspaces.lazy
            .flatMap({ $0.sessions })
            .first(where: { $0.id == active.sessionId }) else {
            // Chat was deleted on the Mac. Surrender now rather than wait
            // for the next sessionUpdate that's never coming.
            endActive(success: false)
            return
        }
        bumpProgress()
        if !session.isProcessing {
            endActive(success: true)
        }
    }

    private func bumpProgress() {
        guard let active else { return }
        let task = active.task
        let next = task.progress.completedUnitCount + 1
        // Stay short of `totalUnitCount` until isProcessing actually flips —
        // when we'd otherwise hit 100%, grow the total so the ring keeps
        // animating instead of pinning at full for a multi-tool turn.
        if next >= task.progress.totalUnitCount {
            task.progress.totalUnitCount += 50
        }
        task.progress.completedUnitCount = next
    }

    /// Surrender runtime now rather than waiting for the next sessionUpdate.
    /// Wire to `stopChat`, `disconnectChat`, `deleteChat`, full disconnect.
    func cancel(sessionId: UUID) {
        guard active?.sessionId == sessionId else { return }
        endActive(success: false)
    }

    /// Tear down whatever's active — used on full disconnect / socket loss.
    func cancelAll() {
        endActive(success: false)
    }

    private func handle(task: BGContinuedProcessingTask) {
        guard let sessionId = pendingSessionId,
              let workspaceId = pendingWorkspaceId else {
            // Stale — chat already finished before iOS scheduled us.
            task.setTaskCompleted(success: true)
            return
        }
        active = Active(sessionId: sessionId, workspaceId: workspaceId, task: task)
        pendingSessionId = nil
        pendingWorkspaceId = nil
        pendingTitle = nil
        pendingSubtitle = nil

        // Determinate-but-fake progress. We don't actually know how done
        // the chat is, but the system terminates tasks reporting "minimal
        // or no progress" under resource pressure, so a steadily-bumping
        // counter keeps us in good standing. The ring filling up is
        // somewhat-honest motion — the chat is making turns, even if we
        // can't quantify them.
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            // System decided we've used too much background time. The chat
            // may genuinely still be running on the Mac; post a follow-up
            // local notification so the user has a tangible "tap to check
            // on this" handle rather than just watching the LA vanish.
            Task { @MainActor in self?.endActiveDueToExpiration() }
        }
    }

    private func endActive(success: Bool) {
        guard let active else { return }
        if success {
            active.task.progress.completedUnitCount = active.task.progress.totalUnitCount
            lastSuccessfulCompletion = (active.sessionId, Date())
        }
        active.task.setTaskCompleted(success: success)
        self.active = nil
    }

    private func endActiveDueToExpiration() {
        guard let active else { return }
        postBackgroundedNotification(for: active)
        active.task.setTaskCompleted(success: false)
        self.active = nil
    }

    private func postBackgroundedNotification(for active: Active) {
        let content = UNMutableNotificationContent()
        // Use the LA's title as the notification title so the user sees the
        // same "<workspace> · <chat>" string they were watching in the
        // Dynamic Island a moment ago.
        content.title = active.task.title
        content.body = "Still working in the background"
        content.sound = .default
        content.userInfo = [
            "workspaceId": active.workspaceId.uuidString,
            "sessionId": active.sessionId.uuidString
        ]
        // Matches `CompanionClient.postFinishedNotification`'s identifier
        // pattern — when the chat eventually finishes and that path runs,
        // it overwrites this notification with a "<chat> finished
        // responding" instead of stacking two banners.
        let request = UNNotificationRequest(
            identifier: "companion.finished.\(active.sessionId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Returns true if the Live Activity for this session just dismissed
    /// successfully. Used by `CompanionClient` to skip posting a redundant
    /// "finished" local notification when the user already saw the
    /// Dynamic Island disappear. The flag is consumed (cleared) on read so
    /// only the immediately-following sessionsList diff dedups.
    func consumeRecentCompletion(sessionId: UUID) -> Bool {
        guard let last = lastSuccessfulCompletion,
              last.sessionId == sessionId,
              Date().timeIntervalSince(last.at) <= Self.completionDedupWindow
        else { return false }
        lastSuccessfulCompletion = nil
        return true
    }
}
