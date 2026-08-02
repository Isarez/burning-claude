import Foundation

/// Reads Claude Code's local transcripts and turns them into deduplicated
/// usage events.
///
/// Two things make this less trivial than "sum the usage fields":
///
///  1. **Duplicates.** Resuming or forking a session rewrites earlier turns
///     into the new transcript file, so the same assistant response appears in
///     several files. On a real history roughly half of all entries are
///     repeats. Summing naively roughly doubles every figure, so every entry
///     is deduplicated globally on `message.id`.
///  2. **Volume.** Transcripts only ever grow, so each file is read from the
///     byte offset where the last scan stopped rather than re-parsed in full.
final class UsageScanner {

    struct FileState: Codable {
        var offset: UInt64
        var size: UInt64
        var modified: Date
    }

    private struct ScanState: Codable {
        var files: [String: FileState] = [:]
        var seenMessageIDs: [String] = []
    }

    private var files: [String: FileState]
    private var seen: Set<String>
    private let registry: AccountRegistry

    init(registry: AccountRegistry) {
        self.registry = registry
        let s = Storage.load(ScanState.self, from: Storage.scanStateFile) ?? ScanState()
        files = s.files
        seen = Set(s.seenMessageIDs)
    }

    /// Discards all incremental state so the next scan re-reads every file.
    func reset() {
        files = [:]
        seen = []
        persist()
    }

    /// Everything a scan pass produced.
    struct ScanResult {
        var usage: [UsageEvent] = []
        var limits: [LimitEvent] = []

        mutating func merge(_ other: ScanResult) {
            usage.append(contentsOf: other.usage)
            limits.append(contentsOf: other.limits)
        }
    }

    /// Scan every root and return only records not previously seen.
    func scan(roots: [ConfigRoot]) -> ScanResult {
        var result = ScanResult()
        for root in roots {
            result.merge(scan(root: root))
        }
        persist()
        return result
    }

    private func scan(root: ConfigRoot) -> ScanResult {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root.projectsURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ScanResult() }

        var result = ScanResult()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            result.merge(scan(file: url, root: root))
        }
        return result
    }

    private func scan(file url: URL, root: ConfigRoot) -> ScanResult {
        let path = url.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast

        var start: UInt64 = 0
        if let prior = files[path] {
            if prior.size == size && prior.modified == modified { return ScanResult() }
            // Transcripts are append-only; a shrink means the file was replaced.
            start = size >= prior.size ? prior.offset : 0
        }
        guard size > start else {
            files[path] = FileState(offset: size, size: size, modified: modified)
            return ScanResult()
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return ScanResult() }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ScanResult() }

        // Only consume up to the last newline: a final partial line means Claude
        // Code is mid-write, and re-reading it next scan is cheaper than
        // dropping a record.
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            files[path] = FileState(offset: start, size: size, modified: modified)
            return ScanResult()
        }
        let complete = data[data.startIndex...lastNewline]
        let consumed = start + UInt64(complete.count)

        var result = ScanResult()
        for line in complete.split(separator: 0x0A) where !line.isEmpty {
            parse(line: Data(line), root: root, into: &result)
        }

        files[path] = FileState(offset: consumed, size: size, modified: modified)
        return result
    }

    private func parse(line: Data, root: ConfigRoot, into result: inout ScanResult) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any]
        else { return }

        // Deduplicate on the API's message id: the same response replayed into
        // a resumed transcript keeps its original id.
        guard let messageID = message["id"] as? String, !seen.contains(messageID) else { return }

        guard let tsString = obj["timestamp"] as? String,
              let timestamp = ISO8601.date(from: tsString)
        else { return }

        // A 429 carries no usage, but it is the only local record of where the
        // plan limits actually sit — capture it before the synthetic filter.
        if (obj["apiErrorStatus"] as? NSNumber)?.intValue == 429 {
            seen.insert(messageID)
            if let limit = LimitParser.parse(
                text: Self.plainText(message["content"]), hitAt: timestamp, rootID: root.id
            ) {
                result.limits.append(limit)
            }
            return
        }

        guard let usage = message["usage"] as? [String: Any] else { return }

        let model = message["model"] as? String ?? ""
        guard !ModelInfo.isSynthetic(model) else {
            seen.insert(messageID)
            return
        }

        seen.insert(messageID)

        func int(_ dict: [String: Any], _ key: String) -> Int {
            (dict[key] as? NSNumber)?.intValue ?? 0
        }

        var tokens = TokenCounts()
        tokens.input = int(usage, "input_tokens")
        tokens.output = int(usage, "output_tokens")
        tokens.cacheRead = int(usage, "cache_read_input_tokens")

        if let creation = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite5m = int(creation, "ephemeral_5m_input_tokens")
            tokens.cacheWrite1h = int(creation, "ephemeral_1h_input_tokens")
        } else {
            // Older transcripts only carry the combined counter; assume the
            // 5-minute rate, which is the default TTL.
            tokens.cacheWrite5m = int(usage, "cache_creation_input_tokens")
        }

        let attribution = registry.attribute(rootID: root.id, at: timestamp)
        result.usage.append(UsageEvent(
            timestamp: timestamp,
            model: model,
            accountUUID: attribution.uuid,
            rootID: root.id,
            tokens: tokens,
            inferredAccount: attribution.inferred,
            fast: (usage["speed"] as? String) == "fast"
        ))
    }

    /// Flattens a message `content` field, which is either a string or an
    /// array of blocks, into searchable text.
    private static func plainText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    private func persist() {
        Storage.save(ScanState(files: files, seenMessageIDs: Array(seen)), to: Storage.scanStateFile)
    }
}
