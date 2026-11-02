import AppIntents
import WidgetKit

// MARK: - Which list the widget shows (right-click the widget → Edit "Google Tasks")

struct TaskListEntity: AppEntity {
    let id: String
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Task List" }
    static var defaultQuery: TaskListQuery { TaskListQuery() }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct TaskListQuery: EntityQuery {
    func entities(for identifiers: [TaskListEntity.ID]) async throws -> [TaskListEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TaskListEntity] {
        try await GoogleTasksClient().lists().map { TaskListEntity(id: $0.id, title: $0.title) }
    }
}

struct SelectListIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Choose List" }
    static var description: IntentDescription { "Show one Google Tasks list, or leave empty to show all lists grouped." }

    @Parameter(title: "List")
    var list: TaskListEntity?

    init() {}
}

// MARK: - Click the circle to complete a task

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource { "Complete Task" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "List ID")
    var listID: String

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(listID: String, taskID: String) {
        self.listID = listID
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        try await GoogleTasksClient().complete(listID: listID, taskID: taskID)
        // WidgetKit reloads the timeline after an interactive intent finishes.
        return .result()
    }
}
