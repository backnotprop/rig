import SwiftUI

struct SettingsView: View {
    @State private var selection: SettingsTab = .agents

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Agents", systemImage: "person.2.gearshape")
                    .tag(SettingsTab.agents)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selection {
            case .agents:
                AgentsSettingsView()
                    .navigationTitle("Agents")
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

private enum SettingsTab: Hashable {
    case agents
}
