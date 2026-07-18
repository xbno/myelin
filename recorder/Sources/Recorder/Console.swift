import Foundation

/// Terminal feedback. Volatile (in-progress) hypotheses repaint a single status
/// line; finalized lines are printed permanently. Transcript JSONL is the source
/// of truth — this is just so you can see it working.
enum Console {
    private static let lock = NSLock()
    private static var lastVolatileLength = 0
    private static let isTTY = isatty(fileno(stderr)) != 0

    private static func clearVolatile_locked() {
        guard isTTY, lastVolatileLength > 0 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
        lastVolatileLength = 0
    }

    static func volatileLine(source: String, text: String) {
        guard isTTY else { return }
        lock.lock()
        defer { lock.unlock() }
        clearVolatile_locked()
        let tag = source == "mic" ? "me " : "them"
        var line = "· \(tag)> \(text)"
        if line.count > 120 { line = "…" + line.suffix(119) }
        FileHandle.standardError.write(Data(line.utf8))
        lastVolatileLength = line.count
    }

    static func finalLine(source: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        clearVolatile_locked()
        let tag = source == "mic" ? "me " : "them"
        FileHandle.standardError.write(Data("\(tag)> \(text)\n".utf8))
    }

    static func status(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        clearVolatile_locked()
        FileHandle.standardError.write(Data("[recorder] \(message)\n".utf8))
    }

    static func error(_ message: String) {
        status("error: \(message)")
    }
}
