import SwiftUI

struct GitPollingModifier<ID: Equatable>: ViewModifier {
    let id: ID
    let interval: Duration
    let action: @Sendable () async -> Void

    func body(content: Content) -> some View {
        content
            .task(id: id, priority: .low) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    await action()
                }
            }
    }
}

extension View {
    func gitPolling<ID: Equatable>(
        id: ID,
        interval: Duration = .seconds(5),
        action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(GitPollingModifier(id: id, interval: interval, action: action))
    }
}
