import XCTest
@testable import HermesMonitorCore

final class DeathSoundWaveformTests: XCTestCase {
    func testFlatlineBeepSpecificationMatchesAcceptanceCriteria() {
        XCTAssertEqual(DeathSoundWaveform.sampleRate, 44_100)
        XCTAssertEqual(DeathSoundWaveform.duration, 1.5)
        XCTAssertEqual(DeathSoundWaveform.frequency, 880)
        XCTAssertEqual(DeathSoundWaveform.amplitude, 0.3)
        XCTAssertEqual(
            DeathSoundWaveform.sampleCount,
            Int(DeathSoundWaveform.sampleRate * DeathSoundWaveform.duration)
        )
    }

    func testGeneratedSamplesStayWithinConfiguredAmplitude() {
        let samples = DeathSoundWaveform.samples()

        XCTAssertEqual(samples.count, DeathSoundWaveform.sampleCount)
        XCTAssertEqual(samples.first, 0)
        XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 0, Float(DeathSoundWaveform.amplitude))
    }
}
