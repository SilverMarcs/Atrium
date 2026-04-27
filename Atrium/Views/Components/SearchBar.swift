import SwiftUI

struct SearchBar<Trailing: View>: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var focusTrigger: Int = 0
    var isLoading: Bool = false
    var onSubmit: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($isFocused)
                .onSubmit { onSubmit?() }

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            trailing
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .task(id: focusTrigger) {
            guard focusTrigger > 0 else { return }
            try? await Task.sleep(for: .milliseconds(150))
            isFocused = true
        }
    }
}

extension SearchBar where Trailing == EmptyView {
    init(
        text: Binding<String>,
        placeholder: String = "Search",
        focusTrigger: Int = 0,
        isLoading: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.focusTrigger = focusTrigger
        self.isLoading = isLoading
        self.onSubmit = onSubmit
        self.trailing = EmptyView()
    }
}
