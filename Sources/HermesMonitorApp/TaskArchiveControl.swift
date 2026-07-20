import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct TaskArchiveControl: View {
    let item: CorrelatedTask
    let isBusy: Bool
    let isEnabled: Bool
    var compact = false
    let onConfirm: () -> Void

    @State private var showsConfirmation = false

    var body: some View {
        if isBusy {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                if !compact {
                    Text("Removing…")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Removing \(item.task.title) from the board")
        } else {
            Button(role: .destructive) {
                showsConfirmation = true
            } label: {
                Group {
                    if compact {
                        Image(systemName: "ellipsis.circle")
                    } else {
                        Label("Remove from board…", systemImage: "archivebox")
                    }
                }
                .frame(
                    minWidth: CGFloat(CompactTaskLayout.disclosureHitTarget),
                    minHeight: CGFloat(CompactTaskLayout.disclosureHitTarget)
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(!isEnabled)
            .accessibilityLabel("Remove \(item.task.title) from the board")
            .help(
                isEnabled
                    ? "Remove this completed task from the remote board"
                    : "Archive is unavailable while a remote refresh or archive is in progress"
            )
            .alert("Remove “\(item.task.title)” from board?", isPresented: $showsConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Remove from board", role: .destructive, action: onConfirm)
            } message: {
                Text(
                    "This archives the Done task on the server and removes it from the active board. " +
                        "Its runs, events, comments, result, and evidence remain preserved; " +
                        "nothing is permanently deleted."
                )
            }
        }
    }
}
