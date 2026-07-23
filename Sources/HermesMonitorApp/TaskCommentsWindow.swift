import AppKit
import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

extension Notification.Name {
    static let showHermesTaskComments = Notification.Name("showHermesTaskComments")
}

enum TaskCommentsReportState: Equatable {
    case waiting
    case summary(String)
    case requiresUserAction(String)

    var summary: String {
        switch self {
        case .waiting:
            return "No Korean Clinical Report is available yet."
        case .summary(let summary):
            return summary
        case .requiresUserAction(let action):
            return action
        }
    }
}

struct TaskCommentsPrefillOption: Equatable, Identifiable {
    let id: String
    let message: String
}

struct TaskCommentsReport: Equatable {
    let statusLabel: String
    let summary: String
    let state: TaskCommentsReportState
    let prefillOptions: [TaskCommentsPrefillOption]
    let sourceCommentID: Int64?

    init(task: KanbanTask, comments: [TaskComment]) {
        let details = KoreanTaskDetails.presentation(
            status: Self.visualStatus(for: task.status),
            comments: comments
        )

        self.init(details: details)
    }

    init(details: KoreanTaskDetailPresentation) {
        statusLabel = details.statusLabel
        summary = details.summary
        sourceCommentID = details.sourceCommentID
        if let userAction = details.userAction {
            state = .requiresUserAction(userAction)
            prefillOptions = []
        } else if details.sourceCommentID != nil {
            state = .summary(details.summary)
            prefillOptions = details.nextSteps.compactMap { step in
                guard step.count >= 3,
                      ["A. ", "B. ", "C. "].contains(String(step.prefix(3))) else {
                    return nil
                }
                return TaskCommentsPrefillOption(
                    id: String(step.prefix(1)),
                    message: step
                )
            }
        } else {
            state = .waiting
            prefillOptions = []
        }
    }

    var userAction: String? {
        guard case let .requiresUserAction(action) = state else { return nil }
        return action
    }

    var agentOptions: [String] {
        prefillOptions.map(\.message)
    }

    func prefill(for optionID: String) -> String? {
        prefillOptions.first(where: { $0.id == optionID })?.message
    }

    private static func visualStatus(for status: KanbanTaskStatus) -> TaskVisualStatus {
        switch status {
        case .todo: return .todo
        case .ready: return .ready
        case .running: return .running
        case .blocked: return .blocked
        case .done: return .done
        case .archived: return .archived
        }
    }
}

@MainActor
enum TaskCommentsDeliveryState: Equatable {
    case idle
    case sending
    case accepted(String)
    case failed(String)
}

@MainActor
final class TaskCommentsComposerState: ObservableObject {
    @Published var draft = ""
    @Published private(set) var selectedOptionID: String?
    @Published private(set) var focusRequestID = 0
    @Published private(set) var deliveryState: TaskCommentsDeliveryState = .idle
    var onSubmit: (() -> Void)?

    func prefill(option: String) {
        draft = option
        let candidate = String(option.prefix(1))
        selectedOptionID = ["A", "B", "C"].contains(candidate) ? candidate : nil
        focusRequestID += 1
        deliveryState = .idle
    }

    func placeholder(for report: TaskCommentsReport) -> String {
        report.userAction ?? "A/B/C 선택 또는 Astra에게 전달할 지시를 입력하세요."
    }

    func makeRequest(
        for task: CorrelatedTask,
        instructionID: UUID = UUID()
    ) throws -> RemoteTaskInstructionRequest {
        try RemoteTaskInstructionRequest(
            task: task,
            message: draft,
            instructionID: instructionID,
            selectedOptionID: selectedOptionID
        )
    }

    func clearSelectedOption() {
        selectedOptionID = nil
    }

    func beginSending() {
        deliveryState = .sending
    }

    func accept(notice: String) {
        draft = ""
        selectedOptionID = nil
        deliveryState = .accepted(notice)
    }

    func fail(message: String) {
        deliveryState = .failed(message)
    }

    func markEdited() {
        guard !draft.isEmpty else { return }
        if case .accepted = deliveryState {
            deliveryState = .idle
        }
    }

    func submit() {
        onSubmit?()
    }
}

@MainActor
final class TaskCommentsWindowCoordinator {
    typealias ControllerFactory = (String) -> NSWindowController

    private let makeController: ControllerFactory
    private var controllersByTaskID: [String: NSWindowController] = [:]

    init(
        viewModel: MonitorViewModel,
        makeController: ControllerFactory? = nil
    ) {
        self.makeController = makeController ?? { taskID in
            TaskCommentsWindowController(taskID: taskID, viewModel: viewModel)
        }
    }

    func controller(forTaskID taskID: String) -> NSWindowController {
        if let existing = controllersByTaskID[taskID] {
            return existing
        }
        let controller = makeController(taskID)
        controllersByTaskID[taskID] = controller
        return controller
    }

    func windowController(taskID: String) -> NSWindowController {
        controller(forTaskID: taskID)
    }

    func show(taskID: String) {
        let controller = controller(forTaskID: taskID)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class TaskCommentsWindowController: NSWindowController {
    init(taskID: String, viewModel: MonitorViewModel) {
        let content = TaskCommentsView(taskID: taskID, viewModel: viewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: content)
        window.title = "Hermes Monitor — Comments · \(taskID)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 600)
        window.setFrameAutosaveName("HermesMonitor.Comments.\(taskID)")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum TaskCommentRole: Equatable {
    case user
    case astra
    case system

    var label: String {
        switch self {
        case .user: return "User"
        case .astra: return "Astra"
        case .system: return "System"
        }
    }

    var color: Color {
        switch self {
        case .user: return .blue
        case .astra: return .purple
        case .system: return .secondary
        }
    }
}

struct TaskCommentsTimelineEntry: Identifiable {
    let comment: TaskComment
    let role: TaskCommentRole
    let visibleBody: String

    var id: Int64 { comment.id }

    init(comment: TaskComment) {
        self.comment = comment
        if comment.author == "user" {
            role = .user
        } else if comment.author == "astra" || comment.body.contains("[ASTRA_REPLY_KO]") {
            role = .astra
        } else {
            role = .system
        }
        visibleBody = comment.body
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed != "[ASTRA_REPLY_KO]" &&
                    trimmed != "[DETAILS_KO]" &&
                    !trimmed.hasPrefix("<!-- hermes-monitor-instruction:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TaskCommentsView: View {
    let taskID: String
    @ObservedObject var viewModel: MonitorViewModel

    @StateObject private var composer = TaskCommentsComposerState()
    @State private var pendingRequest: RemoteTaskInstructionRequest?
    @State private var localError: String?
    @FocusState private var composerFocused: Bool

    private var task: CorrelatedTask? {
        viewModel.snapshot?.tasks.first(where: { $0.id == taskID })
    }

    private var comments: [TaskComment] {
        (viewModel.snapshot?.kanban.comments ?? [])
            .filter { $0.taskID == taskID }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let task {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        clinicalReport(for: task)
                        timeline
                    }
                    .padding(18)
                }
                Divider()
                composer(for: task)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder")
                        .font(.largeTitle)
                    Text("Task unavailable")
                        .font(.headline)
                    Text("Refresh the board to locate \(taskID).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 500, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Clinical Comments")
                    .font(.title3.bold())
                Text("운영 작업 보고서 · 개인·의료 정보는 표시하지 않음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private func clinicalReport(for task: CorrelatedTask) -> some View {
        let report = TaskCommentsReport(task: task.task, comments: comments)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.task.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(report.statusLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(task.visualStatus.color)
                Text(task.task.assignee ?? task.currentRun?.profile ?? "unassigned")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Text(taskID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(reportUpdatedAt(for: task), style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("요약")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(report.summary)
                .font(.callout)
                .textSelection(.enabled)
            if let sourceCommentID = report.sourceCommentID {
                Text("source comment #\(sourceCommentID)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            switch report.state {
            case .waiting:
                Text("A validated [DETAILS_KO] report has not arrived yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .requiresUserAction(let action):
                VStack(alignment: .leading, spacing: 6) {
                    Text("사용자 조치")
                        .font(.caption.bold())
                    Text("사용자만 수행 가능")
                        .font(.caption2)
                    Label(action, systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.orange.opacity(0.38), lineWidth: 0.8)
                }
            case .summary:
                if !report.prefillOptions.isEmpty {
                    Text("권고")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(report.prefillOptions) { option in
                        Button {
                            composer.prefill(option: option.message)
                            pendingRequest = nil
                            localError = nil
                        } label: {
                            HStack(alignment: .top) {
                                Text(option.message)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.down.to.line.compact")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.8)
        }
    }

    private func reportUpdatedAt(for task: CorrelatedTask) -> Date {
        [
            comments.last?.createdAt,
            task.task.lastHeartbeatAt,
            task.task.completedAt,
            task.task.startedAt,
            task.task.createdAt,
        ]
        .compactMap { $0 }
        .max() ?? task.task.createdAt
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Timeline", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if comments.isEmpty {
                Text("아직 댓글이 없습니다")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(comments.map(TaskCommentsTimelineEntry.init)) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.role.label)
                                .font(.caption.bold())
                                .foregroundStyle(entry.role.color)
                            Text("@\(entry.comment.author)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.comment.createdAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.visibleBody.isEmpty ? "(contract marker)" : entry.visibleBody)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(entry.role.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func composer(for task: CorrelatedTask) -> some View {
        let report = TaskCommentsReport(task: task.task, comments: comments)
        let normalized = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let byteCount = normalized.utf8.count
        let isSubmitting = viewModel.instructionInFlightTaskIDs.contains(taskID)
        let isSending = isSubmitting || composer.deliveryState == .sending
        let isSubmissionDisabled = isSending ||
            !viewModel.canSubmitTaskInstructions ||
            task.instructionBinding == .unavailable ||
            normalized.isEmpty ||
            byteCount > RemoteTaskInstructionRequest.maximumMessageBytes
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Instruction to Astra", systemImage: "paperplane.fill")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(byteCount)/\(RemoteTaskInstructionRequest.maximumMessageBytes) bytes")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(
                        byteCount > RemoteTaskInstructionRequest.maximumMessageBytes
                            ? .red
                            : .secondary
                    )
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $composer.draft)
                    .font(.callout)
                    .frame(minHeight: 72, maxHeight: 130)
                    .padding(5)
                    .focused($composerFocused)
                    .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                if composer.draft.isEmpty {
                    Text(composer.placeholder(for: report))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 13)
                        .allowsHitTesting(false)
                }
            }
                .onChange(of: composer.draft) { newValue in
                    let currentMessage = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if pendingRequest?.message != currentMessage {
                        pendingRequest = nil
                    }
                    if composer.selectedOptionID.flatMap({ TaskCommentsReport(
                        task: task.task,
                        comments: comments
                    ).prefill(for: $0) }) != currentMessage {
                        composer.clearSelectedOption()
                    }
                    localError = nil
                    composer.markEdited()
                }
                .onChange(of: composer.focusRequestID) { _ in
                    composerFocused = true
                }

            switch composer.deliveryState {
            case .idle:
                EmptyView()
            case .sending:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Astra로 전송 중")
                        .font(.caption.bold())
                }
                .foregroundStyle(.secondary)
            case .accepted(let notice):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Astra 접수 완료")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            case .failed(let error):
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Text("Durable comment + idempotent Astra envelope")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    submit(task: task)
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else if case .failed = composer.deliveryState {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                            Text("재시도")
                        }
                    } else {
                        Label("Send", systemImage: "paperplane")
                            .foregroundStyle(isSubmissionDisabled ? Color.black.opacity(0.62) : Color.white)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSubmissionDisabled)
            }
        }
        .padding(16)
    }

    private func submit(task: CorrelatedTask) {
        let normalized = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let request: RemoteTaskInstructionRequest
            let candidateRequest = try composer.makeRequest(for: task)
            if let pendingRequest,
               pendingRequest.message == normalized,
               pendingRequest.selectedOptionID == composer.selectedOptionID,
               pendingRequest.runID == candidateRequest.runID {
                request = pendingRequest
            } else {
                request = candidateRequest
            }
            self.pendingRequest = request
            localError = nil
            composer.beginSending()
            Task {
                let accepted = await viewModel.submitTaskInstruction(request)
                if accepted {
                    pendingRequest = nil
                    localError = nil
                    composer.accept(
                        notice: viewModel.instructionNoticeByTaskID[taskID]
                            ?? "Astra instruction accepted"
                    )
                } else {
                    let message = viewModel.instructionErrorByTaskID[taskID]
                        ?? "전송에 실패했습니다. 다시 시도하세요."
                    composer.fail(message: message)
                }
            }
        } catch {
            localError = error.localizedDescription
            composer.fail(message: error.localizedDescription)
        }
    }
}
