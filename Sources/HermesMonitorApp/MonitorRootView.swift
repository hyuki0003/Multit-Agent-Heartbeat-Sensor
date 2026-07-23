import Foundation
import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct MonitorRootView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MonitorPreferenceKeys.taskListMode)
    private var taskListModeRaw = TaskListMode.expanded.rawValue

    private var taskListMode: TaskListMode {
        TaskListMode(rawValue: taskListModeRaw) ?? .expanded
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)

            if let errorMessage = viewModel.errorMessage {
                messageBanner(
                    text: errorMessage,
                    color: .red,
                    systemImage: "exclamationmark.octagon.fill"
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            if let diagnostic = viewModel.familyArchiveDiagnostic {
                messageBanner(
                    text: diagnostic,
                    color: .orange,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            } else if let failure = viewModel.archiveFailure {
                archiveFailureBanner(failure)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            } else if let notice = viewModel.archiveNotice {
                archiveNoticeBanner(notice)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if let snapshot = viewModel.snapshot {
                if !snapshot.warnings.isEmpty {
                    messageBanner(
                        text: snapshot.warnings.prefix(2).joined(separator: "\n"),
                        color: .yellow,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                let activeTasks = ActiveBoardProjection.activeBoardTasks(from: snapshot.tasks)
                if activeTasks.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            TaskListView(
                                snapshot: snapshot,
                                selectedTaskID: viewModel.selectedTaskID,
                                taskListMode: taskListMode,
                                canArchive: viewModel.canArchiveTasks,
                                archiveActionsEnabled: !viewModel.isRefreshing,
                                archiveInFlightTaskIDs: viewModel.archiveInFlightTaskIDs,
                                onManualLink: viewModel.link(taskID:to:),
                                onShowComments: { task in
                                    NotificationCenter.default.post(
                                        name: .showHermesTaskComments,
                                        object: task.id
                                    )
                                },
                                onArchive: { task in
                                    Task { await viewModel.archiveDoneTask(task) }
                                }
                            )
                            .padding(12)
                        }
                        .onAppear {
                            scrollToSelectedTask(viewModel.selectedTaskID, using: proxy)
                        }
                        .onChange(of: viewModel.selectedTaskID) { taskID in
                            scrollToSelectedTask(taskID, using: proxy)
                        }
                    }
                }
            } else {
                loadingState
            }
        }
        .frame(minWidth: 360, idealWidth: 430, minHeight: 460, idealHeight: 720)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.14))
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("HERMES MONITOR")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                if let snapshot = viewModel.snapshot {
                    Text(summary(snapshot))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("remote snapshot monitor")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                taskListModeRaw = taskListMode == .compact
                    ? TaskListMode.expanded.rawValue
                    : TaskListMode.compact.rawValue
            } label: {
                Image(
                    systemName: taskListMode == .compact
                        ? "rectangle.expand.vertical"
                        : "rectangle.compress.vertical"
                )
                .font(.system(size: 12, weight: .semibold))
                .frame(
                    minWidth: CGFloat(CompactTaskLayout.disclosureHitTarget),
                    minHeight: CGFloat(CompactTaskLayout.disclosureHitTarget)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(taskListMode == .compact ? "Use expanded task list" : "Use compact task list")
            .accessibilityLabel(
                taskListMode == .compact ? "Use expanded task list" : "Use compact task list"
            )

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .disabled(viewModel.isRefreshing)

            Button {
                NotificationCenter.default.post(name: .showHermesMonitorSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            if viewModel.errorMessage != nil {
                Image(systemName: "gear.badge.questionmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("Configuration needed")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(viewModel.errorMessage ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text("Open Settings to set your SSH host, username, and Keychain credential.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button {
                    NotificationCenter.default.post(name: .showHermesMonitorSettings, object: nil)
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Connecting to Hermes...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            Text("No tasks in the current snapshot")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToSelectedTask(_ taskID: String?, using proxy: ScrollViewProxy) {
        guard let taskID else { return }
        DispatchQueue.main.async {
            if reduceMotion {
                proxy.scrollTo(taskID, anchor: .center)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(taskID, anchor: .center)
                }
            }
        }
    }

    private func summary(_ snapshot: HermesMonitorSnapshot) -> String {
        let activeTasks = ActiveBoardProjection.activeBoardTasks(from: snapshot.tasks)
        let running = activeTasks.filter { $0.visualStatus == .running }.count
        return "\(running) running · \(activeTasks.count) tasks · updated " +
            snapshot.refreshedAt.formatted(.relative(presentation: .numeric))
    }

    private func archiveFailureBanner(_ failure: TaskArchiveFailure) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(failure.message)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if failure.canRetry {
                Button("Try Again") {
                    Task { await viewModel.retryArchive() }
                }
                .buttonStyle(.borderless)
            }
            Button("Dismiss") {
                viewModel.dismissArchiveFeedback()
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }

    private func archiveNoticeBanner(_ notice: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(notice)
                .font(.caption)
            Spacer(minLength: 4)
            Button("Dismiss") {
                viewModel.dismissArchiveFeedback()
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }

    private func messageBanner(text: String, color: Color, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(color.opacity(0.25), lineWidth: 0.7)
        }
    }
}