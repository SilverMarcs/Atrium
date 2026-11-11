import SwiftUI

/// The command console's input on iPhone: the bottom-bar search field, styled
/// for typing commands, the way the chat composes prompts. Return submits and
/// keeps the field open for the next line, and Close keeps the draft.
struct CommandSearchFieldComposer: ViewModifier {
    @Bindable var console: CommandConsole
    let prompt: String
    let submitLabel: UIReturnKeyType

    @FocusState private var isFocused: Bool
    @State private var isPresented = false
    @State private var delegateProxy: TextFieldDelegateProxy?
    @State private var searchBarDelegateProxy: SearchBarDelegateProxy?

    func body(content: Content) -> some View {
        content
            .searchable(text: $console.draft, isPresented: $isPresented, prompt: Text(prompt))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .searchFocused($isFocused)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .background(
                SearchIntrospector { textField, searchBar, referenceView in
                    configure(textField, searchBar: searchBar, referenceView: referenceView)
                }
            )
            .onSubmit(of: .search) { console.submit() }
    }

    /// Makes Return submit without closing the field and Close keep the draft,
    /// by intercepting them through delegate proxies.
    private func configure(_ textField: UISearchTextField, searchBar: UISearchBar?, referenceView: UIView) {
        if textField.returnKeyType != submitLabel {
            textField.returnKeyType = submitLabel
            if textField.isFirstResponder {
                textField.reloadInputViews()
            }
        }
        for field in commandFields(matching: textField, referenceView: referenceView) {
            if !(field.leftView is ComposerSearchFieldStyle) {
                field.leftView = ComposerSearchFieldStyle(textField: field, isMonospaced: true, autocorrects: false)
            }
            // Shell input breaks on curly quotes and long dashes.
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.spellCheckingType = .no
        }
        if delegateProxy == nil || textField.delegate !== delegateProxy {
            let proxy = TextFieldDelegateProxy(originalDelegate: textField.delegate)
            textField.delegate = proxy
            delegateProxy = proxy
        }
        delegateProxy?.shouldReturn = { _ in
            console.submit()
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

    /// Closes the field and its keyboard, keeping the draft for later.
    ///
    /// SwiftUI's own Close handling empties the search text, so this stands in
    /// for it. UIKit still empties the field as the search deactivates, so the
    /// draft is put back once UIKit is done.
    private func close(_ textField: UISearchTextField, referenceView: UIView) {
        withAnimation {
            isPresented = false
        }
        Task {
            restoreDraft(in: textField, referenceView: referenceView)
        }
    }

    /// Shows the draft in fields UIKit emptied while closing. Fields being
    /// edited are left alone, as they already hold what was typed.
    private func restoreDraft(in textField: UISearchTextField, referenceView: UIView) {
        for field in commandFields(matching: textField, referenceView: referenceView)
        where !field.isFirstResponder && field.text != console.draft {
            field.text = console.draft
        }
    }

    /// `textField` and every clone of it UIKit shows in the bottom bar, told
    /// apart by the console's prompt.
    private func commandFields(matching textField: UISearchTextField, referenceView: UIView) -> [UISearchTextField] {
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
    /// Turns the navigation search field into the command console's input.
    func commandSearchFieldComposer(_ console: CommandConsole, prompt: String, submitLabel: UIReturnKeyType) -> some View {
        modifier(CommandSearchFieldComposer(console: console, prompt: prompt, submitLabel: submitLabel))
    }
}
