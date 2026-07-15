import Foundation
import SwiftUI
import HermesMonitorCore

struct HeartbeatIndicator: View {
    let item: CorrelatedTask
    let liveness: TaskLivenessState

    @State private var beatScale = 1.0

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(heartColor)
            .scaleEffect(beatScale)
            .shadow(color: heartColor.opacity(0.45), radius: liveness == .fresh ? 5 : 0)
            .animation(.easeInOut(duration: 0.2), value: liveness)
            .onChange(of: item.task.lastHeartbeatAt) { _ in
                triggerBeat()
            }
            .accessibilityLabel("Heartbeat \(liveness.displayName.lowercased())")
    }

    private var heartColor: Color {
        if item.visualStatus == .running {
            return liveness.color
        }
        return item.visualStatus.color
    }

    private func triggerBeat() {
        guard item.visualStatus == .running, liveness != .dead else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            beatScale = 1.35
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) {
                beatScale = 1
            }
        }
    }
}

struct ECGWaveformView: View {
    let status: TaskVisualStatus
    let liveness: TaskLivenessState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimated)) { timeline in
            Canvas { context, size in
                drawGrid(context: &context, size: size)
                let path = waveformPath(
                    size: size,
                    phase: timeline.date.timeIntervalSinceReferenceDate * phaseSpeed
                )
                context.stroke(
                    path,
                    with: .color(traceColor),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(height: 34)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("ECG \(status.displayName.lowercased()), \(liveness.displayName.lowercased())")
    }

    private var isAnimated: Bool {
        (status == .running && liveness != .dead) || status == .blocked
    }

    private var phaseSpeed: Double {
        switch (status, liveness) {
        case (.running, .fresh): return 1.25
        case (.running, .stale): return 0.42
        case (.blocked, _): return 0.20
        default: return 0
        }
    }

    private var traceColor: Color {
        status == .running ? liveness.color : status.color
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

    private func waveformPath(size: CGSize, phase: Double) -> Path {
        let centerY = size.height / 2
        guard isAnimated else {
            var flatline = Path()
            flatline.move(to: CGPoint(x: 0, y: centerY))
            flatline.addLine(to: CGPoint(x: size.width, y: centerY))
            return flatline
        }

        let period: Double = status == .blocked ? 220 : (liveness == .stale ? 88 : 62)
        var path = Path()
        for x in stride(from: CGFloat.zero, through: size.width, by: 1.5) {
            let rawCycle = Double(x) / period - phase
            let cycle = rawCycle - floor(rawCycle)
            let sample: CGFloat
            if status == .blocked {
                sample = blockedSample(cycle)
            } else {
                sample = ecgSample(cycle)
            }
            let staleVariation = liveness == .stale
                ? CGFloat(0.62 + 0.18 * sin(rawCycle * 1.7))
                : 1
            let y = centerY - sample * size.height * 0.38 * staleVariation
            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
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

    private func blockedSample(_ phase: Double) -> CGFloat {
        guard phase >= 0.47, phase < 0.54 else { return 0 }
        let local = (phase - 0.47) / 0.07
        return CGFloat(sin(local * .pi)) * 0.35
    }
}
