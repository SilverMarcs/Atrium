import AtriumProtocol
import Foundation

/// What the agent asks Atrium to decide: a tool's permission
/// (`session/request_permission`) or the answers to its questions
/// (`elicitation/create`), and how each answer goes back.
nonisolated enum AntigravityDecision {
    case permission(options: [[String: Any]])
    /// Each question's property in the form, with the values its options stand
    /// for, and the property for an answer of the user's own, when the form has one.
    case questions([Question])

    struct Question {
        let property: String
        let values: [String: String]
        let allowsMultiple: Bool
        let otherProperty: String?
    }

    /// The decision a request asks for, with how Atrium shows it, or nil for a request Atrium doesn't take.
    static func decision(for method: String, params: [String: Any], id: String, taskID: String)
        -> (decision: AntigravityDecision, interaction: AgentInteraction)? {
        switch method {
        case "session/request_permission":
            let call = params["toolCall"] as? [String: Any] ?? [:]
            let interaction = AgentInteraction(id: id, taskID: taskID, title: "Allow Antigravity to continue?", detail: detail(of: call))
            return (.permission(options: params["options"] as? [[String: Any]] ?? []), interaction)
        case "elicitation/create":
            let schema = params["requestedSchema"] as? [String: Any] ?? [:]
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            var questions: [Question] = []
            var shown: [AgentQuestion] = []
            for property in properties.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let field = properties[property] ?? [:]
                // An "other" answer belongs to the question it follows.
                if property.hasSuffix("_other"), let base = properties[String(property.dropLast(6))], hasChoices(base) { continue }
                let parsed = parseChoices(in: field)
                let other = properties["\(property)_other"] == nil ? nil : "\(property)_other"
                questions.append(Question(property: property, values: parsed.values, allowsMultiple: parsed.allowsMultiple, otherProperty: other))
                shown.append(AgentQuestion(
                    id: property,
                    title: field["title"] as? String ?? field["description"] as? String ?? property,
                    options: parsed.titles,
                    allowsMultiple: parsed.allowsMultiple,
                    optionDescriptions: parsed.descriptions,
                    note: field["description"] as? String
                ))
            }
            guard !shown.isEmpty else { return nil }
            let interaction = AgentInteraction(id: id, taskID: taskID, title: "Antigravity needs your input",
                                               detail: params["message"] as? String ?? "", questions: shown)
            return (.questions(questions), interaction)
        default:
            return nil
        }
    }

    /// The result that answers the request.
    func result(for decision: AgentDecision) -> [String: Any] {
        switch self {
        case .permission(let options):
            guard let option = Self.option(in: options, kinds: decision.allowed ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]) else {
                return ["outcome": ["outcome": "cancelled"]]
            }
            return ["outcome": ["outcome": "selected", "optionId": option]]
        case .questions(let questions):
            guard decision.allowed else { return ["action": "decline"] }
            var content: [String: Any] = [:]
            for question in questions {
                let answers = (decision.answers[question.property] ?? []).filter { !$0.isEmpty }
                guard !answers.isEmpty else { continue }
                if question.allowsMultiple {
                    var selected: [String] = []
                    var custom: [String] = []
                    for answer in answers {
                        if let value = question.values[answer] {
                            selected.append(value)
                        } else if question.otherProperty != nil {
                            custom.append(answer)
                        } else {
                            selected.append(answer)
                        }
                    }
                    if !selected.isEmpty { content[question.property] = selected }
                    if let other = question.otherProperty, !custom.isEmpty { content[other] = custom.joined(separator: ", ") }
                } else if let answer = answers.first {
                    if let value = question.values[answer] {
                        content[question.property] = value
                    } else if let other = question.otherProperty {
                        content[other] = answer
                    } else if question.values.isEmpty {
                        content[question.property] = answer
                    }
                }
            }
            return ["action": "accept", "content": content]
        }
    }

    private static func hasChoices(_ field: [String: Any]) -> Bool {
        !parseChoices(in: field).titles.isEmpty
    }

    /// Single-select (`oneOf` / `enum`) or multi-select (`type: "array"` with
    /// `items.anyOf` / `items.oneOf` / `items.enum`) schema choices.
    private static func parseChoices(in field: [String: Any])
        -> (titles: [String], values: [String: String], descriptions: [String: String], allowsMultiple: Bool) {
        let isArray = field["type"] as? String == "array"
        let source = isArray ? (field["items"] as? [String: Any] ?? [:]) : field
        let entries = source["oneOf"] as? [[String: Any]] ?? source["anyOf"] as? [[String: Any]]
        if let entries, !entries.isEmpty {
            var titles: [String] = []
            var values: [String: String] = [:]
            var descriptions: [String: String] = [:]
            for entry in entries {
                guard let value = entry["const"] as? String else { continue }
                let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
                titles.append(title)
                if values[title] == nil { values[title] = value }
                if let description = entry["description"] as? String, !description.isEmpty {
                    descriptions[title] = description
                }
            }
            return (titles, values, descriptions, isArray)
        }
        if let rawValues = source["enum"] as? [String], !rawValues.isEmpty {
            let names = source["enumNames"] as? [String] ?? []
            var titles: [String] = []
            var values: [String: String] = [:]
            for (index, value) in rawValues.enumerated() {
                let title = names.indices.contains(index) && !names[index].isEmpty ? names[index] : value
                titles.append(title)
                if values[title] == nil { values[title] = value }
            }
            return (titles, values, [:], isArray)
        }
        return ([], [:], [:], isArray)
    }

    /// The result that withdraws the request, as a turn that's cancelled does.
    var cancellation: [String: Any] {
        switch self {
        case .permission: ["outcome": ["outcome": "cancelled"]]
        case .questions: ["action": "cancel"]
        }
    }

    private static func option(in options: [[String: Any]], kinds: [String]) -> String? {
        for kind in kinds {
            if let id = options.first(where: { $0["kind"] as? String == kind })?["optionId"] as? String { return id }
        }
        return nil
    }

    /// What the tool would do: its command, or the files it changes.
    private static func detail(of call: [String: Any]) -> String {
        var parts: [String] = []
        if let title = call["title"] as? String, !title.isEmpty { parts.append(title) }
        let input = call["rawInput"] as? [String: Any] ?? [:]
        if let command = input["CommandLine"] as? String, !command.isEmpty, command != call["title"] as? String {
            parts.append(command)
        }
        for content in call["content"] as? [[String: Any]] ?? [] where content["type"] as? String == "diff" {
            guard let path = content["path"] as? String else { continue }
            var text = (content["newText"] as? String) ?? ""
            if text.utf8.count > 8_000 { text = String(text.prefix(8_000)) + "\n…" }
            parts.append(text.isEmpty ? path : "\(path)\n\n\(text)")
        }
        if parts.isEmpty { parts.append("Antigravity wants to run a tool.") }
        return parts.joined(separator: "\n\n")
    }
}
