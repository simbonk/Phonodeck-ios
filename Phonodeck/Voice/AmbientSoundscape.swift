import AVFoundation
import Foundation
import Observation

/// Procedural ambient soundscape bed synthesized once off the main thread into seamless 24 kHz
/// looping WAV clips (zero bundled audio files, zero GPU usage). Automatically adapts to the
/// story's current room and weather (indoor rain on glass, outdoor downpour, warm hearth/room tone,
/// or calm evening breeze), ducks gently under spoken voices, and mutes cleanly while the mic listens.
@Observable
@MainActor
final class AmbientSoundscape {
    static let shared = AmbientSoundscape()

    enum Mood: String, CaseIterable {
        case none
        case rainIndoors
        case rainOutdoors
        case hearthWarm
        case nightBreeze

        var label: String {
            switch self {
            case .none: return "Off"
            case .rainIndoors: return "Rain on glass"
            case .rainOutdoors: return "Rain outside"
            case .hearthWarm: return "Warm room"
            case .nightBreeze: return "Evening air"
            }
        }

        var symbol: String {
            switch self {
            case .none: return "speaker.slash"
            case .rainIndoors, .rainOutdoors: return "cloud.rain"
            case .hearthWarm: return "flame"
            case .nightBreeze: return "wind"
            }
        }
    }

    /// Settings toggle (on by default).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "ambientSoundscape") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ambientSoundscape") }
    }

    private(set) var currentMood: Mood = .none
    private(set) var isPlaying = false

    private var players: [Mood: AVAudioPlayer] = [:]
    private var clips: [Mood: Task<Data, Never>] = [:]
    private var ducked = false
    private var micMuted = false
    private var generation = 0

    nonisolated private static let rate = 24_000.0
    private static let idleVolume: Float = 0.24
    private static let duckedVolume: Float = 0.08

    /// Infers the best ambient mood from the current room's weather, indoor/outdoor type, and setup.
    static func mood(for a: Adventure) -> Mood {
        let room = a.room
        let outdoor = room.map { RoomBuilder.outdoor.contains($0.type) } ?? false
        let locLow = a.location.lowercased()
        let looksOutdoor = outdoor || locLow.range(of: #"\b(street|alley|alleyway|outside|garden|park|dock|pier|beach|shore|road|lane|courtyard|porch|yard|forest|woods|field)\b"#, options: .regularExpression) != nil
        let text = [room?.outside ?? "", room?.inside ?? "", a.ambience[locLow] ?? "", a.setup.place, a.setup.feeling, a.bible]
            .joined(separator: " ")
            .lowercased()
        let hasRain = text.range(of: #"\b(rain|raining|storm|stormy|downpour|drizzle|thunder|raindrop|raindrops|monsoon|pouring|rain-lashed|rain-slicked)\b"#, options: .regularExpression) != nil
        if hasRain {
            return looksOutdoor ? .rainOutdoors : .rainIndoors
        }
        return looksOutdoor ? .nightBreeze : .hearthWarm
    }

    /// Transitions smoothly to the given mood (or stops if `.none` / disabled).
    func setMood(_ mood: Mood) {
        guard Self.enabled, mood != .none else {
            stop()
            return
        }
        if currentMood == mood, isPlaying {
            applyVolume(fade: 0.6)
            return
        }
        let previous = currentMood
        currentMood = mood
        generation += 1
        let mine = generation

        // Fade out previous mood if one was playing.
        if previous != .none, previous != mood, let old = players[previous], old.isPlaying {
            old.setVolume(0, fadeDuration: 1.4)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if self.currentMood != previous { old.pause() }
            }
        }

        let clipTask: Task<Data, Never>
        if let existing = clips[mood] {
            clipTask = existing
        } else {
            let t = Task.detached(priority: .utility) { Self.wav(Self.render(mood)) }
            clips[mood] = t
            clipTask = t
        }

        Task { @MainActor in
            let data = await clipTask.value
            guard self.generation == mine, self.currentMood == mood, Self.enabled else { return }
            if self.players[mood] == nil {
                let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                p?.numberOfLoops = -1
                p?.prepareToPlay()
                self.players[mood] = p
            }
            guard let player = self.players[mood] else { return }
            Narrator.configureSession()
            if !player.isPlaying {
                player.volume = 0
                player.play()
            }
            self.isPlaying = true
            self.applyVolume(fade: 1.8)
        }
    }

    /// Gently lowers ambience while voices are speaking, then rises back when they finish.
    func setDucked(_ isDucked: Bool) {
        guard ducked != isDucked else { return }
        ducked = isDucked
        applyVolume(fade: isDucked ? 0.5 : 1.0)
    }

    /// Cleanly silences ambience while the microphone is listening so STT hears only the user.
    func setMicMuted(_ muted: Bool) {
        guard micMuted != muted else { return }
        micMuted = muted
        applyVolume(fade: muted ? 0.2 : 0.9)
    }

    /// Fades out and pauses all ambience (when leaving a story or toggling off).
    func stop() {
        generation += 1
        let mine = generation
        currentMood = .none
        isPlaying = false
        for (_, p) in players where p.isPlaying {
            p.setVolume(0, fadeDuration: 0.9)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            guard self.generation == mine else { return }
            for (_, p) in self.players { p.pause() }
        }
    }

    private func applyVolume(fade: TimeInterval) {
        guard currentMood != .none, let p = players[currentMood] else { return }
        let target: Float = (!Self.enabled || micMuted) ? 0 : (ducked ? Self.duckedVolume : Self.idleVolume)
        if target > 0 && !p.isPlaying {
            Narrator.configureSession()
            p.volume = 0
            p.play()
            isPlaying = true
        }
        p.setVolume(target, fadeDuration: fade)
    }

    // MARK: Procedural DSP synthesis (silky filtered rain, hearth warmth, evening breeze)

    nonisolated private static func render(_ mood: Mood) -> [Float] {
        let secs = 24.0, pre = 2.0
        let n = Int(rate * (secs + pre))
        var buf = [Float](repeating: 0, count: n)

        // Deterministic xorshift64 PRNG for zero-allocation audio noise.
        var rng: UInt64 = mood == .rainIndoors ? 0x9E3779B97F4A7C15
            : mood == .rainOutdoors ? 0xD1B54A32D192ED03
            : mood == .hearthWarm ? 0xA0761D6478BD642F
            : 0xE7037ED1A0B428DB
        func rand() -> Float {
            rng ^= rng >> 12
            rng ^= rng << 25
            rng ^= rng >> 27
            let v = rng &* 0x2545F4914F6CDD1D
            return Float(Double(v >> 11) * (1.0 / Double(1 << 53))) * 2.0 - 1.0
        }

        // Paul Kellet's pink noise filter state (silky natural spectrum, never harsh white hiss).
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        func pink() -> Float {
            let w = rand()
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            let out = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11
            b6 = w * 0.115926
            return out
        }

        var lp1: Float = 0, lp2: Float = 0, lp3: Float = 0
        var dropEnv: Float = 0, dropPhase: Double = 0, dropFreq: Double = 900
        var crackleEnv: Float = 0

        for i in 0..<n {
            let t = Double(i) / rate
            let p = pink()

            switch mood {
            case .rainIndoors:
                // Muffled roof/glass rain: double low-pass on pink noise + gentle slow storm swell
                // + soft occasional water-droplet taps on glass + subtle warm room resonance.
                let swell = Float(0.84 + 0.16 * sin(2 * .pi * 0.0833 * t) + 0.06 * sin(2 * .pi * 0.1667 * t + 1.1))
                lp1 += 0.14 * (p - lp1)
                lp2 += 0.08 * (lp1 - lp2)
                var s = lp2 * 1.15 * swell

                // Soft raindrop taps on glass (rare, mellow, low amplitude).
                if dropEnv < 0.001, rand() > 0.99915 {
                    dropEnv = Float(0.06 + 0.07 * Double(abs(rand())))
                    dropFreq = 520 + Double(abs(rand())) * 480
                    dropPhase = 0
                }
                if dropEnv > 0.0005 {
                    dropPhase += 2 * .pi * dropFreq / rate
                    s += Float(sin(dropPhase)) * dropEnv
                    dropEnv *= 0.9965
                }

                // Subtle warm room tone (like a distant cozy room / wood resonance).
                let warmth = Float(sin(2 * .pi * 110.0 * t) * 0.012 + sin(2 * .pi * 164.81 * t) * 0.008)
                buf[i] = (s + warmth) * 0.65

            case .rainOutdoors:
                // Closer outdoor rainfall with brighter high-mid detail and gusting breeze.
                let gust = Float(0.76 + 0.24 * sin(2 * .pi * 0.125 * t) + 0.10 * sin(2 * .pi * 0.0417 * t + 0.7))
                lp1 += 0.32 * (p - lp1)
                lp2 += 0.22 * (lp1 - lp2)
                lp3 += 0.05 * (p - lp3)
                buf[i] = (lp2 * 0.85 + lp3 * 0.55) * gust * 0.60

            case .hearthWarm:
                // Cozy quiet room bed: very soft brown-tinted air + occasional gentle hearth/vinyl micro-pops.
                let breath = Float(0.88 + 0.12 * sin(2 * .pi * 0.0833 * t))
                lp1 += 0.045 * (p - lp1)
                lp2 += 0.03 * (lp1 - lp2)
                var s = lp2 * 0.95 * breath

                if crackleEnv < 0.001, rand() > 0.99935 {
                    crackleEnv = Float(0.07 + 0.08 * Double(abs(rand())))
                }
                if crackleEnv > 0.0005 {
                    s += rand() * crackleEnv * 0.45
                    crackleEnv *= 0.96
                }
                let roomTone = Float(sin(2 * .pi * 130.81 * t) * 0.010 + sin(2 * .pi * 196.0 * t) * 0.006)
                buf[i] = (s + roomTone) * 0.58

            case .nightBreeze:
                // Slow, silky outdoor breeze / soft coastal air.
                let wave = Float(0.62 + 0.38 * (0.5 + 0.5 * sin(2 * .pi * 0.0833 * t)))
                lp1 += 0.09 * (p - lp1)
                lp2 += 0.055 * (lp1 - lp2)
                buf[i] = lp2 * 1.15 * wave * 0.62

            case .none:
                buf[i] = 0
            }
        }

        // Seamless loop: drop warm-up and cross-fade the final 1.5 seconds into the start.
        let st = Int(pre * rate)
        let fade = Int(1.5 * rate)
        var out = Array(buf[st...])
        for i in 0..<fade where i < out.count && st - fade + i >= 0 {
            let t = Float(i) / Float(fade)
            let j = out.count - fade + i
            out[j] = out[j] * (1 - t) + buf[st - fade + i] * t
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
