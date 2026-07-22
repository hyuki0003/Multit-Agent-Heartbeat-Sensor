import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct TaskDetailView: View {
    let item: CorrelatedTask
    let runs: [TaskRun]
    let events: [TaskEvent]
    let reportComments: [TaskComment]

    var body: some View {
        let details = KoreanTaskDetails.presentation(
            status: item.visualStatus,
            comments: reportComments
        )

        VStack(alignment: .leading, spacing: 10) {
            detailSection(title: "현재 상태") {
                Label(details.statusLabel, systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.visualStatus.color)
                Text(details.summary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if let userAction = details.userAction {
                detailSection(title: "사용자 전용 조치") {
                    Text(userAction)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            } else if !details.nextSteps.isEmpty {
                detailSection(title: "다음 진행 선택지") {
                    ForEach(details.nextSteps, id: \.self) { step in
                        Text(step)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            if let body = item.task.body, !body.isEmpty {
                detailSection(title: "원문 요청 (BRIEF)") {
                    Text(body)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
            }

            if !runs.isEmpty {
                detailSection(title: "실행 기록") {
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
                detailSection(title: "최근 이벤트") {
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
        case .done, .completed: return .green
        case .blocked: return .orange
        case .crashed, .timedOut, .failed: return .red
        case .released, .unknown: return .secondary
        }
    }
}
