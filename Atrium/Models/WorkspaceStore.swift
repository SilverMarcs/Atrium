import Foundation
import Observation
import SwiftUI

/// Persists `Workspace` objects (and their `Terminal` / `CommandEntry`
/// children) to a JSON file in `~/Library/Application Support/Atrium/TaskWorkspace/`.
///
/// Adding or deleting workspaces schedules a save. Property edits made
/// through `Bindable(workspace).name` etc. are
/// caught by an `withObservationTracking` walk that re-arms after every
/// detected change.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Saves are gated until a successful load. If the file is missing we set
    /// this to `true` immediately (an empty store is a valid initial state);
    /// if the file exists but fails to decode we move it aside and start
    /// fresh — but never silently overwrite the user's data without rescuing
    /// it first.
    @ObservationIgnored private var didLoad = false

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appending(path: "Atrium/TaskWorkspace", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("workspaces.json")

        load()
        beginObservingChanges()
    }

    // MARK: - Load / Save

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            didLoad = true
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(StorePayload.self, from: data)
            for ws in payload.workspaces { ws.store = self }
            workspaces = payload.workspaces
            didLoad = true
        } catch {
            // Move the unreadable file aside so the user can recover it
            // manually, then start with an empty store.
            print("WorkspaceStore: failed to decode \(fileURL.lastPathComponent): \(error)")
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.appendingPathExtension("corrupt-\(stamp)")
            try? fm.moveItem(at: fileURL, to: backup)
            didLoad = true
        }
    }

    func save() {
        guard didLoad else { return }
        do {
            let payload = StorePayload(version: 1, workspaces: workspaces)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("WorkspaceStore: failed to write \(fileURL.lastPathComponent): \(error)")
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            self?.save()
        }
    }

    // MARK: - Observation

    private func beginObservingChanges() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            // Touch every observable field that can be edited via Bindable
            // bindings (TextFields, menus). Insertions and removals go
            // through the explicit CRUD methods below and don't need to be
            // observed here.
            for ws in self.workspaces {
                _ = ws.name
                _ = ws.directory
                _ = ws.projectTypeRaw
                _ = ws.scratchPad
                _ = ws.isArchived
                _ = ws.customIconFilename
                for cmd in ws.commands {
                    _ = cmd.title
                    _ = cmd.runScript
                    _ = cmd.isDefault
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleSave()
                self.beginObservingChanges()
            }
        }
    }

    // MARK: - Lookup

    /// The project a task belongs to. A task that relocated into a linked worktree
    /// stays with the project of its original folder, or of the worktree's main checkout.
    func workspace(for thread: AgentThread) -> Workspace? {
        for directory in [thread.projectDirectory, thread.directory].compactMap(\.self) {
            let url = URL(fileURLWithPath: directory)
            if let workspace = workspace(at: url) { return workspace }
            if let checkout = GitCheckout(containing: url), checkout.linkedWorktreeURL != nil,
               let workspace = workspace(at: checkout.mainCheckoutURL) {
                return workspace
            }
        }
        return nil
    }

    /// The folder a project for a task without one should open: never a linked worktree,
    /// which would otherwise appear as a separate project lacking the real one's commands.
    static func projectDirectory(for thread: AgentThread) -> String {
        let directory = thread.projectDirectory ?? thread.directory
        guard let checkout = GitCheckout(containing: URL(fileURLWithPath: directory)),
              checkout.linkedWorktreeURL != nil else { return directory }
        return Self.path(of: checkout.mainCheckoutURL)
    }

    private func workspace(at url: URL) -> Workspace? {
        let path = Self.path(of: url)
        return workspaces.first { Self.path(of: $0.url) == path }
    }

    /// Directory URLs may or may not carry a trailing slash; compare paths without it.
    private static func path(of url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - CRUD

    func addWorkspace(_ workspace: Workspace) {
        workspace.store = self
        workspaces.insert(workspace, at: 0)
        scheduleSave()
    }

    func moveWorkspaces(from source: IndexSet, to destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func deleteWorkspace(_ workspace: Workspace) {
        for cmd in workspace.commands {
            cmd.terminate()
        }
        workspace.clearCustomIcon()
        workspaces.removeAll { $0.id == workspace.id }
        scheduleSave()
    }
}

private struct StorePayload: Codable {
    let version: Int
    let workspaces: [Workspace]
}
