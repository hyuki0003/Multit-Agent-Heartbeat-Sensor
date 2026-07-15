import Foundation
import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct HeartbeatIndicator: View {
    let item: CorrelatedTask
    let liveness: TaskLivenessState
    @State private var beatScale: CGFloat = 1

    var body: some View {
        heart
            .scaleEffect(beatScale)
            .onChange(of: item.task.lastHeartbeatAt) { timestamp in
                guard timestamp != nil,
                      presentation.heartMotion == .beatOnHeartbeatUpdate else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    beatScale = 1.24
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeIn(duration: 0.16)) {
                        beatScale = 1
                    }
                }
            }
            .onChange(of: presentation.heartMotion) { motion in
                if motion == .none {
                    beatScale = 1
                }
            }
            .accessibilityLabel("Heartbeat")
            .accessibilityValue(Text("\(item.visualStatus.displayName), \(liveness.displayName)"))
    }
    private var heart: some View {
        Image(systemName: symbolName)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(heartColor)
            .shadow(color: heartColor.opacity(0.45), radius: liveness == .fresh ? 5 : 0)
    }

    private var presentation: TaskHeartbeatPresentation {
        TaskHeartbeatPresentation(status: item.visualStatus, liveness: liveness)
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
        switch presentation.heartTone {
        case .healthy: return .green
        case .stale, .blocked: return .yellow
        case .dead: return .red
        case .completed: return .green
        case .inactive: return .secondary
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
        presentation.waveformMotion != .flatline
    }

    private var presentation: TaskHeartbeatPresentation {
        TaskHeartbeatPresentation(status: status, liveness: liveness)
    }

    private var traceColor: Color {
        switch presentation.heartTone {
        case .healthy: return .green
        case .stale, .blocked: return .yellow
        case .dead: return .red
        case .completed: return .blue
        case .inactive: return .secondary
        }
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
            let sample: CGFloat
            switch presentation.waveformMotion {
            case .continuous:
                sample = ecgSample(cycle)
            case .occasionalBlip:
                sample = blockedBlipSample(
                    x: x / max(1, size.width),
                    time: date.timeIntervalSinceReferenceDate
                )
            case .flatline:
                sample = 0
            }
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
        switch presentation.waveformMotion {
        case .flatline:
            return 0
        case .occasionalBlip:
            return 0.65
        case .continuous:
            switch liveness {
            case .fresh:
                return CGFloat(min(1, max(0, date.timeIntervalSince(appearedAt) / 1.2)))
            case .stale:
                guard let lastHeartbeatAt else { return 0 }
                let age = max(TaskLivenessThresholds.staleAfter, date.timeIntervalSince(lastHeartbeatAt))
                let staleDuration = TaskLivenessThresholds.deadAfter - TaskLivenessThresholds.staleAfter
                return CGFloat(min(1, max(0, (TaskLivenessThresholds.deadAfter - age) / staleDuration)))
            case .dead, .inactive:
                return 0
            }
        }
    }

    private func blockedBlipSample(x: CGFloat, time: TimeInterval) -> CGFloat {
        let cycleDuration: TimeInterval = 4
        let center = CGFloat(time.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration)
        let distance = x - center
        guard abs(distance) <= 0.04 else { return 0 }

        let phase = (distance + 0.04) / 0.08
        if phase < 0.25 { return 0.12 * sin(phase / 0.25 * .pi) }
        if phase < 0.42 { return -0.18 * ((phase - 0.25) / 0.17) }
        if phase < 0.55 { return -0.18 + 1.18 * ((phase - 0.42) / 0.13) }
        if phase < 0.68 { return 1.0 - 1.28 * ((phase - 0.55) / 0.13) }
        return -0.28 + 0.28 * ((phase - 0.68) / 0.32)
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
