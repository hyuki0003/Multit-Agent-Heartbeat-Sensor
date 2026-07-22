import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct TaskCardView: View {
    let item: CorrelatedTask
    let runs: [TaskRun]
    let events: [TaskEvent]
    let comments: [TaskComment]
    let availableSessions: [HermesSession]
    let isSelected: Bool
    let onManualLink: (String, String) -> Void
    let canArchive: Bool
    let archiveActionsEnabled: Bool
    let isArchiving: Bool
    let showsWaveform: Bool
    let onShowComments: () -> Void
    let onArchive: () -> Void

    var body: some View {
        cardContent(liveness: item.task.liveness(at: .now))
    }

    private func cardContent(liveness: TaskLivenessState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 8) {
                        LiveHeartbeatIndicator(item: item)
                            .frame(width: 24, height: 24)

                        Text(item.task.title)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .lineLimit(2)
                            .truncationMode(.tail)

                        Spacer(minLength: 3)
                        StatusBadge(status: item.visualStatus)
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle")
                        Text(item.task.assignee ?? item.currentRun?.profile ?? "unassigned")
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .foregroundStyle(.cyan)
                        Text(item.session?.title ?? item.session?.id ?? "No mapped session")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if item.isUncertain {
                        HStack(spacing: 8) {
                            Label("Uncertain", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help("Session or run mapping is inferred, manual, or unmatched.")

                            if canLinkManually {
                                Menu {
                                    ForEach(availableSessions) { session in
                                        Button(session.title ?? session.id) {
                                            onManualLink(item.id, session.id)
                                        }
                                    }
                                } label: {
                                    Label(
                                        item.sessionConfidence == .manual ? "Change Link" : "Link Manually",
                                        systemImage: "link"
                                    )
                                }
                                .menuStyle(.borderlessButton)
                                .disabled(availableSessions.isEmpty)
                                .help(availableSessions.isEmpty ? "No sessions available" : "Select a session")
                            }
                        }
                        .font(.caption2)
                    }

                    HStack(spacing: 9) {
                        Label("\(runs.count) runs", systemImage: "arrow.triangle.2.circlepath")
                        Label("\(item.task.consecutiveFailures) failures", systemImage: "xmark.octagon")
                            .foregroundStyle(item.task.consecutiveFailures > 0 ? Color.red : Color.secondary)
                        Spacer(minLength: 2)
                        TaskLivenessSummaryView(item: item)
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsWaveform {
                    ECGWaveformView(
                        status: item.visualStatus,
                        liveness: liveness,
                        lastHeartbeatAt: item.task.lastHeartbeatAt
                    )
                    .frame(minWidth: 105, idealWidth: 130, maxWidth: 155)
                }
            }

            HStack(spacing: 12) {
                DisclosureButton(
                    title: "Comments",
                    systemImage: "text.bubble",
                    isExpanded: false,
                    isEnabled: true,
                    action: onShowComments
                )
                .help("Open task comments and Clinical Report")
                Spacer()
                if canArchive && item.task.status == .done {
                    TaskArchiveControl(
                        item: item,
                        isBusy: isArchiving,
                        isEnabled: archiveActionsEnabled,
                        onConfirm: onArchive
                    )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(cardTint(liveness).opacity(cardTintOpacity(liveness)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : cardTint(liveness).opacity(0.38),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.task.title), \(item.visualStatus.displayName)")
    }

    private var canLinkManually: Bool {
        item.sessionConfidence == .inferred ||
            item.sessionConfidence == .unmatched ||
            item.sessionConfidence == .manual
    }

    private func cardTint(_ liveness: TaskLivenessState) -> Color {
        if item.visualStatus == .running {
            switch liveness {
            case .stale: return .yellow
            case .dead: return .red
            case .fresh: return .green
            case .inactive: break
            }
        }
        switch item.visualStatus {
        case .blocked: return .yellow
        case .done: return .blue
        case .failed: return .red
        case .todo, .ready, .running, .archived: return item.visualStatus.color
        }
    }

    private func cardTintOpacity(_ liveness: TaskLivenessState) -> Double {
        if item.visualStatus == .running && (liveness == .stale || liveness == .dead) {
            return 0.09
        }
        return 0.06
    }
}

private struct StatusBadge: View {
    let status: TaskVisualStatus

    var body: some View {
        Text(status.displayName)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.13), in: Capsule())
            .overlay {
                Capsule().strokeBorder(status.color.opacity(0.42), lineWidth: 0.7)
            }
    }
}

private struct DisclosureButton: View {
    let title: String
    let systemImage: String
    let isExpanded: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(.caption2)
            .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.45))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
