import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct TaskListView: View {
    let snapshot: HermesMonitorSnapshot
    let selectedTaskID: String?
    let taskListMode: TaskListMode
    let canArchive: Bool
    let archiveActionsEnabled: Bool
    let archiveInFlightTaskIDs: Set<String>
    let onManualLink: (String, String) -> Void
    let onShowComments: (CorrelatedTask) -> Void
    let onArchive: (CorrelatedTask) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MonitorPreferenceKeys.collapsedGroupIDs)
    private var collapsedGroupIDsRaw = ""
    @State private var detailedCompactTaskIDs: Set<String> = []

    var body: some View {
        let activeTasks = ActiveBoardProjection.activeBoardTasks(from: snapshot.tasks)
        let groups = TaskGroupBuilder.groups(
            tasks: activeTasks,
            links: snapshot.kanban.links
        )
        let collapsibleGroupIDs = Set(groups.filter { !$0.isStandalone }.map(\.id))

        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                if taskListMode == .compact {
                    if group.isStandalone {
                        compactTask(group.parent)
                    } else {
                        compactGroup(group)
                    }
                } else if group.isStandalone {
                    card(for: group.parent)
                        .id(group.parent.id)
                } else {
                    expandedGroup(group)
                }
            }
        }
        .onChange(of: selectedTaskID) { taskID in
            expandSelectedTask(taskID, in: groups)
        }
        .onAppear {
            reconcileCollapsedGroups(validGroupIDs: collapsibleGroupIDs)
            expandSelectedTask(selectedTaskID, in: groups)
        }
        .onChange(of: collapsibleGroupIDs) { validGroupIDs in
            reconcileCollapsedGroups(validGroupIDs: validGroupIDs)
        }
    }

    private func expandedGroup(_ group: TaskPresentationGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleGroup(group.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed(group.id) ? -90 : 0))
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

            if !isCollapsed(group.id) {
                card(for: group.parent)
                    .id(group.parent.id)

                VStack(spacing: 8) {
                    ForEach(group.children) { child in
                        card(for: child)
                            .id(child.id)
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

    private func compactGroup(_ group: TaskPresentationGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let liveness = group.liveness(at: timeline.date)
                Button {
                    toggleGroup(group.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Image(systemName: liveness.compactSymbolName)
                                .foregroundStyle(liveness.color)
                                .frame(
                                    minWidth: CGFloat(CompactTaskLayout.disclosureHitTarget),
                                    minHeight: CGFloat(CompactTaskLayout.disclosureHitTarget)
                                )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.parent.task.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .help(group.parent.task.title)
                                Text("\(assignedChildCount(group)) assigned")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .layoutPriority(1)
                            Spacer(minLength: 4)
                            Text("\(group.childProgressPercent)%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(progressColor(group.childProgressPercent))
                                .frame(minWidth: CGFloat(CompactTaskLayout.percentageReservation))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(isCollapsed(group.id) ? -90 : 0))
                        }
                        HStack(spacing: 6) {
                            Text("\(group.completedChildCount)/\(group.childCount) complete")
                                .lineLimit(1)
                            ProgressView(value: Double(group.childProgressPercent), total: 100)
                                .tint(progressColor(group.childProgressPercent))
                            groupLivenessLabel(group, liveness: liveness)
                                .lineLimit(1)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(liveness.color)
                        }
                        .font(.system(size: 9, design: .monospaced))
                    }
                    .padding(.leading, CGFloat(CompactTaskLayout.horizontalInset))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(isCollapsed(group.id) ? "Expand" : "Collapse") " +
                        "\(group.parent.task.title), group. " +
                        "\(group.completedChildCount) of \(group.childCount) subtasks complete, " +
                        "\(group.childProgressPercent) percent. " +
                        groupLivenessAccessibility(group, liveness: liveness, at: timeline.date)
                )
            }

            if !isCollapsed(group.id) {
                VStack(spacing: 5) {
                    ForEach(group.compactDrillDownTasks) { compactTask($0) }
                }
                .padding(.leading, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private func compactTask(_ item: CorrelatedTask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let liveness = item.task.liveness(at: timeline.date)
                HStack(spacing: 7) {
                    Button {
                        toggleCompactTask(item.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: liveness.compactSymbolName)
                                .foregroundStyle(liveness.color)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(item.task.title)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .help(item.task.title)
                                    Text(item.visualStatus.displayName)
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(item.visualStatus.color)
                                }
                                HStack(spacing: 5) {
                                    Text(item.task.assignee ?? item.currentRun?.profile ?? "unassigned")
                                    Text("· LIVE: \(liveness.compactDisplayName)")
                                        .foregroundStyle(liveness.color)
                                    if let heartbeat = item.task.lastHeartbeatAt {
                                        Text("· heartbeat ") + Text(heartbeat, style: .relative)
                                    } else {
                                        Text("· No heartbeat recorded")
                                    }
                                }
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                            .layoutPriority(1)
                            Spacer(minLength: 2)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .rotationEffect(
                                    .degrees(detailedCompactTaskIDs.contains(item.id) ? 90 : 0)
                                )
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: CGFloat(CompactTaskLayout.disclosureHitTarget),
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(item.task.title), \(item.visualStatus.displayName), " +
                            "\(item.task.assignee ?? item.currentRun?.profile ?? "unassigned"), " +
                            "liveness \(liveness.compactDisplayName), " + heartbeatAccessibility(item)
                    )

                    Button {
                        onShowComments(item)
                    } label: {
                        Image(systemName: "text.bubble")
                            .frame(
                                minWidth: CGFloat(CompactTaskLayout.disclosureHitTarget),
                                minHeight: CGFloat(CompactTaskLayout.disclosureHitTarget)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Comments")
                    .accessibilityLabel("Open Comments for \(item.task.title)")

                    if canArchive && item.task.status == .done {
                        TaskArchiveControl(
                            item: item,
                            isBusy: archiveInFlightTaskIDs.contains(item.id),
                            isEnabled: archiveActionsEnabled,
                            compact: true,
                            onConfirm: { onArchive(item) }
                        )
                    }
                }
                .frame(minHeight: CGFloat(CompactTaskLayout.disclosureHitTarget))
            }

            if detailedCompactTaskIDs.contains(item.id) {
                card(for: item, showsWaveform: false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .id(item.id)
    }

    private func card(for item: CorrelatedTask, showsWaveform: Bool = true) -> some View {
        TaskCardView(
            item: item,
            runs: snapshot.kanban.runs.filter { $0.taskID == item.id },
            events: snapshot.kanban.events.filter { $0.taskID == item.id },
            comments: snapshot.kanban.comments.filter { $0.taskID == item.id },
            availableSessions: snapshot.state.sessions.sorted { $0.startedAt > $1.startedAt },
            isSelected: selectedTaskID == item.id,
            onManualLink: onManualLink,
            canArchive: canArchive,
            archiveActionsEnabled: archiveActionsEnabled,
            isArchiving: archiveInFlightTaskIDs.contains(item.id),
            showsWaveform: showsWaveform,
            onShowComments: { onShowComments(item) },
            onArchive: { onArchive(item) }
        )
    }

    private func isCollapsed(_ groupID: String) -> Bool {
        CollapsedTaskGroupPreference.decode(collapsedGroupIDsRaw).contains(groupID)
    }

    private func toggleGroup(_ groupID: String) {
        let update = {
            var collapsed = CollapsedTaskGroupPreference.decode(collapsedGroupIDsRaw)
            if collapsed.contains(groupID) {
                collapsed.remove(groupID)
            } else {
                collapsed.insert(groupID)
            }
            collapsedGroupIDsRaw = CollapsedTaskGroupPreference.encode(collapsed)
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                update()
            }
        }
    }

    private func toggleCompactTask(_ taskID: String) {
        let update = {
            if detailedCompactTaskIDs.contains(taskID) {
                detailedCompactTaskIDs.remove(taskID)
            } else {
                detailedCompactTaskIDs.insert(taskID)
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                update()
            }
        }
    }

    private func expandGroup(_ groupID: String) {
        var collapsed = CollapsedTaskGroupPreference.decode(collapsedGroupIDsRaw)
        collapsed.remove(groupID)
        collapsedGroupIDsRaw = CollapsedTaskGroupPreference.encode(collapsed)
    }

    private func expandSelectedTask(
        _ taskID: String?,
        in groups: [TaskPresentationGroup]
    ) {
        guard let taskID,
              let group = groups.first(where: {
                  $0.parent.id == taskID || $0.children.contains(where: { $0.id == taskID })
              }) else {
            return
        }
        expandGroup(group.id)
    }

    private func reconcileCollapsedGroups(validGroupIDs: Set<String>) {
        let collapsed = CollapsedTaskGroupPreference.decode(collapsedGroupIDsRaw)
        let reconciled = collapsed.intersection(validGroupIDs)
        guard reconciled != collapsed else { return }
        collapsedGroupIDsRaw = CollapsedTaskGroupPreference.encode(reconciled)
    }

    private func assignedChildCount(_ group: TaskPresentationGroup) -> Int {
        group.children.filter { $0.task.assignee != nil || $0.currentRun?.profile != nil }.count
    }

    private func progressColor(_ percent: Int) -> Color {
        guard percent > 0 else { return .secondary }
        return Color.green.opacity(0.35 + 0.65 * Double(percent) / 100)
    }

    private func heartbeatAccessibility(_ item: CorrelatedTask) -> String {
        guard let heartbeat = item.task.lastHeartbeatAt else { return "No heartbeat recorded" }
        return "heartbeat \(heartbeat.formatted(.relative(presentation: .numeric)))"
    }

    private func groupLivenessLabel(
        _ group: TaskPresentationGroup,
        liveness: TaskGroupLivenessState
    ) -> Text {
        let prefix = Text("LIVE: \(liveness.displayName)")
        let running = ([group.parent] + group.children).filter { $0.task.status == .running }
        guard !running.isEmpty else { return prefix + Text(" · No active run") }
        guard !running.contains(where: { $0.task.lastHeartbeatAt == nil }) else {
            return prefix + Text(" · No heartbeat recorded")
        }
        guard let oldestHeartbeat = running.compactMap({ $0.task.lastHeartbeatAt }).min() else {
            return prefix + Text(" · No heartbeat recorded")
        }
        return prefix + Text(" · heartbeat ") + Text(oldestHeartbeat, style: .relative)
    }

    private func groupLivenessAccessibility(
        _ group: TaskPresentationGroup,
        liveness: TaskGroupLivenessState,
        at now: Date
    ) -> String {
        let running = ([group.parent] + group.children).filter { $0.task.status == .running }
        guard !running.isEmpty else { return "Liveness \(liveness.displayName), no active run." }
        guard !running.contains(where: { $0.task.lastHeartbeatAt == nil }),
              let oldestHeartbeat = running.compactMap({ $0.task.lastHeartbeatAt }).min() else {
            return "Liveness \(liveness.displayName), no heartbeat recorded."
        }
        let age = max(0, Int(now.timeIntervalSince(oldestHeartbeat)))
        return "Liveness \(liveness.displayName), heartbeat \(age) seconds ago."
    }
}
