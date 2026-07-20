import SwiftUI
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

extension TaskVisualStatus {
    var displayName: String {
        switch self {
        case .todo: return "TODO"
        case .ready: return "READY"
        case .running: return "RUNNING"
        case .blocked: return "BLOCKED"
        case .done: return "DONE"
        case .archived: return "ARCHIVED"
        case .failed: return "FAILED"
        }
    }

    var color: Color {
        switch self {
        case .todo, .ready, .archived: return .secondary
        case .running: return .blue
        case .blocked: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}

extension TaskLivenessState {
    var displayName: String {
        switch self {
        case .inactive: return "INACTIVE"
        case .fresh: return "FRESH"
        case .stale: return "STALE"
        case .dead: return "DEAD"
        }
    }

    var color: Color {
        switch self {
        case .inactive: return .secondary
        case .fresh: return .green
        case .stale: return .yellow
        case .dead: return .red
        }
    }

    var compactDisplayName: String {
        self == .inactive ? "UNKNOWN" : displayName
    }

    var compactSymbolName: String {
        switch self {
        case .inactive: return "heart"
        case .fresh: return "heart.fill"
        case .stale: return "heart.circle.fill"
        case .dead: return "heart.slash.fill"
        }
    }
}

extension TaskGroupLivenessState {
    var displayName: String {
        switch self {
        case .unknown: return "UNKNOWN"
        case .fresh: return "FRESH"
        case .stale: return "STALE"
        case .dead: return "DEAD"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .fresh: return .green
        case .stale: return .yellow
        case .dead: return .red
        }
    }

    var compactSymbolName: String {
        switch self {
        case .unknown: return "heart"
        case .fresh: return "heart.fill"
        case .stale: return "heart.circle.fill"
        case .dead: return "heart.slash.fill"
        }
    }
}
