import Foundation
import PaceCore

enum LabelStyle: String, Codable, CaseIterable { case words, letters }

struct ModelRowsSetting: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case all, mostConstrained, fixed }
    var mode: Mode = .all
    var fixedName: String = ""
}

/// Where the week's day blocks are anchored. Calendar weekday numbering: 6 = Friday.
struct WeekStartSetting: Codable, Equatable {
    var useAccount = true
    var weekday = 6
    var hour = 17
    var minute = 0
}

/// Everything the user can change. Stored as JSON in UserDefaults.
struct AppSettings: Codable, Equatable {
    var showMark = true
    var labelStyle: LabelStyle = .words
    var showHoursLeft = false
    var modelRows = ModelRowsSetting()
    var usedColor = "#0CA30C"
    var unspentColor = "#FAB219"
    var overColor = "#D03B3B"
    var modelColors: [String: String] = ["Fable": AppSettings.claudeOrange]
    var schedule = Schedule()
    var weekStart = WeekStartSetting()
    var pollSeconds = 60
    var providerEnabled = true
    var launchAtLogin = false

    static let claudeOrange = "#D97757"
    static let key = "pace.settings"

    static func load(defaults: UserDefaults = .standard) -> AppSettings {
        if let data = defaults.data(forKey: key),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        return AppSettings()
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// Fable defaults to Claude orange; any other model starts neutral until the user picks a color.
    func modelColor(_ name: String) -> String { modelColors[name] ?? "#898781" }
}
