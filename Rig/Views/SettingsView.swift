import SwiftUI

struct SettingsView: View {
    @State private var selection: SettingsTab = .agents

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Agents", systemImage: "sparkles.rectangle.stack")
                    .tag(SettingsTab.agents)
                Label("Projects", systemImage: "folder")
                    .tag(SettingsTab.projects)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selection {
            case .agents:
                AgentsSettingsView()
                    .navigationTitle("Agents")
            case .projects:
                ProjectsSettingsView()
                    .navigationTitle("Projects")
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

private enum SettingsTab: Hashable {
    case agents
    case projects
}
