import SwiftUI

/// The task's composer: the bottom-bar search field, styled for writing
/// prompts, with Return sending and then closing the composer, and Close
/// closing it with the draft kept.
struct SearchFieldComposer: ViewModifier {
    @Bindable var composer: TaskComposer
    let prompt: String
    /// Sends the draft, returning whether it was sent.
    let submit: () -> Bool

    @FocusState private var isFocused: Bool
    @State private var isPresented = false
    @State private var delegateProxy: TextFieldDelegateProxy?
    @State private var searchBarDelegateProxy: SearchBarDelegateProxy?

    func body(content: Content) -> some View {
        content
            .searchable(text: $composer.draft, isPresented: $isPresented, prompt: Text(prompt))
            .autocorrectionDisabled(false)
            .textInputAutocapitalization(.sentences)
            .searchFocused($isFocused)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .background(
                SearchIntrospector { configure($0, searchBar: $1, referenceView: $2) }
            )
            .onSubmit(of: .search, send)
            .task(id: composer.focusRequestID) {
                guard composer.focusRequestID != nil else { return }
                isPresented = true
                // Let the search field open before requesting its keyboard.
                await Task.yield()
                guard !Task.isCancelled else { return }
                isFocused = true
            }
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

    /// Closes the composer and its keyboard, keeping the draft for later.
    ///
    /// SwiftUI's own Close handling empties the search text, so this stands in
    /// for it. UIKit still empties the field as the search deactivates, and
    /// SwiftUI only pushes the draft into it when the draft changes, so the
    /// draft is put back once UIKit is done.
    private func close(_ textField: UISearchTextField, referenceView: UIView) {
        withAnimation {
            isPresented = false
        }
        Task {
            restoreDraft(in: textField, referenceView: referenceView)
        }
    }

    /// Makes Return send and Close keep the draft, by intercepting them
    /// through delegate proxies.
    private func configure(_ textField: UISearchTextField, searchBar: UISearchBar?, referenceView: UIView) {
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
        if let searchBar {
            if searchBarDelegateProxy == nil || searchBar.delegate !== searchBarDelegateProxy {
                let proxy = SearchBarDelegateProxy(originalDelegate: searchBar.delegate)
                searchBar.delegate = proxy
                searchBarDelegateProxy = proxy
            }
            searchBarDelegateProxy?.cancelButtonClicked = { [weak textField, weak referenceView] _ in
                guard let textField, let referenceView else { return }
                close(textField, referenceView: referenceView)
            }
        }
        restoreDraft(in: textField, referenceView: referenceView)
    }

    /// Shows the draft in composer fields UIKit emptied while closing. Fields
    /// being edited are left alone, as they already hold what was typed.
    private func restoreDraft(in textField: UISearchTextField, referenceView: UIView) {
        for field in composerFields(matching: textField, referenceView: referenceView)
        where !field.isFirstResponder && field.text != composer.draft {
            field.text = composer.draft
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
        for field in composerFields(matching: textField, referenceView: referenceView)
        where !(field.leftView is ComposerSearchFieldStyle) {
            field.leftView = ComposerSearchFieldStyle(textField: field)
        }
    }

    /// `textField` and every clone of it UIKit shows, told apart by this
    /// composer's prompt.
    private func composerFields(matching textField: UISearchTextField, referenceView: UIView) -> [UISearchTextField] {
        guard let prompt = textField.placeholder, let window = referenceView.window else { return [] }
        return ([textField] + searchTextFields(in: window)).filter { $0.placeholder == prompt }
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
