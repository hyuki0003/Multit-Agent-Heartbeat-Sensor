import SwiftUI
import HermesMonitorCore

struct TaskDetailView: View {
    let item: CorrelatedTask
    let runs: [TaskRun]
    let events: [TaskEvent]
    let comments: [TaskComment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let body = item.task.body, !body.isEmpty {
                detailSection(title: "BRIEF") {
                    Text(body)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
            }

            if !runs.isEmpty {
                detailSection(title: "RUN HISTORY") {
                    ForEach(Array(runs.suffix(5).reversed())) { run in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(runColor(run))
                                .frame(width: 6, height: 6)
                            Text("#\(run.id) · \(run.profile) · \(run.status.rawValue)")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(run.startedAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !events.isEmpty {
                detailSection(title: "RECENT EVENTS") {
                    ForEach(Array(events.suffix(5).reversed())) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(event.kind.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(.cyan)
                            Spacer(minLength: 4)
                            Text(event.createdAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !comments.isEmpty {
                detailSection(title: "COMMENTS") {
                    ForEach(Array(comments.suffix(3).reversed())) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(comment.author)")
                                .font(.caption2.bold())
                                .foregroundStyle(.purple)
                            Text(comment.body)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .font(.caption)
        .padding(.top, 2)
    }

    private func detailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            content()
        }
    }

    private func runColor(_ run: TaskRun) -> Color {
        switch run.status {
        case .running: return .blue
        case .done: return .green
        case .blocked: return .orange
        case .crashed, .timedOut, .failed: return .red
        case .released: return .secondary
        }
    }
}
