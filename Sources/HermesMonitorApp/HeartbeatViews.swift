import Foundation
import SwiftUI
import HermesMonitorCore

struct HeartbeatIndicator: View {
    let item: CorrelatedTask
    let liveness: TaskLivenessState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !shouldAnimate)) { timeline in
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(heartColor)
                .scaleEffect(scale(at: timeline.date))
                .shadow(color: heartColor.opacity(0.45), radius: liveness == .fresh ? 5 : 0)
        }
        .accessibilityLabel("Heartbeat \(liveness.displayName.lowercased())")
    }

    private var shouldAnimate: Bool {
        (item.visualStatus == .running && liveness == .fresh) ||
            item.visualStatus == .done ||
            item.visualStatus == .archived
    }

    private var symbolName: String {
        switch item.visualStatus {
        case .done, .archived:
            return "heart.text.square.fill"
        case .failed:
            return "heart.slash.fill"
        case .running where liveness == .dead:
            return "heart.slash.fill"
        default:
            return "heart.fill"
        }
    }

    private var heartColor: Color {
        if item.visualStatus == .running {
            return liveness == .fresh ? .green : .gray
        }
        if item.visualStatus == .done || item.visualStatus == .archived {
            return .green
        }
        return item.visualStatus.color
    }

    private func scale(at date: Date) -> CGFloat {
        if item.visualStatus == .done || item.visualStatus == .archived {
            let phase = date.timeIntervalSinceReferenceDate * .pi / 1.4
            return 1 + CGFloat((sin(phase) + 1) * 0.035)
        }

        guard item.visualStatus == .running, liveness == .fresh else { return 1 }
        let anchor = item.task.lastHeartbeatAt ?? date
        let elapsed = max(0, date.timeIntervalSince(anchor))
        let phase = elapsed.truncatingRemainder(dividingBy: 1)
        switch phase {
        case 0..<0.10:
            return 1 + CGFloat(sin(phase / 0.10 * .pi)) * 0.30
        case 0.16..<0.25:
            return 1 + CGFloat(sin((phase - 0.16) / 0.09 * .pi)) * 0.16
        default:
            return 1
        }
    }
}

struct ECGWaveformView: View {
    let status: TaskVisualStatus
    let liveness: TaskLivenessState
    let lastHeartbeatAt: Date?

    @State private var appearedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimated)) { timeline in
            Canvas { context, size in
                drawGrid(context: &context, size: size)
                let path = waveformPath(
                    size: size,
                    date: timeline.date
                )
                context.stroke(
                    path,
                    with: .color(traceColor),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(height: 60)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("ECG \(status.displayName.lowercased()), \(liveness.displayName.lowercased())")
    }

    private var isAnimated: Bool {
        status == .running && (liveness == .fresh || liveness == .stale)
    }

    private var traceColor: Color {
        if status == .done || status == .archived { return .blue }
        if status == .running {
            switch liveness {
            case .fresh: return .green
            case .stale: return .yellow
            case .dead, .inactive: return .gray
            }
        }
        return status == .failed ? .red : .gray
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for x in stride(from: CGFloat(12), through: size.width, by: 12) {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: CGFloat(8), through: size.height, by: 8) {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
    }

    private func waveformPath(size: CGSize, date: Date) -> Path {
        let centerY = size.height / 2
        let amplitude = amplitude(at: date)
        guard isAnimated, amplitude > 0 else {
            var flatline = Path()
            flatline.move(to: CGPoint(x: 0, y: centerY))
            flatline.addLine(to: CGPoint(x: size.width, y: centerY))
            return flatline
        }

        let period = 74.0
        let phase = date.timeIntervalSinceReferenceDate
        var path = Path()
        for x in stride(from: CGFloat.zero, through: size.width, by: 1.5) {
            let rawCycle = Double(x) / period + phase
            let cycle = rawCycle - floor(rawCycle)
            let sample = ecgSample(cycle)
            let y = centerY - sample * size.height * 0.38 * amplitude
            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private func amplitude(at date: Date) -> CGFloat {
        guard status == .running else { return 0 }
        switch liveness {
        case .fresh:
            return CGFloat(min(1, max(0, date.timeIntervalSince(appearedAt) / 1.2)))
        case .stale:
            guard let lastHeartbeatAt else { return 0 }
            let age = max(60, date.timeIntervalSince(lastHeartbeatAt))
            return CGFloat(min(1, max(0, (180 - age) / 120)))
        case .dead, .inactive:
            return 0
        }
    }

    private func ecgSample(_ phase: Double) -> CGFloat {
        switch phase {
        case 0.08..<0.16:
            return CGFloat(sin((phase - 0.08) / 0.08 * .pi)) * 0.15
        case 0.30..<0.36:
            return -CGFloat((phase - 0.30) / 0.06) * 0.22
        case 0.36..<0.40:
            return -0.22 + CGFloat((phase - 0.36) / 0.04) * 1.22
        case 0.40..<0.45:
            return 1 - CGFloat((phase - 0.40) / 0.05) * 1.48
        case 0.45..<0.51:
            return -0.48 + CGFloat((phase - 0.45) / 0.06) * 0.48
        case 0.62..<0.78:
            return CGFloat(sin((phase - 0.62) / 0.16 * .pi)) * 0.24
        default:
            return 0
        }
    }

}
