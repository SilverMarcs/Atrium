import Foundation

extension CodexBackend {
    func ask(id: JSONValue, params: JSONValue) throws {
        let thread = try params.requireString("threadId")
        let turn = try params.requireString("turnId")
        guard ownsThread(thread), thread != sessionID || turn == turnID else {
            throw AgentError(message: "Unexpected Codex question turn: \(params.raw)")
        }
        guard let values = params["questions"].array, !values.isEmpty else {
            throw AgentError(message: "Invalid Codex questions: \(params.raw)")
        }
        let inputs = try values.map { question in
            let options = try (question["options"].array ?? []).map { option in
                InputQuestionOption(label: try option.requireString("label"), description: try option.requireString("description"))
            }
            return InputQuestion(id: try question.requireString("id"), header: try question.requireString("header"), question: try question.requireString("question"), options: options, allowsOther: question["isOther"].bool == true || options.isEmpty, isSecret: question["isSecret"].bool == true)
        }
        guard Set(inputs.map(\.id)).count == inputs.count else { throw AgentError(message: "Duplicate Codex question IDs: \(params.raw)") }
        let key = id.raw
        guard questions[key] == nil else { throw AgentError(message: "Duplicate Codex question request: \(params.raw)") }
        let request = QuestionRequest(questions: inputs) { [weak self] answers in
            guard let self, !isClosed, let request = questions.removeValue(forKey: key) else { return }
            let values = answers.mapValues { JSONValue.object(["answers": .array($0.map(JSONValue.string))]) }
            do { try transport.reply(id, result: .object(["answers": .object(values)])) }
            catch { onFailure?(error) }
            onEvent?(.questionResolved(request.id))
        }
        questions[key] = request
        onEvent?(.question(request))
    }

    func askFromMessage(_ item: JSONValue) throws {
        guard let values = item["questions"].array, !values.isEmpty else { return }
        let inputs = try values.enumerated().map { index, question in
            let options = try (question["options"].array ?? []).map { option -> InputQuestionOption in
                guard let label = option.string else { throw AgentError(message: "Invalid Codex question option: \(item.raw)") }
                return InputQuestionOption(label: label, description: "")
            }
            return InputQuestion(id: String(index), header: "Question", question: try question.requireString("title"), options: options, allowsOther: true, isSecret: false)
        }
        let key = "message/" + (try item.requireString("id"))
        guard questions[key] == nil else { throw AgentError(message: "Duplicate Codex question message: \(item.raw)") }
        let request = QuestionRequest(questions: inputs, requiresActiveTurn: false) { [weak self] answers in
            guard let self, !isClosed, let request = questions.removeValue(forKey: key) else { return }
            onEvent?(.questionResolved(request.id))
            let text = inputs.compactMap { question -> String? in
                guard let values = answers[question.id], !values.isEmpty else { return nil }
                return question.question + "\n" + values.joined(separator: "\n")
            }.joined(separator: "\n\n")
            if !text.isEmpty { onEvent?(.userReply(text)) }
        }
        questions[key] = request
        onEvent?(.question(request))
    }

    func resolveQuestions(requiresActiveTurn: Bool) {
        let requests = questions.filter { $0.value.requiresActiveTurn == requiresActiveTurn }
        for (key, request) in requests {
            questions.removeValue(forKey: key)
            onEvent?(.questionResolved(request.id))
        }
    }
}
