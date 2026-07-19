import Foundation
import Network

/// Localhost ingest for meeting-app speaker hints. The meet-tap browser
/// extension POSTs {"names":["Alice"]} to /speaking whenever the platform's
/// active speaker changes (empty names = silence). Hints are stored as time
/// intervals; per utterance, a confident single-name hint beats the
/// diarizer's anonymous S-label — and is also fed back to name the diarizer's
/// voice slot, so identification keeps working when hints stop (screen share,
/// captions off, next call on a different platform).
final class MeetHints {
    private struct Interval {
        let start: Date
        var end: Date?
        let names: [String]
    }

    private let lock = NSLock()
    private var intervals: [Interval] = []
    private var listener: NWListener?

    func start(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RecorderError("invalid meet-tap port \(port)")
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receive(connection, buffered: Data())
        }
        listener.start(queue: .global())
        self.listener = listener
        Console.status("meet-tap hint listener on http://127.0.0.1:\(port)/speaking")
    }

    func stop() {
        listener?.cancel()
    }

    // MARK: - Hint store

    private func record(names: [String]) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if !intervals.isEmpty, intervals[intervals.count - 1].end == nil {
            intervals[intervals.count - 1].end = now
        }
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 60 }
        if !cleaned.isEmpty {
            intervals.append(Interval(start: now, end: nil, names: cleaned))
        }
        // Keep memory bounded on long calls.
        if intervals.count > 20_000 {
            intervals.removeFirst(intervals.count - 20_000)
        }
    }

    /// Dominant hinted name over the wall-clock window, or nil when there is
    /// no hint covering ≥40% of it (or the window is contested between names).
    func query(w0: Date, w1: Date) -> String? {
        let span = w1.timeIntervalSince(w0)
        guard span > 0 else { return nil }
        let now = Date()
        lock.lock()
        let snapshot = intervals
        lock.unlock()

        var coverage: [String: Double] = [:]
        for interval in snapshot {
            let end = interval.end ?? now
            let overlap = min(end, w1).timeIntervalSince(max(interval.start, w0))
            guard overlap > 0 else { continue }
            for name in interval.names {
                coverage[name, default: 0] += overlap
            }
        }
        let ranked = coverage.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 0.4 * span else { return nil }
        if ranked.count > 1, ranked[1].value > 0.5 * best.value { return nil }  // contested
        return best.key
    }

    // MARK: - Minimal HTTP handling (localhost only, tiny bodies)

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            var buffer = buffered
            buffer.append(data)
            if let response = self.handle(request: buffer) {
                connection.send(
                    content: response,
                    completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete {
                connection.cancel()
            } else if buffer.count < 65_536 {
                self.receive(connection, buffered: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    /// Returns a response once the request is fully buffered, nil to keep reading.
    private func handle(request: Data) -> Data? {
        guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: request[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let method = requestLine.components(separatedBy: " ").first ?? ""

        if method == "OPTIONS" { return Self.response(status: "204 No Content") }
        guard method == "POST" else { return Self.response(status: "405 Method Not Allowed") }

        var contentLength = 0
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = request[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }

        var names: [String] = []
        if let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
            let list = obj["names"] as? [Any]
        {
            names = list.compactMap { $0 as? String }
        }
        record(names: names)
        return Self.response(status: "204 No Content")
    }

    private static func response(status: String) -> Data {
        Data(
            """
            HTTP/1.1 \(status)\r
            Access-Control-Allow-Origin: *\r
            Access-Control-Allow-Methods: POST, OPTIONS\r
            Access-Control-Allow-Headers: *\r
            Content-Length: 0\r
            Connection: close\r
            \r

            """.utf8)
    }
}
