import SwiftUI
import PaceCore

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Claude Code mark", isOn: $store.settings.showMark)
                Picker("Labels", selection: $store.settings.labelStyle) {
                    Text("Words · Sess, Week, Fable").tag(LabelStyle.words)
                    Text("Letters · S, W, F").tag(LabelStyle.letters)
                }
                Toggle("Hours left after the bars", isOn: $store.settings.showHoursLeft)
                Picker("Bar fill", selection: $store.settings.barStyle) {
                    Text("Hatched · diagonal lines").tag(BarStyle.hatched)
                    Text("Solid · flat tint").tag(BarStyle.solid)
                }
                Picker("Model rows", selection: $store.settings.modelRows.mode) {
                    Text("All models the account reports").tag(ModelRowsSetting.Mode.all)
                    Text("Most constrained only").tag(ModelRowsSetting.Mode.mostConstrained)
                    Text("One model").tag(ModelRowsSetting.Mode.fixed)
                }
                if store.settings.modelRows.mode == .fixed {
                    Picker("Model", selection: $store.settings.modelRows.fixedName) {
                        ForEach(modelNames, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section("Colors") {
                colorRow("Used, up to the tick", $store.settings.usedColor)
                colorRow("Unspent, fill to tick", $store.settings.unspentColor)
                colorRow("Over, tick to fill", $store.settings.overColor)
                ForEach(modelNames, id: \.self) { name in
                    colorRow(name, Binding(
                        get: { store.settings.modelColor(name) },
                        set: { store.settings.modelColors[name] = $0 }))
                }
            }
            Section("Pace model") {
                Toggle("Week starts at the account's reset", isOn: $store.settings.weekStart.useAccount)
                if store.settings.weekStart.useAccount {
                    LabeledContent("Reset", value: store.weekWindowEnd().map { Fmt.clock($0, now: store.now, calendar: store.calendar) } ?? "waiting for data")
                } else {
                    Picker("Weekday", selection: $store.settings.weekStart.weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }
                    Stepper("Hour: \(hour(store.settings.weekStart.hour))", value: $store.settings.weekStart.hour, in: 0...23)
                }
                Toggle("Include weekends", isOn: $store.settings.schedule.includesWeekends)
                Stepper("Working hours start: \(hour(store.settings.schedule.startHour))",
                        value: $store.settings.schedule.startHour, in: 0...23)
                    .onChange(of: store.settings.schedule.startHour) { _, v in
                        if store.settings.schedule.endHour <= v { store.settings.schedule.endHour = v + 1 }
                    }
                Stepper("Working hours end: \(hour(store.settings.schedule.endHour))",
                        value: $store.settings.schedule.endHour, in: 1...24)
                    .onChange(of: store.settings.schedule.endHour) { _, v in
                        if store.settings.schedule.startHour >= v { store.settings.schedule.startHour = v - 1 }
                    }
                HStack {
                    Text("On-pace band ±\(Int(store.settings.schedule.onPaceBand)) pts")
                    Slider(value: $store.settings.schedule.onPaceBand, in: 0...15, step: 1)
                }
            }
            Section("Providers") {
                Toggle("Anthropic, via Claude Code login", isOn: $store.settings.providerEnabled)
                LabeledContent("Status", value: providerStatus)
                Picker("Poll every", selection: $store.settings.pollSeconds) {
                    Text("30 s").tag(30)
                    Text("60 s").tag(60)
                    Text("2 min").tag(120)
                    Text("3 min").tag(180)
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
                }
                Text("The usage API rate-limits aggressive polling. On a 429 Pace keeps the last numbers and backs off, doubling up to 30 minutes.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { store.settings.launchAtLogin = $0; LaunchAtLogin.apply($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private var modelNames: [String] {
        let fromData = store.snapshot?.models.compactMap(\.modelName) ?? []
        return Array(Set(fromData + Array(store.settings.modelColors.keys))).sorted()
    }

    private var providerStatus: String {
        if store.isLoggedOut { return "not logged in, open Claude Code" }
        if let since = store.staleSince { return "stale since \(Fmt.clock(since, now: store.now, calendar: store.calendar))" }
        if store.snapshot != nil { return "token fresh" }
        return "waiting"
    }

    private func hour(_ h: Int) -> String {
        if h >= 24 { return "midnight" }
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return Fmt.clock(date, now: Date(), calendar: .current)
    }

    private func colorRow(_ label: String, _ hex: Binding<String>) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(hex: hex.wrappedValue) },
            set: { hex.wrappedValue = $0.hexString }), supportsOpacity: false)
    }
}
