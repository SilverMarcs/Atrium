import Foundation

/// Path elements for the root `NavigationStack`. Hoisted out of the
/// individual screens so notification taps and post-`createChat` pushes
/// can mutate navigation from outside the view tree.
enum Route: Hashable {
    case workspace(WireWorkspace)
    case chat(UUID)
}

/// Single-shot deeplink target — workspace + session pair to land on.
/// Identified by a per-instance UUID so SwiftUI's `onChange` reliably
/// fires even if the same workspace/session pair is taken twice in a row.
struct PendingDeepLink: Hashable {
    let id = UUID()
    let workspaceId: UUID
    let sessionId: UUID
}
