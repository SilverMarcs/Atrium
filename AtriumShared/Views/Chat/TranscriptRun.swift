import Foundation

/// Adjacent blocks of the same kind, so consecutive notes read as one.
struct TranscriptRun: Identifiable {
    enum Content {
        case text(String)
        case tools(Int)
    }

    let id: String
    var content: Content

    static func runs(in blocks: [TranscriptBlock]) -> [TranscriptRun] {
        var runs: [TranscriptRun] = []
        for block in blocks {
            switch (block, runs.last?.content) {
            case (.text(let text, _), .text(let previous)?):
                runs[runs.count - 1].content = .text(previous + "\n\n" + text)
            case (.tools(let count, _), .tools(let previous)?):
                runs[runs.count - 1].content = .tools(previous + count)
            case (.text(let text, let id), _):
                runs.append(TranscriptRun(id: id, content: .text(text)))
            case (.tools(let count, let id), _):
                runs.append(TranscriptRun(id: id, content: .tools(count)))
            }
        }
        return runs
    }
}
