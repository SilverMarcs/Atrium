import SwiftUI

/// What a diff window shows, in a project on one of the hosts: one commit's
/// changes, or a branch's since it left its base, as a pull request would.
struct GitDiffWindowItem: Identifiable, Hashable, Codable {
    enum Subject: Hashable, Codable {
        case commit(hash: String, message: String)
        /// `head` is a branch, or nil for the checkout itself with its
        /// uncommitted changes; `name` is what the window calls it.
        case review(head: String?, name: String)
    }

    let project: WorkspaceRef
    let repositoryRootURL: URL
    let subject: Subject

    var id: String {
        switch subject {
        case .commit(let hash, _): hash
        case .review(let head, _): "review:\(repositoryRootURL.path):\(head ?? "")"
        }
    }
}

struct GitDiffWindow: View {
    let item: GitDiffWindowItem
    @Environment(AppModel.self) private var app
    @State private var diffLoader = DiffLoadModel()
    @State private var files: [GitComparedFile] = []
    /// What the files' diffs are taken between, once they've loaded.
    @State private var stage: GitDiffStage?
    @State private var comparison: GitComparison?
    /// The base a review was switched to; nil is the repository's default branch.
    @State private var chosenBase: String?
    @State private var baseChoices: GitBranchListing?
    @State private var isLoading = false
    @State private var selectedID: GitComparedFile.ID?
    @State private var loadError: String?
    @AppStorage(DiffLayout.key) private var defaultLayout = DiffLayout.unified
    /// This window's layout once switched in its toolbar; nil follows Settings.
    @State private var chosenLayout: DiffLayout?

    private var layout: DiffLayout { chosenLayout ?? defaultLayout }

    private var title: String {
        switch item.subject {
        case .commit(let hash, _): "Changes in \(hash.prefix(7))"
        case .review(_, let name): name
        }
    }

    private var subtitle: String {
        switch item.subject {
        case .commit(_, let message): message
        case .review:
            comparison.map { "\($0.commitCount) \($0.commitCount == 1 ? "commit" : "commits")" } ?? ""
        }
    }

    private var selectedFile: GitChangedFile? {
        files.first { $0.id == selectedID }?.file
    }

    private var isReview: Bool {
        if case .review = item.subject { true } else { false }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if isLoading && files.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "Unable to Load Changes",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if files.isEmpty {
                    ContentUnavailableView(
                        "No Changes",
                        systemImage: "doc.richtext",
                        description: Text(comparison.map { "Nothing here that isn’t in \($0.base)." } ?? "Nothing to show here.")
                    )
                } else {
                    List(files, selection: $selectedID) { file in
                        fileRow(file)
                    }
                    .listStyle(.sidebar)
                }
            }
            // What the files are, at the top of the sidebar; the diff's own
            // title is the file's.
            .toolbar {
                ToolbarItem {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.headline)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .padding(.leading, 8)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
            }
            .safeAreaBar(edge: .bottom) {
                if let comparison { reviewFooter(comparison) }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 3000, max: 420)
        } detail: {
            if let selection = selectedFile, let project = app.project(item.project), let reference = reference(for: selection) {
                DiffBodyView(reference: reference, project: project, loader: diffLoader, layout: layout)
                    .navigationTitle(selection.fileURL.lastPathComponent)
                    .navigationSubtitle(selection.repositoryRelativePath)
                    .toolbar {
                        if !selection.fileURL.isPreviewableImage {
                            ToolbarItem(placement: .primaryAction) {
                                Toggle("Side by Side", systemImage: "rectangle.split.2x1", isOn: Binding(
                                    get: { layout == .sideBySide },
                                    set: { chosenLayout = $0 ? .sideBySide : .unified }
                                ))
                                .help(layout == .sideBySide ? "Show Unified Diff" : "Show Side by Side")
                            }
                        }
                    }
            } else if !files.isEmpty {
                ContentUnavailableView(
                    "Select a File",
                    systemImage: "sidebar.left",
                    description: Text("Pick a file from the sidebar to see its diff.")
                )
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 560)
        .task(id: item.id) {
            await load()
            await loadBaseChoices()
        }
    }

    /// The review's totals and what they're compared with, at the foot of
    /// the sidebar as the inspector shows its branch; the menu switches the
    /// base or refreshes.
    private func reviewFooter(_ comparison: GitComparison) -> some View {
        HStack {
            baseMenu(comparison)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding()
    }

    private func baseMenu(_ comparison: GitComparison) -> some View {
        Menu {
            Picker("Compare With", selection: Binding(
                get: { comparison.base },
                set: { base in
                    chosenBase = base
                    Task { await load() }
                }
            )) {
                if let listing = baseChoices {
                    let local = listing.branches.filter { !$0.isRemote }.map(\.name)
                    let remote = listing.remoteBranches.map(\.name)
                    if !local.contains(comparison.base) && !remote.contains(comparison.base) {
                        Text(comparison.base).tag(comparison.base)
                    }
                    Section("Local") {
                        ForEach(local, id: \.self) { Text($0).tag($0) }
                    }
                    Section("Remote") {
                        ForEach(remote, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Text(comparison.base).tag(comparison.base)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
            .disabled(isLoading)
        } label: {
            baseTitle(comparison)
        }
        .controlSize(.large)
        .buttonSizing(.flexible)
        .help("Compared with \(comparison.baseRef) from where they split, \(comparison.mergeBase.prefix(7))")
    }

    /// "+39 −2 vs origin/develop", as one text so the menu's title keeps its colors.
    private func baseTitle(_ comparison: GitComparison) -> Text {
        let totals = LineCounts.text(added: comparison.added, removed: comparison.removed)
        return Text("\(totals) \(Text("vs").foregroundStyle(.secondary)) \(comparison.base)").monospacedDigit()
    }

    @ViewBuilder
    private func fileRow(_ compared: GitComparedFile) -> some View {
        let file = compared.file
        HStack(spacing: 8) {
            Image(nsImage: FileIcon.image(for: file.fileURL))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileURL.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(file.repositoryRelativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let added = compared.added, let removed = compared.removed {
                LineCounts(added: added, removed: removed)
                    .font(.caption.monospacedDigit())
            }
            GitStatusBadge(kind: file.kind, staged: true)
        }
        .padding(.vertical, 2)
    }

    private func reference(for file: GitChangedFile) -> GitDiffReference? {
        guard let stage else { return nil }
        return GitDiffReference(
            repositoryRootURL: item.repositoryRootURL,
            fileURL: file.fileURL,
            repositoryRelativePath: file.repositoryRelativePath,
            stage: stage,
            kind: file.kind
        )
    }

    private func load() async {
        loadError = nil
        guard let project = app.project(item.project) else {
            loadError = "This project’s host is no longer connected."
            return
        }
        isLoading = true
        defer { isLoading = false }
        let shownReference = selectedFile.flatMap(reference(for:))
        do {
            switch item.subject {
            case .commit(let hash, _):
                guard case .files(let commitFiles) = try await project.git(.commitFiles(hash: hash), in: item.repositoryRootURL) else {
                    throw HostClientError.unexpectedReply
                }
                files = commitFiles.map { GitComparedFile(file: $0, added: nil, removed: nil) }
                stage = .commit(hash: hash)
            case .review(let head, _):
                guard case .comparison(let compared) = try await project.git(.compare(base: chosenBase, head: head), in: item.repositoryRootURL) else {
                    throw HostClientError.unexpectedReply
                }
                comparison = compared
                files = compared.files
                stage = .comparison(mergeBase: compared.mergeBase, head: head)
            }
            // A refresh keeps the file in view. Its diff view reloads when the
            // reference changes; an unchanged one reloads here, keeping its place.
            if let selection = selectedFile, let reference = reference(for: selection) {
                if reference == shownReference { await diffLoader.reloadInPlace(reference, from: project.git.model) }
            } else {
                selectedID = files.first?.id
            }
        } catch {
            files = []
            selectedID = nil
            loadError = error.localizedDescription
        }
    }

    private func loadBaseChoices() async {
        guard isReview, let project = app.project(item.project),
              case .branches(let listing) = try? await project.git(.branches, in: item.repositoryRootURL) else { return }
        baseChoices = listing
    }
}
