import AVFoundation
import Foundation

/// The app's sound cues, ported from the web app (voice.js): short chirps so you can hear
/// with your eyes closed what is happening, and a soft hum while the Phonodeck thinks.
///
/// Everything is synthesised once into small WAV clips (no sound files ship with the app) and played
/// with AVAudioPlayer, beside the narrator and the microphone in the shared audio session.
@MainActor
final class ComputerSounds {
    static let shared = ComputerSounds()

    enum Cue: String {
        /// Your turn to talk: the microphone just opened.
        case listen
        /// The send phrase heard: an acknowledging chirp (three rising notes).
        case ack
        /// A typed message was sent.
        case sent
    }

    /// Settings > Hands-free > Sound cues (on unless turned off).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "computerSounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "computerSounds") }
    }

    private var cuePlayers: [Cue: AVAudioPlayer] = [:]
    private var humPlayer: AVAudioPlayer?
    /// The hum takes a moment to synthesise (longer in a Debug build), so it is made in the background at launch.
    private var humClip: Task<Data, Never>?
    private var humOn = false
    private var humGeneration = 0

    nonisolated private static let rate = 24_000.0

    /// Synthesises the hum ahead of time, off the main thread.
    func warm() {
        guard humClip == nil else { return }
        humClip = Task.detached(priority: .utility) { Self.wav(Self.renderHum()) }
    }

    // MARK: Playing

    /// Plays a cue. `after` waits that long first; the send phrase uses it because the chirp comes the moment
    /// the microphone shuts, and iOS takes a beat to rebuild the audio route then, swallowing anything
    /// that starts during it (the chirp is only a third of a second long).
    func play(_ cue: Cue, after delay: Double = 0) {
        guard Self.enabled else { return }
        if cuePlayers[cue] == nil {
            cuePlayers[cue] = try? AVAudioPlayer(data: Self.wav(Self.renderCue(cue)), fileTypeHint: AVFileType.wav.rawValue)
            cuePlayers[cue]?.prepareToPlay()
        }
        guard let p = cuePlayers[cue] else { return }
        // The thinking hum waits for the chirp, so the chirp is heard on its own first.
        cueEndsAt = max(cueEndsAt, Date().addingTimeInterval(delay + p.duration))
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            // If the route is still settling, play() refuses; try again a moment later.
            for attempt in 0..<4 {
                guard Self.enabled else { return }
                Narrator.configureSession()
                p.currentTime = 0
                p.volume = 1
                if p.play() { return }
                try? await Task.sleep(for: .milliseconds(120 * (attempt + 1)))
            }
        }
    }

    /// When the last cue that was asked for finishes.
    private var cueEndsAt = Date.distantPast

    /// Starts the thinking hum (fades in over two seconds). Does nothing if it is already playing.
    func startHum() {
        guard Self.enabled, !humOn else { return }
        humOn = true
        humGeneration += 1
        let mine = humGeneration
        warm()
        let clip = humClip
        Task { @MainActor in
            let wait = self.cueEndsAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if self.humPlayer == nil, let data = await clip?.value {
                self.humPlayer = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                self.humPlayer?.numberOfLoops = -1
                self.humPlayer?.prepareToPlay()
            }
            guard self.humOn, self.humGeneration == mine, let p = self.humPlayer else { return }
            Narrator.configureSession()
            if !p.isPlaying {
                p.volume = 0
                p.play()
            }
            p.setVolume(1, fadeDuration: 2)
        }
    }

    /// Fades the hum out (the narrator has started, or the reply is in).
    func stopHum() {
        guard humOn else { return }
        humOn = false
        humGeneration += 1
        let mine = humGeneration
        humPlayer?.setVolume(0, fadeDuration: 1.2)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            guard self.humGeneration == mine, !self.humOn else { return }
            self.humPlayer?.pause()
        }
    }

    // MARK: Synthesis (the same recipes as the web app's Web Audio graphs)

    /// Each cue is a list of (frequency, start, length) tones, as in voice.js.
    nonisolated private static func renderCue(_ cue: Cue) -> [Float] {
        let tones: [(Double, Double, Double)]
        switch cue {
        case .listen: tones = [(660, 0, 0.35)]
        case .sent: tones = [(440, 0, 0.35)]
        case .ack: tones = [(1175, 0, 0.07), (1568, 0.085, 0.07), (2093, 0.17, 0.16)]
        }
        let peak: Float = cue == .ack ? 0.09 : 0.12
        var out = [Float](repeating: 0, count: Int(rate * 0.5))
        for (f, start, len) in tones {
            let s0 = Int(start * rate), n = Int((len + 0.05) * rate)
            for i in 0..<n where s0 + i < out.count {
                let t = Double(i) / rate
                // Exponential ramps: up to the peak in 15 ms, down to silence by the tone's end.
                let env: Float
                if t < 0.015 {
                    env = 0.0001 * powf(peak / 0.0001, Float(t / 0.015))
                } else if t < len {
                    env = peak * powf(0.0001 / peak, Float((t - 0.015) / (len - 0.015)))
                } else {
                    env = 0
                }
                let phase = (f * t).truncatingRemainder(dividingBy: 1)
                // The acknowledging chirp is a triangle wave (brighter); the others are sines.
                let wave = cue == .ack ? Float(4 * abs(phase - 0.5) - 1) : Float(sin(2 * .pi * phase))
                out[s0 + i] += wave * env
            }
        }
        return out
    }

    /// A soft, slow "thinking" pad: an open-fifth chord of detuned sine tones that breathes, with a
    /// faint echo. Like the web app's iPhone clip, it leaves out the low D that phone speakers buzz on.
    /// Rendered as a 30-second loop whose end is cross-faded into its start, so it repeats seamlessly.
    nonisolated private static func renderHum() -> [Float] {
        let notes: [(Double, Float)] = [(146.83, 0.3), (220, 0.45), (329.63, 0.32), (440, 0.14)]
        let secs = 30.0, pre = 3.0
        let n = Int(rate * (secs + pre))
        var d = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let breathe = Float(0.16 + 0.03 * sin(2 * .pi * 0.09 * t))          // slow breathing
            let swell = Float(0.75 + 0.25 * sin(2 * .pi * 0.05 * t))            // slow brightness swell on the upper notes
            var s: Float = 0
            for (k, (f, g)) in notes.enumerated() {
                let bright: Float = k >= 2 ? swell : 1
                for cents in [-4.0, 4.0] {
                    s += Float(sin(2 * .pi * f * pow(2, cents / 1200) * t)) * g / 2 * bright
                }
            }
            d[i] = s * breathe
        }
        // Echo: half a second, fed back at 0.38, softened.
        let delay = Int(rate * 0.5)
        var echo = [Float](repeating: 0, count: n)
        var lp: Float = 0
        for i in delay..<n {
            lp += 0.25 * ((d[i - delay] + echo[i - delay] * 0.38) - lp)
            echo[i] = lp
        }
        for i in 0..<n { d[i] = (d[i] + echo[i]) * 0.5 }
        // Seamless loop: drop the warm-up, then blend the last second into what came just before the start.
        let st = Int(pre * rate), fade = Int(rate)
        var out = Array(d[st...])
        for i in 0..<fade {
            let t = Float(i) / Float(fade), j = out.count - fade + i
            out[j] = out[j] * (1 - t) + d[st - fade + i] * t
        }
        return out
    }

    /// 16-bit mono PCM in a WAV container.
    nonisolated private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate) * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for s in samples { put(Int16(max(-1, min(1, s)) * 32767)) }
        return data
    }
}
