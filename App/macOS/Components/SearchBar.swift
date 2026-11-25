import SwiftUI

/// The inspector's search field: a capsule with a magnifying glass, or other
/// controls, before the field and optional buttons after it.
struct SearchBar<Leading: View, Trailing: View>: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var focusTrigger: Int = 0
    var isLoading: Bool = false
    /// Whether a clear button shows once there's text.
    var clears = true
    /// Tells the owner whether the field is being edited.
    var onEditingChange: ((Bool) -> Void)?
    var onSubmit: (() -> Void)?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            leading

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($isFocused)
                .onSubmit { onSubmit?() }
                .onChange(of: isFocused) { onEditingChange?(isFocused) }

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if clears, !text.isEmpty {
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
        .frame(height: InspectorBar.height)
        .background(.quaternary, in: Capsule())
        .task(id: focusTrigger) {
            guard focusTrigger > 0 else { return }
            try? await Task.sleep(for: .milliseconds(150))
            isFocused = true
        }
    }
}

/// The capsule bars along the top of the inspector's tabs, such as the
/// search bars and the Simulator tab's picker, all take one height, so
/// switching tabs never moves what's below them.
enum InspectorBar {
    static let height: CGFloat = 25
}

/// The magnifying glass a search bar starts with, which also sets its height.
struct SearchBarIcon: View {
    var body: some View {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
    }
}

extension SearchBar where Leading == SearchBarIcon {
    init(
        text: Binding<String>,
        placeholder: String = "Search",
        focusTrigger: Int = 0,
        isLoading: Bool = false,
        onSubmit: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(text: text, placeholder: placeholder, focusTrigger: focusTrigger, isLoading: isLoading,
                  onSubmit: onSubmit, leading: { SearchBarIcon() }, trailing: trailing)
    }
}

extension SearchBar where Leading == SearchBarIcon, Trailing == EmptyView {
    init(
        text: Binding<String>,
        placeholder: String = "Search",
        focusTrigger: Int = 0,
        isLoading: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.init(text: text, placeholder: placeholder, focusTrigger: focusTrigger, isLoading: isLoading,
                  onSubmit: onSubmit, trailing: { EmptyView() })
    }
}
