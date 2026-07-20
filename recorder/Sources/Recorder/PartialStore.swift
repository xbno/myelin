import Foundation

/// Current in-flight (volatile) hypothesis per channel, for the live view.
/// Never written to the transcript — finals replace these at full accuracy.
final class PartialStore {
    private let lock = NSLock()
    private var entries: [String: (text: String, at: Date)] = [:]

    func set(_ source: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        entries[source] = (trimmed, Date())
        lock.unlock()
    }

    func clear(_ source: String) {
        lock.lock()
        entries.removeValue(forKey: source)
        lock.unlock()
    }

    /// {"mic": "current words…", "system": "…"} — stale entries dropped.
    func json() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let fresh = entries.filter { now.timeIntervalSince($0.value.at) < 10 }
        return (try? JSONSerialization.data(withJSONObject: fresh.mapValues { $0.text }))
            ?? Data("{}".utf8)
    }
}
