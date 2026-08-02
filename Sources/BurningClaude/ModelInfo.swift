import Foundation

/// Helpers for interpreting the `model` field on a transcript entry.
enum ModelInfo {

    /// Claude Code writes `<synthetic>` for locally generated placeholder
    /// messages (API errors, interrupts). They carry no real usage.
    static func isSynthetic(_ model: String) -> Bool {
        model.isEmpty || model.hasPrefix("<")
    }

    /// Short label for the model breakdown, e.g. `opus-5`, `sonnet-4-6`.
    static func displayName(_ model: String) -> String {
        if isSynthetic(model) { return "synthetic" }
        var s = model
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        // Trim a trailing date snapshot, e.g. "haiku-4-5-20251001".
        let parts = s.split(separator: "-")
        if let last = parts.last, last.count == 8, Int(last) != nil {
            s = parts.dropLast().joined(separator: "-")
        }
        return s
    }
}
