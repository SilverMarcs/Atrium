import Foundation

/// Adjacent blocks of the same kind, so consecutive tool calls show as one badge.
struct TranscriptRun: Identifiable {
    enum Content {
        case text(String)
        case tools([TranscriptBlock])
    }

    let id: String
    var content: Content

    static func runs(in blocks: [TranscriptBlock]) -> [TranscriptRun] {
        var runs: [TranscriptRun] = []
        for block in blocks {
            switch (block.kind, runs.last?.content) {
            case (.text, .text(let text)?):
                runs[runs.count - 1].content = .text(text + "\n\n" + block.text)
            case (.tool, .tools(let tools)?):
                runs[runs.count - 1].content = .tools(tools + [block])
            case (.text, _):
                runs.append(TranscriptRun(id: block.id, content: .text(block.text)))
            case (.tool, _):
                runs.append(TranscriptRun(id: block.id, content: .tools([block])))
            }
        }
        return runs
    }
}
