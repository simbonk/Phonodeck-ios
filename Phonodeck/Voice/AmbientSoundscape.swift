import AVFoundation
import Foundation
import Observation

/// Plays real bundled ambient field-recording loops (`.m4a` / `.mp3` / `.wav` in the app bundle)
/// matched to the story's current room and weather.
///
/// Design rules:
/// - Never plays synthetic/robotic tones: if a matching high-quality recording is not bundled,
///   stays completely silent.
/// - Plays ONLY while the story is actively thinking or being read aloud (`storyActive == true`),
///   and fades smoothly to complete silence the moment it is your turn to type or speak, so it
///   never interferes with typing, hands-free dictation, or quiet thought.
@Observable
@MainActor
final class AmbientSoundscape {
    static let shared = AmbientSoundscape()

    enum Mood: String, CaseIterable {
        case none
        case rainIndoors = "rain_indoors"
        case rainOutdoors = "rain_outdoors"
        case hearth = "hearth"
        case cafe = "cafe"
        case ocean = "ocean"
        case forest = "forest"
        case night = "night"
        case city = "city"

        var label: String {
            switch self {
            case .none: return "Silent"
            case .rainIndoors: return "Rain on glass"
            case .rainOutdoors: return "Rain outside"
            case .hearth: return "Fireplace"
            case .cafe: return "Warm room"
            case .ocean: return "Ocean waves"
            case .forest: return "Forest breeze"
            case .night: return "Night air"
            case .city: return "Distant city"
            }
        }

        var symbol: String {
            switch self {
            case .none: return "speaker.slash"
            case .rainIndoors, .rainOutdoors: return "cloud.rain"
            case .hearth: return "flame"
            case .cafe: return "cup.and.saucer"
            case .ocean: return "water.waves"
            case .forest: return "leaf"
            case .night: return "moon.stars"
            case .city: return "building.2"
            }
        }
    }

    /// Settings toggle (on by default when real audio loops are bundled).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "ambientSoundscape") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ambientSoundscape") }
    }

    /// True if at least one real `.m4a` / `.mp3` / `.wav` ambience recording is bundled in the app.
    static var hasBundledAudio: Bool {
        Mood.allCases.contains { $0 != .none && bundleURL(for: $0) != nil }
    }

    private(set) var currentMood: Mood = .none
    private(set) var isPlaying = false

    private var players: [Mood: AVAudioPlayer] = [:]
    private var storyActive = false
    private var ducked = false
    private var micMuted = false
    private var generation = 0

    private static let thinkingVolume: Float = 0.22
    private static let speakingVolume: Float = 0.09

    /// Looks for a real bundled recording matching `mood.rawValue` (e.g. `rain_indoors.m4a`).
    static func bundleURL(for mood: Mood) -> URL? {
        guard mood != .none else { return nil }
        for ext in ["m4a", "mp3", "wav", "caf"] {
            if let url = Bundle.main.url(forResource: mood.rawValue, withExtension: ext, subdirectory: "Ambience")
                ?? Bundle.main.url(forResource: mood.rawValue, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    /// Infers the best real-world ambient loop for the current room, or `.none` if nothing fits cleanly.
    static func mood(for a: Adventure) -> Mood {
        let room = a.room
        let outdoor = room.map { RoomBuilder.outdoor.contains($0.type) } ?? false
        let locLow = a.location.lowercased()
        let looksOutdoor = outdoor || locLow.range(of: #"\b(street|alley|alleyway|outside|garden|park|dock|pier|beach|shore|road|lane|courtyard|porch|yard|forest|woods|field|deck|coast)\b"#, options: .regularExpression) != nil
        let text = [room?.outside ?? "", room?.inside ?? "", a.ambience[locLow] ?? "", a.location, a.setup.place, a.bible]
            .joined(separator: " ")
            .lowercased()

        if text.range(of: #"\b(rain|raining|storm|stormy|downpour|drizzle|thunder|raindrop|pouring|rain-lashed|rain-slicked)\b"#, options: .regularExpression) != nil {
            return looksOutdoor ? .rainOutdoors : .rainIndoors
        }
        if text.range(of: #"\b(ocean|sea|waves|surf|coast|lighthouse|beach|shore|harbor|harbour|pier|dock|ship)\b"#, options: .regularExpression) != nil {
            return .ocean
        }
        if text.range(of: #"\b(fireplace|hearth|crackling fire|campfire|woodstove|wood stove|cabin|lodge)\b"#, options: .regularExpression) != nil {
            return .hearth
        }
        if !looksOutdoor, text.range(of: #"\b(bar|speakeasy|cafe|café|coffee|diner|tavern|pub|bistro|restaurant|inn)\b"#, options: .regularExpression) != nil {
            return .cafe
        }
        if looksOutdoor, text.range(of: #"\b(forest|woods|trees|trail|meadow|garden|park|pine)\b"#, options: .regularExpression) != nil {
            return .forest
        }
        if looksOutdoor, text.range(of: #"\b(city|street|alley|station|downtown|avenue|traffic|train)\b"#, options: .regularExpression) != nil {
            return .city
        }
        if looksOutdoor, text.range(of: #"\b(night|evening|dusk|porch|moon|stars|crickets)\b"#, options: .regularExpression) != nil {
            return .night
        }
        return .none
    }

    /// Sets the scene's ambient mood (only plays when a real bundled file exists AND `storyActive` is true).
    func setMood(_ mood: Mood) {
        guard Self.enabled, mood != .none, let url = Self.bundleURL(for: mood) else {
            stop()
            return
        }
        if currentMood == mood {
            applyVolume(fade: 0.6)
            return
        }
        let previous = currentMood
        currentMood = mood
        generation += 1

        if previous != .none, previous != mood, let old = players[previous], old.isPlaying {
            old.setVolume(0, fadeDuration: 1.0)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.1))
                if self.currentMood != previous { old.pause() }
            }
        }

        if players[mood] == nil {
            let p = try? AVAudioPlayer(contentsOf: url)
            p?.numberOfLoops = -1
            p?.prepareToPlay()
            players[mood] = p
        }
        applyVolume(fade: 1.0)
    }

    /// Ambience is ONLY heard while the story is actively thinking or being read aloud.
    /// The moment the turn finishes and it's the player's turn, fades smoothly to silence.
    func setStoryActive(_ active: Bool) {
        guard storyActive != active else { return }
        storyActive = active
        applyVolume(fade: active ? 0.8 : 0.7)
    }

    /// Gently ducks volume under spoken narration/dialogue.
    func setDucked(_ isDucked: Bool) {
        guard ducked != isDucked else { return }
        ducked = isDucked
        applyVolume(fade: isDucked ? 0.4 : 0.8)
    }

    /// Immediately silences ambience while the microphone is listening.
    func setMicMuted(_ muted: Bool) {
        guard micMuted != muted else { return }
        micMuted = muted
        applyVolume(fade: muted ? 0.15 : 0.6)
    }

    /// Fades out and pauses all ambience.
    func stop() {
        generation += 1
        let mine = generation
        currentMood = .none
        isPlaying = false
        for (_, p) in players where p.isPlaying {
            p.setVolume(0, fadeDuration: 0.6)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.7))
            guard self.generation == mine else { return }
            for (_, p) in self.players { p.pause() }
        }
    }

    private func applyVolume(fade: TimeInterval) {
        guard currentMood != .none, let p = players[currentMood] else {
            isPlaying = false
            return
        }
        let shouldPlay = Self.enabled && storyActive && !micMuted
        let target: Float = shouldPlay ? (ducked ? Self.speakingVolume : Self.thinkingVolume) : 0
        if target > 0 {
            if !p.isPlaying {
                Narrator.configureSession()
                p.volume = 0
                p.play()
            }
            isPlaying = true
            p.setVolume(target, fadeDuration: fade)
        } else {
            isPlaying = false
            if p.isPlaying {
                p.setVolume(0, fadeDuration: fade)
                let mine = generation
                let moodToPause = currentMood
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(fade + 0.1))
                    guard self.generation == mine, !self.isPlaying, self.currentMood == moodToPause else { return }
                    self.players[moodToPause]?.pause()
                }
            }
        }
    }
}
