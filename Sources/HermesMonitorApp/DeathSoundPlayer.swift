import AVFoundation
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

@MainActor
protocol DeathSoundPlaying: AnyObject {
    func playDeathSound()
}

@MainActor
final class DeathSoundPlayer: DeathSoundPlaying {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init() {
        format = AVAudioFormat(
            standardFormatWithSampleRate: DeathSoundWaveform.sampleRate,
            channels: 1
        )!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func playDeathSound() {
        guard let buffer = makeBuffer() else { return }

        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            player.scheduleBuffer(buffer)
            if !player.isPlaying {
                player.play()
            }
        } catch {
            player.stop()
        }
    }

    private func makeBuffer() -> AVAudioPCMBuffer? {
        let samples = DeathSoundWaveform.samples()
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }

        buffer.frameLength = buffer.frameCapacity
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }
}
