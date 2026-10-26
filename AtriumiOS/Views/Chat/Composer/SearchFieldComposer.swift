import SwiftUI

/// The task's composer: the bottom-bar search field, styled for writing
/// prompts, with Return sending and then closing the composer.
struct SearchFieldComposer: ViewModifier {
    @Bindable var composer: TaskComposer
    let prompt: String
    /// Sends the draft, returning whether it was sent.
    let submit: () -> Bool

    @FocusState private var isFocused: Bool
    @State private var isPresented = false
    @State private var delegateProxy: TextFieldDelegateProxy?

    func body(content: Content) -> some View {
        content
            .searchable(text: $composer.draft, isPresented: $isPresented, prompt: Text(prompt))
            .autocorrectionDisabled(false)
            .textInputAutocapitalization(.sentences)
            .searchFocused($isFocused)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .background(
                SearchIntrospector { configure($0, referenceView: $1) }
            )
            .onSubmit(of: .search, send)
            // Mirror focus into the composer, where the timeline observes it
            // to scroll to the latest message (FocusState is view-local).
            .onChange(of: isFocused) { _, focused in
                composer.isFocused = focused
            }
            // Leaving the task can tear the field down while it still has
            // focus; the next task's first focus must register as a change.
            .onDisappear {
                composer.isFocused = false
            }
    }

    /// Sends the draft and, once it's gone, closes the composer and its
    /// keyboard. A draft that couldn't be sent stays open for editing.
    private func send() {
        if submit() {
            isPresented = false
        }
    }

    /// Makes Return send, by intercepting it through a delegate proxy.
    private func configure(_ textField: UISearchTextField, referenceView: UIView) {
        if textField.returnKeyType != .send {
            textField.returnKeyType = .send
            if textField.isFirstResponder {
                textField.reloadInputViews()
            }
        }
        styleComposerFields(in: textField, referenceView: referenceView)
        if delegateProxy == nil || textField.delegate !== delegateProxy {
            let proxy = TextFieldDelegateProxy(originalDelegate: textField.delegate)
            textField.delegate = proxy
            delegateProxy = proxy
        }
        delegateProxy?.shouldReturn = { _ in
            send()
            return false
        }
    }

    /// Uses regular body text and removes the magnifying glass, since this field
    /// composes prompts. A zero-size leading view replaces the glyph so its slot
    /// takes no width; merely hiding the glyph keeps the slot.
    ///
    /// The bottom-bar field UIKit draws is a clone of `textField` that doesn't
    /// follow the original's icon, so every field showing this composer's
    /// prompt is updated directly. The task list's "Search tasks" field never
    /// shares that prompt.
    private func styleComposerFields(in textField: UISearchTextField, referenceView: UIView) {
        guard let prompt = textField.placeholder, let window = referenceView.window else { return }
        for field in [textField] + searchTextFields(in: window)
        where field.placeholder == prompt {
            if !(field.leftView is ComposerSearchFieldStyle) {
                field.leftView = ComposerSearchFieldStyle(textField: field)
            }
        }
    }

    private func searchTextFields(in view: UIView) -> [UISearchTextField] {
        if let field = view as? UISearchTextField {
            return [field]
        }
        return view.subviews.flatMap(searchTextFields(in:))
    }
}

extension View {
    /// Turns the navigation search field into the task's prompt composer.
    func searchFieldComposer(_ composer: TaskComposer, prompt: String, submit: @escaping () -> Bool) -> some View {
        modifier(SearchFieldComposer(composer: composer, prompt: prompt, submit: submit))
    }
}
