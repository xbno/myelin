import Foundation
import PaceCore

enum LabelStyle: String, Codable, CaseIterable { case words, letters }

/// How the track and the unspent span are painted. Diagonal hatching keeps them
/// legible over a busy wallpaper; flat reads better against a plain one.
enum BarStyle: String, Codable, CaseIterable { case hatched, solid }

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
    var barStyle: BarStyle = .hatched
    var schedule = Schedule()
    var weekStart = WeekStartSetting()
    var pollSeconds = 180
    var providerEnabled = true          // Anthropic, via the Claude Code login
    var codexEnabled = false            // Codex, via the Codex CLI
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

    /// Whether a provider contributes rows. Keyed by `UsageProvider.id`.
    func isEnabled(_ providerID: String) -> Bool {
        switch providerID {
        case "codex": return codexEnabled
        default: return providerEnabled
        }
    }
}

/// Decoded key by key, each one falling back to its default. The synthesized decoder
/// throws on a key that is missing, which would send `load` to its catch-all and reset
/// every setting the moment a new one is added. In an extension so the memberwise init survives.
extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.init()
        showMark = try c.decodeIfPresent(Bool.self, forKey: .showMark) ?? d.showMark
        labelStyle = try c.decodeIfPresent(LabelStyle.self, forKey: .labelStyle) ?? d.labelStyle
        showHoursLeft = try c.decodeIfPresent(Bool.self, forKey: .showHoursLeft) ?? d.showHoursLeft
        modelRows = try c.decodeIfPresent(ModelRowsSetting.self, forKey: .modelRows) ?? d.modelRows
        usedColor = try c.decodeIfPresent(String.self, forKey: .usedColor) ?? d.usedColor
        unspentColor = try c.decodeIfPresent(String.self, forKey: .unspentColor) ?? d.unspentColor
        overColor = try c.decodeIfPresent(String.self, forKey: .overColor) ?? d.overColor
        modelColors = try c.decodeIfPresent([String: String].self, forKey: .modelColors) ?? d.modelColors
        barStyle = try c.decodeIfPresent(BarStyle.self, forKey: .barStyle) ?? d.barStyle
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? d.schedule
        weekStart = try c.decodeIfPresent(WeekStartSetting.self, forKey: .weekStart) ?? d.weekStart
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? d.pollSeconds
        providerEnabled = try c.decodeIfPresent(Bool.self, forKey: .providerEnabled) ?? d.providerEnabled
        codexEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? d.codexEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }
}
