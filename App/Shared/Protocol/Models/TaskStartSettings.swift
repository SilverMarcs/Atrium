/// Settings inherited by a blank conversation, independently of its history.
nonisolated struct TaskStartSettings: Codable, Sendable, Hashable {
    var model: String?
    var reasoningEffort: String?
    var isFastMode: Bool?
    var permissionMode: PermissionMode?
}
