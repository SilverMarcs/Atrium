/// Native gauge needles communicate the selected reasoning effort.
nonisolated enum ComposerReasoningSymbol {
    static func name(for effort: String?) -> String {
        switch effort?.lowercased() {
        case "none", "minimal": "gauge.with.dots.needle.0percent"
        case "low": "gauge.with.dots.needle.33percent"
        case "medium": "gauge.with.dots.needle.50percent"
        case "high": "gauge.with.dots.needle.67percent"
        case "xhigh", "max", "ultra": "gauge.with.dots.needle.100percent"
        default: "gauge.with.needle"
        }
    }
}
