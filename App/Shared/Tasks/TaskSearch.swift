import Foundation

/// How the sidebar search matches a task in both apps.
enum TaskSearch {
    static func matches(_ query: String, in fields: String?...) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || fields.contains { $0?.localizedStandardContains(query) == true }
    }
}
