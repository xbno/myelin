import Foundation

/// Serializes transcript lines from both channels into one append-only JSONL file.
/// One line per finalized utterance:
///   {"ts":"…","source":"mic|system","speaker":"S1","t0":12.34,"t1":15.60,"text":"…"}
/// (speaker appears once diarization is enabled; mic lines are always the local user.)
actor TranscriptWriter {
    private let handle: FileHandle
    private var lineCount = 0
    private let iso: ISO8601DateFormatter

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle.seekToEnd()
        self.iso = ISO8601DateFormatter()
    }

    func write(source: String, text: String, t0: Double?, t1: Double?, speaker: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard
            let textData = try? JSONSerialization.data(
                withJSONObject: trimmed, options: .fragmentsAllowed),
            let escapedText = String(data: textData, encoding: .utf8)
        else { return }

        var fields: [String] = [
            "\"ts\":\"\(iso.string(from: Date()))\"",
            "\"source\":\"\(source)\"",
        ]
        if let speaker { fields.append("\"speaker\":\"\(speaker)\"") }
        if let t0 { fields.append("\"t0\":\(String(format: "%.2f", t0))") }
        if let t1 { fields.append("\"t1\":\(String(format: "%.2f", t1))") }
        fields.append("\"text\":\(escapedText)")

        handle.write(Data(("{" + fields.joined(separator: ",") + "}\n").utf8))
        try? handle.synchronize()
        lineCount += 1
    }

    func close() {
        try? handle.close()
    }

    var count: Int { lineCount }
}
