import SwiftUI

extension View {
    @ViewBuilder
    func shimmer(when isLoading: Bool) -> some View {
        if isLoading {
            self.modifier(ShimmerModifier())
                .redacted(reason: .placeholder)
        } else {
            self
        }
    }

    @ViewBuilder
    func shimmerWithoutRedact(when isLoading: Bool) -> some View {
        if isLoading {
            self.modifier(ShimmerModifier())
        } else {
            self
        }
    }
}

struct ShimmerModifier: ViewModifier {
    @State private var isInitialState = true

    func body(content: Content) -> some View {
        content
            .brightness(0.1)
            .mask(
                LinearGradient(
                    gradient: .init(colors: [.black.opacity(0.6), .black, .black.opacity(0.6)]),
                    startPoint: (isInitialState ? .init(x: -0.3, y: -0.3) : .init(x: 1, y: 1)),
                    endPoint: (isInitialState ? .init(x: 0, y: 0) : .init(x: 1.3, y: 1.3))
                )
            )
            .animation(.linear(duration: 1.5).delay(0.25).repeatForever(autoreverses: false), value: isInitialState)
            .onAppear {
                isInitialState = false
            }
    }
}
