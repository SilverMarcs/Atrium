import SwiftUI

/// Settings' choice of how diff viewers open: unified or side by side.
/// Each viewer can still switch on its own.
struct DiffLayoutPicker: View {
    @AppStorage(DiffLayout.key) private var layout = DiffLayout.unified

    var body: some View {
        Picker(selection: $layout) {
            ForEach(DiffLayout.allCases) { layout in
                Text(layout.title).tag(layout)
            }
        } label: {
            Text("Diff layout")
        }
    }
}
