import SwiftUI

struct SettingsView: View {
    @State private var selection: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape.fill")
                    .tag(SettingsTab.general)
                Label("Agents", systemImage: "sparkles.rectangle.stack")
                    .tag(SettingsTab.agents)
                Label("Prompts", systemImage: "quote.bubble")
                    .tag(SettingsTab.prompts)
                Label("Projects", systemImage: "folder")
                    .tag(SettingsTab.projects)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selection {
            case .general:
                GeneralSettingsView()
                    .navigationTitle("General")
            case .agents:
                AgentsSettingsView()
                    .navigationTitle("Agents")
            case .prompts:
                PromptsSettingsView()
                    .navigationTitle("Prompts")
            case .projects:
                ProjectsSettingsView()
                    .navigationTitle("Projects")
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

private enum SettingsTab: Hashable {
    case general
    case agents
    case prompts
    case projects
}
