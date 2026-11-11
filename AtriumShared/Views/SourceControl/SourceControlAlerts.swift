import SwiftUI

/// Presents what a project's source control asks to confirm, and its errors.
private struct SourceControlAlerts: ViewModifier {
    let source: SourceControl

    func body(content: Content) -> some View {
        let prompt = source.prompt
        content
            .alert(
                prompt?.title ?? "",
                isPresented: Binding(get: { source.prompt != nil }, set: { if !$0 { source.prompt = nil } }),
                presenting: prompt
            ) { prompt in
                if let confirmTitle = prompt.confirmTitle {
                    Button(confirmTitle, role: prompt.isDestructive ? .destructive : nil) {
                        Task { await source.confirm(prompt) }
                    }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { prompt in
                Text(prompt.message)
            }
            .alert(
                "Source Control",
                isPresented: Binding(get: { source.errorMessage != nil }, set: { if !$0 { source.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(source.errorMessage ?? "")
            }
    }
}

extension View {
    /// Presents what `source` asks to confirm, and its errors.
    func sourceControlAlerts(_ source: SourceControl) -> some View {
        modifier(SourceControlAlerts(source: source))
    }
}
