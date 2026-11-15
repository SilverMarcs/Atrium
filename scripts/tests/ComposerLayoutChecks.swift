import AppKit
import SwiftUI

// The production layout runs unchanged; only editor measurement is fixed.
nonisolated enum ComposerEditor {
    static let horizontalInset: CGFloat = 20
    static func expandedHeight(of text: String, width: CGFloat, maximumLines: Int) -> CGFloat { 48 }
}
nonisolated enum ComposerTextView { static let maximumLines = 8 }

@MainActor final class LayoutCapture {
    var views: [ComposerBarPart: NSView] = [:]
}

struct LayoutProbe: NSViewRepresentable {
    let part: ComposerBarPart
    let capture: LayoutCapture
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        capture.views[part] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct LayoutFixture: View {
    let expanded: Bool
    let capture: LayoutCapture
    var body: some View {
        ComposerBarLayout(isExpanded: expanded, draft: "") {
            Color.clear.composerBarPart(.panel)
            Color.clear.composerBarPart(.attach)
            LayoutProbe(part: .action, capture: capture).frame(width: 48, height: 48).composerBarPart(.action)
            Color.clear.frame(width: 44, height: 36).composerBarPart(.dictation)
            LayoutProbe(part: .permissions, capture: capture).frame(width: 44, height: 44).composerBarPart(.permissions)
            LayoutProbe(part: .model, capture: capture).frame(width: 44, height: 44).composerBarPart(.model)
        }
    }
}

@main @MainActor enum ComposerLayoutChecks {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func measure(expanded: Bool, width: CGFloat) async throws -> [ComposerBarPart: CGRect] {
        let capture = LayoutCapture()
        let host = NSHostingView(rootView: LayoutFixture(expanded: expanded, capture: capture))
        host.frame = CGRect(x: 0, y: 0, width: width, height: expanded ? 96 : 48)
        _ = host.fittingSize
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        var frames: [ComposerBarPart: CGRect] = [:]
        for part in [ComposerBarPart.permissions, .model, .action] {
            guard let view = capture.views[part] else { throw Failure(message: "Missing layout probe") }
            frames[part] = host.convert(view.bounds, from: view)
        }
        return frames
    }
    static func main() async {
        do { try await runChecks() }
        catch {
            print("Composer layout checks failed:", error)
            exit(1)
        }
    }
    static func runChecks() async throws {
        _ = NSApplication.shared
        for width in [CGFloat(393), 768] {
            let resting = try await measure(expanded: false, width: width)
            let expanded = try await measure(expanded: true, width: width)
            for frames in [resting, expanded] {
                guard let permissions = frames[.permissions], let model = frames[.model], let action = frames[.action] else {
                    throw Failure(message: "Missing menu frames")
                }
                try check(action.width == 48 && action.height == 48, "Send and Stop keep one 48-point touch target")
                try check(permissions.minX > 0 && model.minX > 0, "Menus must never start at the layout origin")
                try check(model.minX > permissions.maxX, "Model must remain in the trailing group")
                try check(model.width == 44 && model.height == 44 && permissions.width == 44 && permissions.height == 44,
                          "Menus must preserve their touch targets")
            }
            try check(resting[.permissions]?.minX == expanded[.permissions]?.minX && resting[.model]?.minX == expanded[.model]?.minX,
                      "Opening the composer must preserve menu horizontal positions")
        }
        print("Composer menu layout regression checks passed")
    }
}
