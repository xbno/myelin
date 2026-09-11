import Foundation

public enum Fmt {
    /// "74h" at ten hours and above, "3h 39m" below, "39m" under an hour.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0m" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes))m" }
        let h = minutes / 60
        let m = minutes % 60
        if h < 10 { return "\(h)h \(m)m" }
        return "\(Int((seconds / 3600).rounded()))h"
    }

    /// Menu bar variant: whole hours, minutes only under an hour.
    public static func hoursOnly(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0h" }
        if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        return "\(Int((seconds / 3600).rounded()))h"
    }

    /// "Fri 5:00 pm", or "6:31 pm" when `date` falls on the same day as `now`.
    public static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }

    /// "12 s ago", "3 min ago", "2 h ago".
    public static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }
}
