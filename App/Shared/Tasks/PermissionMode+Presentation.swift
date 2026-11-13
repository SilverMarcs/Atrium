import AtriumProtocol

extension PermissionMode {
    var title: String {
        switch self {
        case .supervised: "Supervised"
        case .acceptEdits: "Auto-Accept Edits"
        case .auto: "Auto"
        case .fullAccess: "Full Access"
        }
    }

    var symbolName: String {
        switch self {
        case .supervised: "hand.raised"
        case .acceptEdits: "pencil.line"
        case .auto: "checkmark.shield"
        case .fullAccess: "lock.open"
        }
    }
}
