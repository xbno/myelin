import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline data

struct TaskRow: Identifiable, Hashable {
    let id: String
    let listID: String
    let title: String
    let due: String?     // yyyy-MM-dd
    let isSubtask: Bool
}

struct TaskSection: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [TaskRow]
}

struct TasksEntry: TimelineEntry {
    let date: Date
    let title: String
    let sections: [TaskSection]
    let showSectionHeaders: Bool
    let error: String?

    var total: Int { sections.reduce(0) { $0 + $1.rows.count } }

    static let sample = TasksEntry(
        date: .now,
        title: "Tasks",
        sections: [
            TaskSection(id: "a", title: "Acme", rows: [
                TaskRow(id: "1", listID: "a", title: "Kickoff prep", due: nil, isSubtask: false),
                TaskRow(id: "2", listID: "a", title: "Draft agenda", due: nil, isSubtask: true),
            ]),
            TaskSection(id: "b", title: "Globex", rows: [
                TaskRow(id: "3", listID: "b", title: "Quarterly report", due: nil, isSubtask: false),
            ]),
        ],
        showSectionHeaders: true,
        error: nil
    )
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TasksEntry { .sample }

    func snapshot(for configuration: SelectListIntent, in context: Context) async -> TasksEntry {
        context.isPreview ? .sample : await load(configuration)
    }

    func timeline(for configuration: SelectListIntent, in context: Context) async -> Timeline<TasksEntry> {
        let entry = await load(configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func load(_ configuration: SelectListIntent) async -> TasksEntry {
        let client = GoogleTasksClient()
        do {
            var lists = try await client.lists()
            if let chosen = configuration.list {
                lists = lists.filter { $0.id == chosen.id }
            }
            var sections: [TaskSection] = []
            for list in lists {
                let tasks = try await client.openTasks(listID: list.id)
                let rows = Self.ordered(tasks, listID: list.id)
                if !rows.isEmpty || configuration.list != nil {
                    sections.append(TaskSection(id: list.id, title: list.title, rows: rows))
                }
            }
            return TasksEntry(
                date: .now,
                title: configuration.list?.title ?? "Tasks",
                sections: sections,
                showSectionHeaders: configuration.list == nil,
                error: nil
            )
        } catch {
            return TasksEntry(
                date: .now,
                title: configuration.list?.title ?? "Tasks",
                sections: [],
                showSectionHeaders: false,
                error: error.localizedDescription
            )
        }
    }

    /// Parents in list order, each followed by its subtasks.
    static func ordered(_ tasks: [GTask], listID: String) -> [TaskRow] {
        let sorted = tasks.sorted { ($0.position ?? "") < ($1.position ?? "") }
        let ids = Set(sorted.map(\.id))
        let parents = sorted.filter { $0.parent == nil || !ids.contains($0.parent!) }
        var children: [String: [GTask]] = [:]
        for task in sorted {
            if let parent = task.parent, ids.contains(parent) {
                children[parent, default: []].append(task)
            }
        }
        func row(_ t: GTask, sub: Bool) -> TaskRow {
            TaskRow(
                id: t.id,
                listID: listID,
                title: (t.title?.isEmpty == false ? t.title! : "(untitled)"),
                due: t.due.map { String($0.prefix(10)) },
                isSubtask: sub
            )
        }
        var out: [TaskRow] = []
        for parent in parents {
            out.append(row(parent, sub: false))
            out += (children[parent.id] ?? []).map { row($0, sub: true) }
        }
        return out
    }
}

// MARK: - Views

private enum Line: Identifiable {
    case header(TaskSection)
    case task(TaskRow)

    var id: String {
        switch self {
        case .header(let s): return "h-\(s.id)"
        case .task(let r): return "t-\(r.id)"
        }
    }
}

private enum DueFormat {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Returns a label like "Today", "Tomorrow", "Sep 30" and whether it is overdue.
    static func label(_ due: String?) -> (String, Bool)? {
        guard let due, let day = dayFormatter.date(from: due) else { return nil }
        let today = dayFormatter.string(from: .now)
        if due < today { return (shortFormatter.string(from: day), true) }
        if due == today { return ("Today", false) }
        let tomorrow = dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
        if due == tomorrow { return ("Tomorrow", false) }
        return (shortFormatter.string(from: day), false)
    }
}

struct GTasksWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TasksEntry

    private var maxLines: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 5
        case .systemLarge: return 13
        default: return 13
        }
    }

    private var lines: [Line] {
        var out: [Line] = []
        for section in entry.sections {
            if entry.showSectionHeaders { out.append(.header(section)) }
            out += section.rows.map { Line.task($0) }
        }
        // Don't end on a dangling header.
        var clipped = Array(out.prefix(maxLines))
        if case .some(.header) = clipped.last { clipped.removeLast() }
        return clipped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                Spacer()
                Text("\(entry.total)")
                    .font(.system(size: family == .systemSmall ? 22 : 26, weight: .bold, design: .rounded))
            }
            Divider()

            if let error = entry.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if entry.total == 0 {
                Spacer()
                Text("All done")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(lines) { line in
                    switch line {
                    case .header(let section):
                        Text(section.title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    case .task(let row):
                        TaskRowView(row: row, compact: family == .systemSmall)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "https://tasks.google.com"))
    }
}

private struct TaskRowView: View {
    let row: TaskRow
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: CompleteTaskIntent(listID: row.listID, taskID: row.id)) {
                Image(systemName: "circle")
                    .font(compact ? .caption : .body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(row.title)
                .font(compact ? .caption : .subheadline)
                .lineLimit(1)

            Spacer(minLength: 4)

            if !compact, let due = DueFormat.label(row.due) {
                Text(due.0)
                    .font(.caption2)
                    .foregroundStyle(due.1 ? Color.red : Color.secondary)
            }
        }
        .padding(.leading, row.isSubtask ? 18 : 0)
    }
}

// MARK: - Widget

struct GTasksWidget: Widget {
    let kind = "GTasksWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectListIntent.self, provider: Provider()) { entry in
            GTasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Google Tasks")
        .description("Open tasks from one list, or all lists grouped.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct GTasksWidgetBundle: WidgetBundle {
    var body: some Widget {
        GTasksWidget()
    }
}
