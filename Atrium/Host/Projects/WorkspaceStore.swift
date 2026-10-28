import Foundation
import Observation
import SwiftUI

/// Persists `Workspace` objects (and their saved commands) to a JSON file in
/// `~/Library/Application Support/Atrium/TaskWorkspace/`. Every change comes
/// through a request, which schedules a save.
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
        let dir = HostStorage.directory.appending(path: "TaskWorkspace", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("workspaces.json")

        load()
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
