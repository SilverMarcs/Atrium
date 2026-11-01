import AtriumProtocol
import SwiftUI

/// Keys to press in a running command, for prompts that want more than a typed reply.
struct CommandKeysMenu: View {
    let press: (CommandKey) -> Void

    var body: some View {
        Menu("Keys", systemImage: "keyboard") {
            ForEach(CommandKey.allCases, id: \.self) { key in
                Button(key.title, systemImage: key.systemImage) { press(key) }
            }
        }
        .help("Press a key in the running command")
    }
}

extension CommandKey {
    var title: String {
        switch self {
        case .interrupt: "Control-C"
        case .endOfInput: "Control-D"
        case .escape: "Escape"
        case .tab: "Tab"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .enter: "Return"
        }
    }

    var systemImage: String {
        switch self {
        case .interrupt: "xmark.octagon"
        case .endOfInput: "eject"
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .enter: "return"
        }
    }
}
