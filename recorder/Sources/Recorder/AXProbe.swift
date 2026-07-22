import AppKit
import ApplicationServices

/// Feasibility probe for the native (Accessibility) speaker-naming path.
///
/// Reading participant *names* from a meeting app's accessibility tree is easy
/// (they're AXStaticText). Detecting *who is speaking* is the open question —
/// the "speaking" highlight is usually visual (CSS), which may not surface in
/// the AX tree. So this samples the tree over time and reports the two things
/// that matter, filtering out geometry/pointer noise:
///
///   1. the participant-name roster (static-text values), and
///   2. text nodes / semantic attributes whose *values* change as speakers
///      alternate — the candidate "who's talking" signal.
///
/// Usage (grant the *terminal* running this Accessibility; see scripts/ax-spike.sh):
///   recorder --ax-dump  [--app com.google.Chrome]   # one snapshot: roster + controls
///   recorder --ax-watch [--app com.google.Chrome]    # sample ~20s: what changes
enum AXProbe {
    // Attributes that carry meaning we'd use; everything else (geometry,
    // parent/window pointers, text-marker ranges) is noise for this purpose.
    static let semanticAttrs = [
        "AXValue", "AXTitle", "AXDescription", "AXHelp",
        "AXRoleDescription", "AXValueDescription", "AXSelected",
        "AXFocused", "AXExpanded", "AXChecked",
    ]

    static func run(watch: Bool, bundleID: String?) {
        if !ensureTrusted() { return }
        let targets = bundleID.map { [$0] } ?? [
            "com.google.Chrome", "us.zoom.xos", "com.microsoft.teams2",
            "com.microsoft.teams", "com.google.Chrome.beta",
        ]
        guard let app = firstRunning(targets) else {
            Console.error("no target app running (looked for: \(targets.joined(separator: ", ")))")
            return
        }
        Console.status("probing \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = frontWindow(axApp) else {
            Console.error("no window — is the meeting open and frontmost?")
            return
        }
        watch ? watchTree(window) : dumpOnce(window)
    }

    // MARK: - Permission

    private static func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        Console.error(
            "not trusted for Accessibility. Enable the TERMINAL running this under "
            + "Privacy & Security ▸ Accessibility (quit & reopen it after), then re-run.")
        return false
    }

    // MARK: - Discovery

    private static func firstRunning(_ ids: [String]) -> NSRunningApplication? {
        for id in ids {
            if let a = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == id }) { return a }
        }
        return nil
    }

    private static func frontWindow(_ axApp: AXUIElement) -> AXUIElement? {
        if let w = raw(axApp, kAXFocusedWindowAttribute) { return (w as! AXUIElement) }
        if let ws = raw(axApp, kAXWindowsAttribute) as? [AXUIElement] { return ws.first }
        return nil
    }

    // MARK: - Attribute access

    private static func raw(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func attrNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success,
            let arr = names as? [String] else { return [] }
        return arr
    }

    /// Extract a *semantic scalar* (string/bool/number) from a value, or nil for
    /// AXValue geometry, element pointers, arrays, and anything unreadable.
    private static func scalar(_ v: AnyObject?) -> String? {
        guard let v else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((v as! CFBoolean)) ? "true" : "false"
        }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(80))
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil  // AXValue (geometry), AXUIElement, arrays → not useful here
    }

    private static func role(_ el: AXUIElement) -> String {
        (raw(el, kAXRoleAttribute) as? String) ?? "?"
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (raw(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    // MARK: - One-shot dump: roster + controls

    private static func dumpOnce(_ root: AXUIElement) {
        var texts: [String] = []
        var controls: [String] = []
        var speakingAttrs: [String] = []
        walk(root) { el in
            let r = role(el)
            for name in attrNames(el) {
                let lname = name.lowercased()
                if lname.contains("speak") || lname.contains("talk")
                    || lname.contains("active") || lname.contains("announce")
                    || lname.contains("live") {
                    if let s = scalar(raw(el, name)) {
                        speakingAttrs.append("\(name)=\(s)  [\(r)]")
                    }
                }
            }
            if r == "AXStaticText", let s = scalar(raw(el, "AXValue")) { texts.append(s) }
            if r == "AXButton" || r == "AXCheckBox",
               let s = scalar(raw(el, kAXTitleAttribute)) ?? scalar(raw(el, "AXDescription")) {
                controls.append(s)
            }
        }
        print("=== participant/text nodes (AXStaticText values) ===")
        for t in dedupPreservingOrder(texts).prefix(120) { print("  • \(t)") }
        print("\n=== speaking/active/live-named attributes found ===")
        print(speakingAttrs.isEmpty ? "  (none)" : dedupPreservingOrder(speakingAttrs).joined(separator: "\n"))
        print("\n(\(controls.count) buttons seen; \(texts.count) text nodes)")
    }

    // MARK: - Watch: what changes as speakers alternate

    private static func watchTree(_ root: AXUIElement) {
        // Per-user temp dir (0700), not world-readable /tmp — this dumps names
        // scraped from the meeting app's accessibility tree.
        let logPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ax-watch.txt")
        Console.status(
            "sampling ~20s — have DIFFERENT people talk. Full log → \(logPath); "
            + "compact summary below.")
        // snapshot = ordered list of (stableKey -> semantic fingerprint)
        var snaps: [[String: String]] = []
        var textSeq: [Set<String>] = []  // static-text value sets per snapshot
        for i in 0..<16 {
            var fp: [String: String] = [:]
            var texts: Set<String> = []
            walk(root) { el in
                let r = role(el)
                if r == "AXStaticText", let s = scalar(raw(el, "AXValue")) { texts.insert(s) }
                // stable-ish key: role + own name/title + COARSE position, so two
                // participants with the same display name don't collapse together
                // (tiles barely move mid-call; coarse buckets absorb small shifts).
                let nameKey = scalar(raw(el, kAXTitleAttribute))
                    ?? scalar(raw(el, "AXDescription"))
                    ?? scalar(raw(el, "AXValue")) ?? ""
                guard !nameKey.isEmpty else { return }
                let posKey = positionBucket(el)
                var parts: [String] = []
                for a in semanticAttrs {
                    if let s = scalar(raw(el, a)) { parts.append("\(a)=\(s)") }
                }
                // any attribute *named* like a speaking signal, whatever its value
                for a in attrNames(el) {
                    let la = a.lowercased()
                    if la.contains("speak") || la.contains("talk") || la.contains("active")
                        || la.contains("announce") {
                        if let s = scalar(raw(el, a)) { parts.append("\(a)=\(s)") }
                    }
                }
                if !parts.isEmpty { fp["\(r)|\(nameKey)|\(posKey)"] = parts.joined(separator: ",") }
            }
            snaps.append(fp)
            textSeq.append(texts)
            if i < 15 { Thread.sleep(forTimeInterval: 1.25) }
        }

        // Nodes present in every snapshot whose fingerprint changed at least once.
        let common = snaps.dropFirst().reduce(Set(snaps.first?.keys ?? Dictionary<String, String>().keys)) {
            $0.intersection(Set($1.keys))
        }
        var changed: [(node: String, values: [String])] = []
        for node in common {
            let seq = snaps.map { $0[node] ?? "" }
            if Set(seq).count > 1 { changed.append((node, dedupPreservingOrder(seq))) }
        }
        // Static-text values that appeared/disappeared across snapshots (aria-live
        // announcements like "X is presenting" surface here).
        let allTexts = textSeq.reduce(Set<String>()) { $0.union($1) }
        let volatileTexts = allTexts.filter { t in !textSeq.allSatisfy { $0.contains(t) } }

        // Full detail to file; compact summary to console.
        var log = "changed semantic nodes:\n"
        for c in changed.sorted(by: { $0.node < $1.node }) {
            log += "• \(c.node)\n    \(c.values.joined(separator: " → "))\n"
        }
        log += "\nvolatile static-text (appeared/disappeared):\n"
            + volatileTexts.sorted().map { "  • \($0)" }.joined(separator: "\n") + "\n"
        try? log.write(toFile: logPath, atomically: true, encoding: .utf8)

        print("=== semantic attributes that toggled while speakers alternated ===")
        if changed.isEmpty {
            print("  (none — no per-node semantic attribute changed)")
        } else {
            for c in changed.sorted(by: { $0.node < $1.node }).prefix(40) {
                print("  • \(c.node): \(c.values.joined(separator: " → "))")
            }
        }
        print("\n=== static-text that appeared/disappeared (aria-live candidates) ===")
        for t in volatileTexts.sorted().prefix(40) { print("  • \(t)") }
        if changed.isEmpty && volatileTexts.isEmpty {
            print("\n→ nothing in the AX tree tracked the speaker. That points to "
                + "approach B (ScreenCaptureKit visual detection). Full log: \(logPath)")
        } else {
            print("\n→ candidate speaking signal above. Full log: \(logPath)")
        }
    }

    // MARK: - Helpers

    private static func walk(_ root: AXUIElement, _ visit: (AXUIElement) -> Void) {
        var stack = [root]
        var n = 0
        while let el = stack.popLast(), n < 8000 {
            n += 1
            visit(el)
            stack.append(contentsOf: children(el))
        }
    }

    /// Coarse on-screen position bucket (100pt grid) for disambiguating same-named tiles.
    private static func positionBucket(_ el: AXUIElement) -> String {
        guard let v = raw(el, kAXPositionAttribute) else { return "?" }
        var p = CGPoint.zero
        AXValueGetValue((v as! AXValue), .cgPoint, &p)
        return "\(Int(p.x / 100))x\(Int(p.y / 100))"
    }

    private static func dedupPreservingOrder(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); out.append(x) }
        return out
    }
}
