import Foundation

@main
enum ComposerControlChecks {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        try check(ComposerReasoningSymbol.name(for: "low") != ComposerReasoningSymbol.name(for: "high"), "Reasoning levels must move the gauge needle")
        try check(ComposerReasoningSymbol.name(for: "xhigh") == "gauge.with.dots.needle.100percent", "Extra High must use the fullest gauge")
        try check(ComposerReasoningSymbol.name(for: nil) == "gauge.with.needle", "Unknown effort must not imply a selected level")
        print("Composer reasoning symbol checks passed")
    }
}
