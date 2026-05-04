import SwiftUI

struct ProjectsSettingsView: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.config.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }

                Button {
                    store.addProjectByPickingFolder()
                } label: {
                    Label("Add project…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .padding(.top, 4)

                Text(
                    "Projects set the working directory for new sessions. "
                        + "Selecting a project in the launcher filters the session list to that project."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        Text("No projects yet. Add one to set its folder as the working directory for new sessions.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            ForEach(Array($store.config.projects.enumerated()), id: \.element.id) { index, $project in
                ProjectRow(project: $project) {
                    store.removeProject(id: project.id)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                if index < store.config.projects.count - 1 {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

private struct ProjectRow: View {
    @Binding var project: Project
    let onDelete: () -> Void

    @State private var labelDraft: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Project name", text: $labelDraft, onCommit: commitLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .semibold))
                    .onAppear { labelDraft = project.label ?? project.displayName }
                    .onChange(of: project.id) { _, _ in
                        labelDraft = project.label ?? project.displayName
                    }
                    .onSubmit(commitLabel)

                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove project")
        }
    }

    private func commitLabel() {
        let trimmed = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let derived = (project.path as NSString).lastPathComponent
        if trimmed.isEmpty || trimmed == derived {
            project.label = nil
            labelDraft = derived
        } else {
            project.label = trimmed
        }
    }
}
