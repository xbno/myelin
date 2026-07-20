#if canImport(Darwin)
    import Darwin
#endif
import Foundation

/// Terminal feedback. Volatile (in-progress) hypotheses repaint a single status
/// line; finalized lines are printed permanently. Transcript JSONL is the source
/// of truth — this is just so you can see it working.
enum Console {
    private static let lock = NSLock()
    private static var lastVolatileLength = 0
    private static let isTTY = isatty(fileno(stderr)) != 0

    /// Current terminal width; the volatile line is truncated to this so it
    /// stays on ONE row — a wrapped volatile line breaks the clear-and-repaint
    /// (only the last row clears), which stacks stale rows on every update.
    private static func termWidth() -> Int {
        var w = winsize()
        if ioctl(fileno(stderr), UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0 {
            return Int(w.ws_col)
        }
        if let cols = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(cols), n > 0 {
            return n
        }
        return 80
    }

    private static func clearVolatile_locked() {
        guard isTTY, lastVolatileLength > 0 else { return }
        // The previous volatile line may now span multiple physical rows if the
        // terminal was resized narrower since it was printed. Clear every row it
        // occupies AT THE CURRENT WIDTH: clear the bottom row, then move up and
        // clear each row above. ceil(len / width) rows.
        let w = max(1, termWidth())
        let rows = max(1, (lastVolatileLength + w - 1) / w)
        var seq = "\r\u{1B}[2K"
        for _ in 1..<rows {
            seq += "\u{1B}[1A\u{1B}[2K"
        }
        FileHandle.standardError.write(Data(seq.utf8))
        lastVolatileLength = 0
    }

    static func volatileLine(source: String, text: String) {
        guard isTTY else { return }
        lock.lock()
        defer { lock.unlock() }
        clearVolatile_locked()
        let tag = source == "mic" ? "me " : "them"
        // one physical row only: collapse newlines, truncate to terminal width
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        var line = "· \(tag)> \(flat)"
        let maxw = max(20, termWidth() - 1)
        if line.count > maxw {
            line = String(line.prefix(maxw - 1)) + "…"
        }
        FileHandle.standardError.write(Data(line.utf8))
        lastVolatileLength = line.count
    }

    static func finalLine(source: String, speaker: String? = nil, text: String) {
        lock.lock()
        defer { lock.unlock() }
        clearVolatile_locked()
        let tag = speaker ?? (source == "mic" ? "me " : "them")
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
