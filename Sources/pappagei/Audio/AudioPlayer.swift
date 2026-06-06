import AVFoundation

/// Plays streamed int16 mono PCM (24 kHz) through AVAudioEngine with low latency.
/// Handles byte chunks that may split a sample across HTTP boundaries.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()   // changes rate, keeps pitch natural
    private let format: AVAudioFormat
    private var residual = Data()
    private let queue = DispatchQueue(label: "pappagei.audio")

    init(sampleRate: Double = 24000) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    /// Playback speed multiplier with pitch preserved. 1.0 = normal. Takes effect live.
    func setRate(_ rate: Double) {
        timePitch.rate = Float(max(0.5, min(2.0, rate)))
    }

    /// Start a fresh playback session (call before enqueuing a new utterance).
    func begin() {
        queue.sync {
            residual.removeAll(keepingCapacity: true)
            do {
                if !engine.isRunning { try engine.start() }
                player.play()
            } catch {
                NSLog("pappagei: audio engine start failed: \(error)")
            }
        }
    }

    func enqueue(_ data: Data) {
        queue.sync {
            var bytes = residual
            bytes.append(data)
            let frameCount = bytes.count / 2
            let usable = frameCount * 2
            guard frameCount > 0 else { residual = bytes; return }
            residual = bytes.subdata(in: usable..<bytes.count)
            let frame = bytes.subdata(in: 0..<usable)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let out = buffer.floatChannelData![0]
            frame.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<frameCount {
                    out[i] = max(-1, min(1, Float(samples[i]) / 32768.0))
                }
            }
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
    }

    func pause() { queue.sync { player.pause() } }

    func resume() { queue.sync { player.play() } }

    func stop() {
        queue.sync {
            player.stop()
            player.reset()
            residual.removeAll(keepingCapacity: true)
        }
    }
}
