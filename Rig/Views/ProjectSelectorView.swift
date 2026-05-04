import SwiftUI

struct ProjectSelectorView: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        Menu {
            menuContent
        } label: {
            triggerLabel
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var triggerLabel: some View {
        HStack(spacing: 4) {
            Text(store.selectedProject?.displayName ?? "Project")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 110)
        .background {
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        let recent = store.recentProjects
        let recentIDs = store.recentProjectIDs
        let overflow = store.allProjectsByRecency.filter { !recentIDs.contains($0.id) }

        if recent.isEmpty {
            Text("No projects yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(recent) { project in
                Button {
                    store.selectProject(id: project.id)
                } label: {
                    if store.config.preferences.selectedProjectID == project.id {
                        Label(project.displayName, systemImage: "checkmark")
                    } else {
                        Text(project.displayName)
                    }
                }
            }
        }

        if !overflow.isEmpty {
            Divider()
            Menu("Show all") {
                ForEach(overflow) { project in
                    Button {
                        store.selectProject(id: project.id)
                    } label: {
                        Text(project.displayName)
                    }
                }
            }
        }

        Divider()

        Button {
            store.addProjectByPickingFolder()
        } label: {
            Label("Add new…", systemImage: "plus")
        }
    }
}
