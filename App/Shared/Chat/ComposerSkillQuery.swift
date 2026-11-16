/// The unfinished skill name at the beginning of a draft.
enum ComposerSkillQuery {
    static func parse(_ draft: String) -> String? {
        guard draft.first == "/" else { return nil }
        let name = draft.dropFirst()
        guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
        return String(name)
    }
}
