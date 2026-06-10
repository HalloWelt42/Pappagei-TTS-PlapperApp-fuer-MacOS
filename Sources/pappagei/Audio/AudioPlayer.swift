import AVFoundation

/// Plays streamed int16 mono PCM (24 kHz) through AVAudioEngine with low latency.
/// Handles byte chunks that may split a sample across HTTP boundaries.
///
/// Playback is tracked to true completion: `endStream()` queues a trailing marker
/// buffer, and `isDrained` flips only once that marker has finished playing. This
/// lets the controller keep the "speaking" state (and the pause/stop controls live)
/// until the audio actually ends -- not merely until the bytes have arrived.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()   // changes rate, keeps pitch natural
    private let format: AVAudioFormat
    private var residual = Data()
    private let queue = DispatchQueue(label: "pappagei.audio")

    private var drained = true       // all scheduled audio has finished playing
    private var generation = 0       // bumped each begin()/stop(); ignores stale completions

    /// Called on the main thread after the engine was rebuilt because the
    /// output device changed; scheduled audio is lost at that point.
    var onInterruption: (() -> Void)?

    init(sampleRate: Double = 24000) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        // The engine stops itself when the output device changes (AirPods,
        // monitor speakers, ...); rebuild so playback can continue.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: nil) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        // Always async onto the serial queue: this fires on an arbitrary
        // thread and queue.sync here could deadlock against isDrained.
        queue.async {
            self.player.stop()
            self.engine.stop()
            self.engine.disconnectNodeOutput(self.player)
            self.engine.disconnectNodeOutput(self.timePitch)
            self.engine.connect(self.player, to: self.timePitch, format: self.format)
            self.engine.connect(self.timePitch, to: self.engine.mainMixerNode, format: self.format)
            self.residual.removeAll(keepingCapacity: true)
            self.generation &+= 1     // invalidate markers of the lost buffers
            self.drained = true       // let a pending drain loop finish
            DispatchQueue.main.async { self.onInterruption?() }
        }
    }

    /// Playback speed multiplier with pitch preserved. 1.0 = normal. Takes effect live.
    func setRate(_ rate: Double) {
        timePitch.rate = Float(max(0.5, min(2.0, rate)))
    }

    /// Start a fresh playback session (clears any leftover audio from a prior utterance).
    func begin() {
        queue.sync {
            player.stop()
            player.reset()
            residual.removeAll(keepingCapacity: true)
            generation &+= 1
            drained = false
            do {
                if !engine.isRunning { try engine.start() }
                player.play()
            } catch {
                NSLog("pappagei: audio engine start failed: \(error)")
                drained = true
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
            player.scheduleBuffer(buffer, at: nil, options: [],
                                  completionCallbackType: .dataPlayedBack, completionHandler: nil)
        }
    }

    /// Schedule a zero-audio marker; `onPlayed` fires on the main queue once
    /// everything enqueued before it has actually played. Markers from an
    /// earlier generation (before a stop/begin) are silently dropped.
    func scheduleMarker(_ onPlayed: @escaping @Sendable () -> Void) {
        queue.sync {
            guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
                DispatchQueue.main.async(execute: onPlayed)
                return
            }
            marker.frameLength = 1
            marker.floatChannelData![0][0] = 0
            let gen = generation
            player.scheduleBuffer(marker, at: nil, options: [],
                                  completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard gen == self.generation else { return }
                    DispatchQueue.main.async(execute: onPlayed)
                }
            }
        }
    }

    /// Signal that all bytes have arrived. Queue a trailing marker; buffers play in
    /// order, so when the marker finishes, every real buffer ahead of it has played.
    func endStream() {
        queue.sync {
            guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
                drained = true; return
            }
            marker.frameLength = 1
            marker.floatChannelData![0][0] = 0
            let gen = generation
            player.scheduleBuffer(marker, at: nil, options: [],
                                  completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async { if gen == self.generation { self.drained = true } }
            }
        }
    }

    /// True once playback of the whole utterance has finished.
    var isDrained: Bool { queue.sync { drained } }

    func pause() { queue.sync { player.pause() } }

    func resume() { queue.sync { player.play() } }

    func stop() {
        queue.sync {
            player.stop()
            player.reset()
            residual.removeAll(keepingCapacity: true)
            generation &+= 1
            drained = true
        }
    }
}
