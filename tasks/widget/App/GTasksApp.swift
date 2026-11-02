import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

@main
struct GTasksApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var status = SharedStore.loadConfig() == nil ? "Not connected." : "Connected."
    @State private var lists: [GTaskList] = []
    @State private var importing = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Google Tasks Widget").font(.title2.bold())

            Text("1. Finish the bridge setup in tasks/README.md.\n2. Import tasks/bridge.json (Cmd+Shift+G in the picker to type the path).\n3. Right-click the desktop → Edit Widgets → search \"Google Tasks\".")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Import bridge.json…") { importing = true }
                Button("Test connection") { Task { await test() } }
                    .disabled(busy)
                Button("Refresh widgets") { WidgetCenter.shared.reloadAllTimelines() }
                Spacer()
                Button("Disconnect", role: .destructive) {
                    SharedStore.clear()
                    lists = []
                    status = "Not connected."
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }

            Text(status)
                .font(.callout)
                .textSelection(.enabled)

            if !lists.isEmpty {
                Text("Lists: " + lists.map(\.title).joined(separator: ", "))
                    .font(.callout)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                importConfig(from: url)
            case .failure(let error):
                status = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func importConfig(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            _ = try SharedStore.importBridgeJSON(data)
            status = "Imported. Testing…"
            Task { await test() }
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func test() async {
        busy = true
        defer { busy = false }
        do {
            lists = try await GoogleTasksClient().lists()
            status = "Connected. Found \(lists.count) list(s)."
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lists = []
            status = error.localizedDescription
        }
    }
}
