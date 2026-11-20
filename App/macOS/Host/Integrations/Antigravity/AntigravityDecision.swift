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
                if property.hasSuffix("_other"), properties[String(property.dropLast(6))]?["oneOf"] != nil { continue }
                let choices = field["oneOf"] as? [[String: Any]] ?? []
                let titles = choices.compactMap { $0["title"] as? String }
                let values = Dictionary(choices.compactMap { choice -> (String, String)? in
                    guard let title = choice["title"] as? String, let value = choice["const"] as? String else { return nil }
                    return (title, value)
                }, uniquingKeysWith: { first, _ in first })
                let other = properties["\(property)_other"] == nil ? nil : "\(property)_other"
                questions.append(Question(property: property, values: values, otherProperty: other))
                shown.append(AgentQuestion(id: property, title: field["title"] as? String ?? field["description"] as? String ?? property,
                                           options: titles, note: field["description"] as? String))
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
                guard let answer = decision.answers[question.property]?.first, !answer.isEmpty else { continue }
                if let value = question.values[answer] {
                    content[question.property] = value
                } else if let other = question.otherProperty {
                    content[other] = answer
                } else if question.values.isEmpty {
                    content[question.property] = answer
                }
            }
            return ["action": "accept", "content": content]
        }
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
