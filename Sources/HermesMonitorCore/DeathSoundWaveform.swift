import Foundation

public enum DeathSoundWaveform: Sendable {
    public static let sampleRate: Double = 44_100
    public static let duration: TimeInterval = 1.5
    public static let frequency: Double = 880
    public static let amplitude: Double = 0.3

    public static var sampleCount: Int {
        Int(sampleRate * duration)
    }

    public static func samples() -> [Float] {
        (0..<sampleCount).map { index in
            let phase = 2.0 * Double.pi * frequency * Double(index) / sampleRate
            return Float(sin(phase) * amplitude)
        }
    }
}
