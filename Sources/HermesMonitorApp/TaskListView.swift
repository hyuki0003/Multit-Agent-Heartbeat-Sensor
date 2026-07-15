import SwiftUI
import HermesMonitorCore

struct TaskListView: View {
    let snapshot: HermesMonitorSnapshot

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
                        HStack(spacing: 7) {
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
                            Text("\(group.completedCount)/\(group.totalCount)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .background(Color.purple.opacity(0.14), in: Capsule())
                        }
                        .padding(.horizontal, 4)

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
                    }
                }
            }
        }
    }

    private func card(for item: CorrelatedTask) -> some View {
        TaskCardView(
            item: item,
            runs: snapshot.kanban.runs.filter { $0.taskID == item.id },
            events: snapshot.kanban.events.filter { $0.taskID == item.id },
            comments: snapshot.kanban.comments.filter { $0.taskID == item.id },
            logLines: snapshot.logTails[item.id] ?? []
        )
    }
}
