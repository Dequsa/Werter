import AVFoundation

/// A soft 25 ms click, like a dial's detent, played when the cursor moves onto a wedge.
/// Synthesized once; the audio engine only runs while the wheel is on screen.
@MainActor
final class TickSound {
    static let shared = TickSound()
    static let enabledKey = "playSounds"

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let click: AVAudioPCMBuffer

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private init() {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * 0.025)
        click = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        click.frameLength = frames
        // Two high partials under a fast exponential decay: bright but short, never a beep.
        let samples = click.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let tone = 0.6 * sin(2 * .pi * 2_400 * t) + 0.4 * sin(2 * .pi * 5_200 * t)
            samples[i] = Float(exp(-t * 350) * tone * 0.3)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Spins up the audio engine so the first tick isn't late. Call when the wheel appears.
    func prepare() {
        guard isEnabled, !engine.isRunning else { return }
        try? engine.start()
    }

    func play() {
        guard isEnabled else { return }
        prepare() // also recovers if the output device changed and stopped the engine
        guard engine.isRunning else { return }
        // Interrupt a tick still ringing so quick sweeps across wedges stay crisp.
        player.scheduleBuffer(click, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// Releases the audio hardware. Call when the wheel goes away.
    func stop() {
        player.stop()
        engine.stop()
    }
}
