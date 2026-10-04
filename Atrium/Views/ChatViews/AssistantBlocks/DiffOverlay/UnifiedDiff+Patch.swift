import Foundation

extension UnifiedDiff {
    static func patchLines(_ patch: String) -> [SharedDiffLine] {
        var result: [SharedDiffLine] = []
        var oldLine: Int?
        var newLine: Int?
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@ ") {
                let ranges = line.split(separator: " ")
                oldLine = ranges.count > 2 ? ranges[1].dropFirst().split(separator: ",").first.flatMap { Int($0) } : nil
                newLine = ranges.count > 2 ? ranges[2].dropFirst().split(separator: ",").first.flatMap { Int($0) } : nil
                continue
            }
            guard let old = oldLine, let new = newLine, let prefix = line.first else { continue }
            let content = String(line.dropFirst())
            switch prefix {
            case "-":
                result.append(SharedDiffLine(content: content, kind: .removed, oldLineNumber: old, newLineNumber: nil))
                oldLine = old + 1
            case "+":
                result.append(SharedDiffLine(content: content, kind: .added, oldLineNumber: nil, newLineNumber: new))
                newLine = new + 1
            case " ":
                result.append(SharedDiffLine(content: content, kind: nil, oldLineNumber: old, newLineNumber: new))
                oldLine = old + 1
                newLine = new + 1
            default: break
            }
        }
        return result
    }
}
