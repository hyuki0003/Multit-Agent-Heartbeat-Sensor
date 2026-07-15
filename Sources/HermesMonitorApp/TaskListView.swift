import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct TaskListView: View {
    let snapshot: HermesMonitorSnapshot
    let selectedTaskID: String?
    let onManualLink: (String, String) -> Void

    @State private var collapsedGroupIDs: Set<String> = []

    var body: some View {
        let groups = TaskGroupBuilder.groups(
            tasks: snapshot.tasks,
            links: snapshot.kanban.links
        )

        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                if group.isStandalone {
                    card(for: group.parent)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if collapsedGroupIDs.contains(group.id) {
                                    collapsedGroupIDs.remove(group.id)
                                } else {
                                    collapsedGroupIDs.insert(group.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(collapsedGroupIDs.contains(group.id) ? -90 : 0))
                                Image(systemName: "square.stack.3d.up.fill")
                                .foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("TASK GROUP")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .tracking(1)
                                    Text(group.parent.task.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(group.completedCount)/\(group.totalCount) done")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.purple)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(Color.purple.opacity(0.14), in: Capsule())
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)

                        if !collapsedGroupIDs.contains(group.id) {
                            card(for: group.parent)

                            VStack(spacing: 8) {
                                ForEach(group.children) { child in
                                    card(for: child)
                                }
                            }
                            .padding(.leading, 14)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.purple.opacity(0.30))
                                    .frame(width: 2)
                                    .padding(.vertical, 4)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
        }
        .onChange(of: selectedTaskID) { taskID in
            guard let taskID,
                  let group = groups.first(where: {
                      $0.parent.id == taskID || $0.children.contains(where: { $0.id == taskID })
                  }) else {
                return
            }
            collapsedGroupIDs.remove(group.id)
        }
    }

    private func card(for item: CorrelatedTask) -> some View {
        TaskCardView(
            item: item,
            runs: snapshot.kanban.runs.filter { $0.taskID == item.id },
            events: snapshot.kanban.events.filter { $0.taskID == item.id },
            comments: snapshot.kanban.comments.filter { $0.taskID == item.id },
            logLines: snapshot.logTails[item.id] ?? [],
            availableSessions: snapshot.state.sessions.sorted { $0.startedAt > $1.startedAt },
            isSelected: selectedTaskID == item.id,
            onManualLink: onManualLink
        )
        .id(item.id)
    }
}
