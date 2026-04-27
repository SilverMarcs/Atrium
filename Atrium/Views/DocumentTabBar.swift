// Preserved for future UI reference after the terminal-tab UI was removed.
// This view depends on `Workspace.terminals` and `AppState.selectedTerminal`,
// neither of which exist anymore — uncomment and wire back up if tabs return.

/*
import SwiftUI

struct DocumentTabBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("hideTabBarWithSingleTab") private var hideTabBarWithSingleTab = false
    let workspace: Workspace
    @State private var hoveredTabID: UUID?
    @State private var draggedTabID: UUID?
    @State private var dragOriginalIndex: Int?
    @State private var dragCurrentIndex: Int?
    @State private var dragOffset: CGFloat = 0
    @State private var lastDragTranslation: CGFloat = 0
    @State private var renamingTab: Terminal?
    @State private var processNames: [UUID: String] = [:]
    @State private var hoveredCloseTabID: UUID?

    var body: some View {
        let terminals = workspace.terminals
        let isVisible = terminals.count > 1 || (terminals.count == 1 && !hideTabBarWithSingleTab)
        tabContent(terminals: terminals)
            .frame(height: isVisible ? nil : 0)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .clipped()
    }

    @ViewBuilder
    private func tabContent(terminals: [Terminal]) -> some View {
        HStack(spacing: 5) {
            tabStrip(terminals: terminals)
            Button {
                let terminal = workspace.addTerminal(
                    currentDirectory: appState.selectedTerminal?.currentDirectory,
                    after: appState.selectedTerminal
                )
                appState.selectedTerminal = terminal
            } label: {
                Image(systemName: "plus")
                    .padding(2)
            }
            .help("New Tab")
            .controlSize(.large)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
        .task {
            while !Task.isCancelled {
                var names: [UUID: String] = [:]
                for terminal in terminals {
                    if let name = terminal.foregroundProcessName {
                        names[terminal.id] = name
                    }
                }
                processNames = names
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Rename Tab", isPresented: Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } }), presenting: renamingTab) { tab in
            TextField("Tab Name", text: Bindable(tab).title)
            Button("Cancel", role: .cancel) { renamingTab = nil }
            Button("Done", role: .confirm) { renamingTab = nil }
        } message: { _ in
            Text("Set a custom name for this terminal tab.")
        }
    }

    private func tabStrip(terminals: [Terminal]) -> some View {
        GeometryReader { proxy in
            let tabCount = max(terminals.count, 1)
            let separatorWidth: CGFloat = 5
            let totalSeparators = CGFloat(max(tabCount - 1, 0)) * separatorWidth
            let tabWidth = max((proxy.size.width - totalSeparators) / CGFloat(tabCount), 90)
            let contentWidth = CGFloat(tabCount) * tabWidth + totalSeparators
            let tabStride = tabWidth + separatorWidth

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                        if index > 0 {
                            separator(before: index, in: terminals)
                        }
                        tabItem(terminal, index: index, width: tabWidth, tabStride: tabStride, in: terminals)
                    }
                }
                .frame(minWidth: contentWidth, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(height: 26)
        .padding(.top, 2)
        .padding(.horizontal, 2)
        .padding(.bottom, 0)
        .background(
            Capsule()
                .fill(colorScheme == .dark ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.secondary))
        )
    }

    @ViewBuilder
    private func tabItem(_ terminal: Terminal, index: Int, width: CGFloat, tabStride: CGFloat, in terminals: [Terminal]) -> some View {
        let isSelected = appState.selectedTerminal === terminal
        let isHovered = hoveredTabID == terminal.id
        let isDragging = draggedTabID == terminal.id
        let computedOffset = computedDragOffset(for: terminal, at: index, tabStride: tabStride)

        Button {
            appState.selectedTerminal = terminal
        } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: 10, height: 10)

                Text(processNames[terminal.id].map { "\(terminal.title) \u{2014} \($0)" } ?? terminal.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .center)

                if terminal.hasBellNotification {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .frame(width: 10, height: 10)
                } else {
                    Color.clear.frame(width: 10, height: 10)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .frame(width: width)
            .background(
                Capsule()
                    .fill(isSelected ? (colorScheme == .dark ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background.secondary)) : isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
                    .strokeBorder(isSelected ? (colorScheme == .dark ? AnyShapeStyle(.separator) : AnyShapeStyle(.background)) : AnyShapeStyle(.clear))
            )
            .contentShape(.capsule)
        }
        .offset(x: computedOffset)
        .zIndex(isDragging ? 1 : 0)
        .animation(.default, value: terminals.count)
        .overlay(alignment: .leading) {
            if isHovered && terminals.count > 1 && draggedTabID == nil {
                Button {
                    closeTerminal(terminal)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .fill(hoveredCloseTabID == terminal.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                        )
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredCloseTabID = isHovering ? terminal.id : (hoveredCloseTabID == terminal.id ? nil : hoveredCloseTabID)
                }
                .padding(.leading, 6)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renamingTab = terminal
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    handleDragChanged(terminal: terminal, translation: value.translation.width, tabStride: tabStride)
                }
                .onEnded { _ in
                    handleDragEnded(tabStride: tabStride)
                }
        )
        .onHover { isHovering in
            hoveredTabID = isHovering ? terminal.id : (hoveredTabID == terminal.id ? nil : hoveredTabID)
        }
    }

    private func computedDragOffset(for terminal: Terminal, at index: Int, tabStride: CGFloat) -> CGFloat {
        if terminal.id == draggedTabID {
            return dragOffset
        }
        guard let original = dragOriginalIndex, let current = dragCurrentIndex else {
            return 0
        }
        if original < current {
            if index > original && index <= current {
                return -tabStride
            }
        } else if original > current {
            if index >= current && index < original {
                return tabStride
            }
        }
        return 0
    }

    private func handleDragChanged(terminal: Terminal, translation: CGFloat, tabStride: CGFloat) {
        if draggedTabID != terminal.id {
            let sorted = workspace.terminals
            guard let originalIdx = sorted.firstIndex(where: { $0.id == terminal.id }) else { return }
            draggedTabID = terminal.id
            dragOriginalIndex = originalIdx
            dragCurrentIndex = originalIdx
            dragOffset = 0
            lastDragTranslation = 0
        }

        guard let originalIdx = dragOriginalIndex else { return }
        let count = workspace.terminals.count

        let delta = translation - lastDragTranslation
        lastDragTranslation = translation

        let minOffset = -CGFloat(originalIdx) * tabStride
        let maxOffset = CGFloat(count - 1 - originalIdx) * tabStride
        dragOffset = min(max(dragOffset + delta, minOffset), maxOffset)

        let stepsMoved = Int((dragOffset / tabStride).rounded())
        let newCurrent = max(0, min(count - 1, originalIdx + stepsMoved))
        if newCurrent != dragCurrentIndex {
            withAnimation(.snappy(duration: 0.2)) {
                dragCurrentIndex = newCurrent
            }
        }
    }

    private func handleDragEnded(tabStride: CGFloat) {
        guard let draggedID = draggedTabID,
              let originalIdx = dragOriginalIndex,
              let currentIdx = dragCurrentIndex else {
            resetDragState()
            return
        }

        lastDragTranslation = 0

        withAnimation(.snappy(duration: 0.22)) {
            if originalIdx != currentIdx {
                let sorted = workspace.terminals
                if let dragged = sorted.first(where: { $0.id == draggedID }) {
                    var newOrder = sorted
                    newOrder.remove(at: originalIdx)
                    newOrder.insert(dragged, at: currentIdx)
                    workspace.reorderTerminals(newOrder)
                }
            }
            dragOriginalIndex = nil
            dragCurrentIndex = nil
            dragOffset = 0
        } completion: {
            draggedTabID = nil
        }
    }

    private func resetDragState() {
        draggedTabID = nil
        dragOriginalIndex = nil
        dragCurrentIndex = nil
        dragOffset = 0
        lastDragTranslation = 0
    }

    private func separator(before index: Int, in terminals: [Terminal]) -> some View {
        let show = index > 0 && index < terminals.count
            && appState.selectedTerminal !== terminals[index - 1]
            && appState.selectedTerminal !== terminals[index]

        return Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
            .opacity(show ? 1 : 0)
    }

    private func closeTerminal(_ terminal: Terminal) {
        if terminal.hasChildProcess {
            appState.terminalPendingClose = terminal
            return
        }
        performClose(terminal)
    }

    private func performClose(_ terminal: Terminal) {
        if appState.selectedTerminal === terminal {
            let terminals = workspace.terminals
            if let idx = terminals.firstIndex(where: { $0 === terminal }) {
                if idx + 1 < terminals.count {
                    appState.selectedTerminal = terminals[idx + 1]
                } else if idx > 0 {
                    appState.selectedTerminal = terminals[idx - 1]
                } else {
                    appState.selectedTerminal = nil
                }
            }
        }
        workspace.closeTerminal(terminal)
    }
}
*/
