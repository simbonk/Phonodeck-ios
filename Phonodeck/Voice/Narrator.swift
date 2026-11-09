import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import Observation
import os

/// Reads the story aloud, sentence by sentence, while the model is still writing it.
///
/// Three tiers: Apple's built-in voices (instant, no download), Kokoro (a small neural voice
/// that sounds natural), and Qwen3-TTS (the most expressive, but slower and larger).
@Observable
@MainActor
final class Narrator: NSObject {
    private(set) var speaking = false
    private(set) var preparing = false
    var lastError: String? {
        didSet { if let lastError, lastError != oldValue { NSLog("Phonodeck narrator problem: %@", lastError) } }
    }
    /// What a neural voice is doing right now, shown under the Listen buttons (and in Xcode's console).
    private(set) var detail: String? {
        didSet {
            // The "s so far" ticks would flood the console, so only new steps are logged.
            if let detail, detail.components(separatedBy: " (").first != oldValue?.components(separatedBy: " (").first {
                NSLog("Phonodeck narrator: %@", detail)
            }
        }
    }
    /// Called when everything queued has been spoken (hands-free uses it to start listening).
    var onFinished: (() -> Void)?

    private let store: ModelStore
    private let synth = AVSpeechSynthesizer()
    private var buffer = ""
    private var streamDone = true
    private var appleOutstanding = 0

    // Neural voice
    private var ttsModel: SpeechGenerationModel?
    private var ttsModelID: String?
    private var sentenceQueue: [String] = []
    private var worker: Task<Void, Never>?
    /// True while a neural voice still has sentences to turn into speech (it needs the GPU for
    /// that; playing the finished audio does not). Background story work waits for this.
    var synthesizing: Bool { worker != nil || (activeVoiceModel != nil && !sentenceQueue.isEmpty) }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineFormat: AVAudioFormat?
    private var buffersOutstanding = 0
    private var pendingBuffers: Set<UUID> = []
    private var generation = 0
    /// When the last scheduled sentence should finish playing. Sentences queue up behind each other
    /// on the player (Kokoro often writes faster than it speaks), so a sentence's own length is not
    /// enough to know when it will be heard.
    private var playbackEndsAt = Date.distantPast

    /// Speech made but not yet handed to the speaker. A reply only starts playing once enough is
    /// ready that the voice can keep ahead of itself; otherwise the first sentences come out choppy,
    /// with gaps while the next one is still being made (the voice is slowest on its first sentences).
    private var held: [(samples: [Float], sampleRate: Double)] = []
    private var heldSeconds = 0.0
    private var startedPlayback = false
    /// How long the voice has taken per character so far this reply, to judge how much to hold back.
    private var synthSeconds = 0.0
    private var synthChars = 0
    /// When the voice got the chip for the current sentence (time spent waiting for its turn doesn't count).
    private var makingSince: Date?
    /// Times this reply's speech ran dry between sentences (shown in the detail line and the console).
    private(set) var gaps = 0

    init(store: ModelStore) {
        self.store = store
        super.init()
        synth.delegate = self
        engine.attach(player)
        // The audio route or session can change under the engine (another app, dictation, a headset);
        // the engine then stops silently and queued speech would never play.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineChanged() }
        }
    }

    private func engineChanged() {
        engineFormat = nil
        guard buffersOutstanding > 0 else { return }
        detail = (detail ?? "") + " The audio route changed; restarting the speaker."
        do {
            try engine.start()
            player.play()
        } catch {
            lastError = "The speaker stopped when the audio route changed (\(error.localizedDescription))."
        }
    }

    // MARK: Settings

    static var appleVoiceID: String? {
        get { UserDefaults.standard.string(forKey: "appleVoice") }
        set { UserDefaults.standard.set(newValue, forKey: "appleVoice") }
    }
    static var rate: Float {
        get { Float((UserDefaults.standard.object(forKey: "speechRate") as? NSNumber)?.doubleValue ?? 0.5) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "speechRate") }
    }
    static func neuralVoice(for entry: ModelEntry) -> String {
        UserDefaults.standard.string(forKey: "neuralVoice." + entry.id) ?? entry.defaultVoice ?? ""
    }
    static func setNeuralVoice(_ v: String, for entry: ModelEntry) {
        UserDefaults.standard.set(v, forKey: "neuralVoice." + entry.id)
    }

    /// English voices installed on this phone, best quality first. Premium and Enhanced voices
    /// are free downloads in iOS Settings > Accessibility > Spoken Content > Voices.
    static var appleVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
            }
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Basic"
        }
    }

    private var appleVoice: AVSpeechSynthesisVoice? {
        if let id = Self.appleVoiceID, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return Self.appleVoices.first { $0.language == "en-US" } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// A voice being auditioned (the Listen buttons), used instead of the chosen one until the next stop.
    private var auditionVoice: Audition?
    private enum Audition { case apple, neural(ModelEntry) }
    private var activeVoiceModel: ModelEntry? {
        switch auditionVoice {
        case .apple: nil
        case .neural(let e): e
        case nil: store.voiceModel
        }
    }
    private var usingNeural: Bool { activeVoiceModel != nil }

    /// What is auditioning right now, so the matching Listen button can show Stop.
    private(set) var auditioningID: String?
    /// Sound is actually coming out (not just being prepared).
    private(set) var playing = false {
        // The thinking hum gives way as soon as the voice is heard, as on the web app.
        didSet { if playing && !oldValue { ComputerSounds.shared.stopHum() } }
    }

    /// Plays a sample in one voice (nil for Apple's) without changing the chosen narrator.
    func audition(_ entry: ModelEntry?, text: String = "The rain eases. Somewhere below, a door opens, and a voice you almost recognise calls your name.") {
        begin()
        auditionVoice = entry.map { .neural($0) } ?? .apple
        auditioningID = entry?.id ?? "apple"
        feed(text)
        finish()
    }

    /// The neural voice held in memory, if any.
    var loadedVoiceID: String? { ttsModelID }

    // MARK: Audio session

    static func configureSession() {
        let s = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers]
        // Setting the category again while speech is playing can make iOS rebuild the audio route,
        // which is heard as a click or a cut. Only set it when something changed it.
        if s.category != .playAndRecord || s.mode != .default || s.categoryOptions != options {
            try? s.setCategory(.playAndRecord, mode: .default, options: options)
        }
        try? s.setActive(true)
    }

    // MARK: Speaking

    /// Speaks a complete text, replacing anything already playing.
    func speak(_ text: String) {
        stop()
        begin()
        feed(text)
        finish()
    }

    /// Starts a new streamed reply.
    func begin() {
        stop()
        lastError = nil
        streamDone = false
        buffer = ""
    }

    /// Adds newly written text; complete sentences are spoken right away.
    func feed(_ text: String) {
        buffer += text
        while let cut = Self.sentenceEnd(in: buffer) {
            let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !sentence.isEmpty { enqueue(sentence) }
        }
    }

    /// The reply is complete: speak what is left.
    func finish() {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !rest.isEmpty { enqueue(rest) }
        streamDone = true
        checkFinished()
    }

    func stop() {
        generation += 1
        synth.stopSpeaking(at: .immediate)
        appleOutstanding = 0
        sentenceQueue.removeAll()
        worker?.cancel()
        worker = nil
        player.stop()
        buffersOutstanding = 0
        pendingBuffers.removeAll()
        playbackEndsAt = .distantPast
        lastPlayerSample = nil
        held.removeAll()
        heldSeconds = 0
        startedPlayback = false
        synthSeconds = 0
        synthChars = 0
        gaps = 0
        buffer = ""
        streamDone = true
        speaking = false
        preparing = false
        auditionVoice = nil
        auditioningID = nil
        playing = false
        detail = nil
    }

    /// Where a sentence ends: after . ! ? or a line break, once a few more characters have arrived
    /// (so "Mr." or "3.5" mid-stream are not split too early).
    static func sentenceEnd(in s: String) -> String.Index? {
        var i = s.startIndex
        var length = 0
        while i < s.endIndex {
            let c = s[i]
            length += 1
            let next = s.index(after: i)
            if c == "\n", length > 1 { return next }
            if ".!?…".contains(c), length > 24 {
                var j = next
                while j < s.endIndex, "\"'”’)".contains(s[j]) { j = s.index(after: j) }
                if j < s.endIndex, s[j] == " " || s[j] == "\n" { return j }
            }
            i = next
        }
        return nil
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    private func enqueue(_ sentence: String) {
        let text = clean(sentence)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speaking = true
        if usingNeural {
            sentenceQueue.append(text)
            startWorker()
        } else {
            Self.configureSession()
            let u = AVSpeechUtterance(string: text)
            u.voice = appleVoice
            u.rate = Self.rate
            u.postUtteranceDelay = 0.05
            appleOutstanding += 1
            synth.speak(u)
            playing = true
        }
    }

    private func checkFinished() {
        guard streamDone, appleOutstanding == 0, sentenceQueue.isEmpty, worker == nil, held.isEmpty, buffersOutstanding == 0 else { return }
        if speaking {
            if usingNeural { detail = (detail ?? "") + " Finished." }
            speaking = false
            playing = false
            let wasAudition = auditionVoice != nil
            auditionVoice = nil
            auditioningID = nil
            if !wasAudition { onFinished?() }
        }
    }

    // MARK: Neural voices

    var neuralLoadedGB: Double { ttsModelID == nil ? 0 : store.neededGB(ttsModelID) }

    func unloadNeural() {
        stop()
        ttsModel = nil
        ttsModelID = nil
        MLX.Memory.clearCache()
    }

    /// Keeps MLX's pool of reusable GPU buffers small while only a voice is loaded.
    static func limitCache() {
        if MLX.Memory.cacheLimit == 0 || MLX.Memory.cacheLimit > 64 * 1024 * 1024 { MLX.Memory.cacheLimit = 64 * 1024 * 1024 }
    }

    private func loadNeural(_ entry: ModelEntry) async throws -> SpeechGenerationModel {
        if let m = ttsModel, ttsModelID == entry.id { return m }
        ttsModel = nil
        guard let dir = ModelStore.snapshotDirectory(entry.id) else {
            throw NSError(domain: "Phonodeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(entry.name) is not downloaded yet."])
        }
        preparing = true
        defer { preparing = false }
        Self.limitCache()
        let path = dir.path
        UserDefaults.standard.set(entry.id, forKey: "voiceInFlight")
        defer { UserDefaults.standard.removeObject(forKey: "voiceInFlight") }
        let m = try await MLXGate.shared.run(urgent: true, label: "loading the \(entry.name) voice") {
            try await withError { error in
                let model = try await TTS.loadModel(modelRepo: path, modelType: nil, cache: ModelStore.hubCache)
                try error.check()
                return Unchecked(value: model)
            }
        }.value
        ttsModel = m
        ttsModelID = entry.id
        return m
    }

    /// Set after a neural voice closed the app on the graphics chip: it then runs on the processor,
    /// which is slower but avoids the GPU path that failed.
    static var neuralOnCPU: Bool {
        get { UserDefaults.standard.bool(forKey: "neuralOnCPU") }
        set { UserDefaults.standard.set(newValue, forKey: "neuralOnCPU") }
    }

    nonisolated private static func onChosenDevice<R>(_ cpu: Bool, _ body: () async throws -> R) async throws -> R {
        if cpu { return try await Device.withDefaultDevice(.cpu, body) }
        return try await body()
    }

    private func startWorker() {
        guard worker == nil, let entry = activeVoiceModel else { return }
        let myGeneration = generation
        worker = Task { @MainActor in
            defer {
                // Everything queued has been made: play whatever was held back.
                if self.generation == myGeneration { self.releaseHeld(); self.worker = nil; self.checkFinished() }
            }
            do {
                self.detail = "Loading \(entry.name)…"
                let model = try await self.loadNeural(entry)
                let voice = Self.neuralVoice(for: entry)
                let isQwen = entry.id.contains("Qwen3-TTS")
                let voiceArg: String? = voice.isEmpty ? nil : isQwen ? voice + ", a warm, expressive storyteller." : voice
                // Kokoro picks American or British pronunciation from the voice name.
                let language: String? = isQwen ? "English" : nil
                let boxed = Unchecked(value: model)
                let onCPU = Self.neuralOnCPU
                while !self.sentenceQueue.isEmpty, !Task.isCancelled, self.generation == myGeneration {
                    let sentence = self.sentenceQueue.removeFirst()
                    // Synthesis runs in the background, one MLX job at a time, so it can never freeze the screen.
                    // Marked while a neural voice is working, so a crash here is noticed at the next launch.
                    UserDefaults.standard.set(entry.id, forKey: "voiceInFlight")
                    defer { UserDefaults.standard.removeObject(forKey: "voiceInFlight") }
                    let chip = onCPU ? "processor" : "graphics chip"
                    self.detail = "Waiting for its turn on the \(chip)…"
                    let started = Date()
                    // Ticks while synthesis runs, so a stuck or slow step shows how long it has been.
                    let ticker = Task { @MainActor in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(5))
                            let busy = await MLXGate.shared.status()
                            guard !Task.isCancelled, self.generation == myGeneration, let d = self.detail else { return }
                            let base = d.components(separatedBy: " (").first ?? d
                            let waitingOn = base.hasPrefix("Waiting") ? busy.map { "; held by \($0)" } ?? "" : ""
                            self.detail = base + " (\(Int(Date().timeIntervalSince(started))) s so far\(waitingOn))"
                        }
                    }
                    defer { ticker.cancel() }
                    // An MLX failure becomes a Swift error (and Apple's voice takes over) instead of a crash.
                    let samples = try await MLXGate.shared.run(urgent: true, label: "the \(entry.name) voice on the \(chip)") { () async throws -> [Float] in
                        await MainActor.run { self.detail = "Making speech on the \(chip)…"; self.makingSince = Date() }
                        return try await Self.onChosenDevice(onCPU) {
                            try await withError { error in
                                let audio = try await boxed.value.generate(
                                    text: sentence, voice: voiceArg, refAudio: nil, refText: nil, language: language)
                                audio.eval()
                                try error.check()
                                let samples = audio.asArray(Float.self)
                                // MLX keeps freed GPU buffers for reuse; without a limit they pile up
                                // across sentences until iOS closes the app for using too much memory.
                                MLX.Memory.clearCache()
                                return samples
                            }
                        }
                    }
                    ticker.cancel()
                    guard self.generation == myGeneration else { return }
                    let seconds = Double(samples.count) / Double(model.sampleRate)
                    let loudest = samples.reduce(Float(0)) { max($0, abs($1)) }
                    let gb = { (bytes: Int) in Double(bytes) / 1_073_741_824 }
                    self.detail = String(format: "Made %.1f s of speech in %.1f s on the \(chip). Memory %.1f GB, peak %.1f GB, %.1f GB free.",
                                         seconds, Date().timeIntervalSince(started), gb(MLX.Memory.activeMemory), gb(MLX.Memory.peakMemory),
                                         gb(os_proc_available_memory()))
                    if samples.isEmpty || loudest < 0.0001 {
                        self.lastError = "\(entry.name) made silence for that sentence (\(samples.count) samples)."
                    }
                    self.synthSeconds += Date().timeIntervalSince(self.makingSince ?? started)
                    self.synthChars += sentence.count
                    self.deliver(samples, sampleRate: Double(model.sampleRate), generation: myGeneration)
                }
            } catch is CancellationError {
                if self.generation == myGeneration { self.lastError = "The \(entry.name) voice was cancelled before it spoke." }
            } catch {
                self.releaseHeld()
                self.lastError = "The \(entry.name) voice failed (\(error.localizedDescription)); using Apple's voice instead."
                let leftover = self.sentenceQueue
                self.sentenceQueue.removeAll()
                for s in leftover {
                    let u = AVSpeechUtterance(string: s)
                    u.voice = self.appleVoice
                    u.rate = Self.rate
                    self.appleOutstanding += 1
                    self.synth.speak(u)
                }
            }
        }
    }

    /// Hands a sentence's speech to the speaker, or holds it back until the voice is far enough ahead.
    private func deliver(_ samples: [Float], sampleRate: Double, generation myGeneration: Int) {
        guard !samples.isEmpty else { return }
        if startedPlayback {
            schedule(samples, sampleRate: sampleRate, generation: myGeneration)
            return
        }
        held.append((samples, sampleRate))
        heldSeconds += Double(samples.count) / sampleRate
        // Start once the speech ready lasts longer than making the rest is expected to take (with
        // room to spare), so playback never catches up with the voice. Until the reply is fully
        // written the rest can't be measured, so wait for a comfortable cushion instead.
        let remainingChars = sentenceQueue.reduce(0) { $0 + $1.count } + buffer.count
        let perChar = synthChars > 0 ? synthSeconds / Double(synthChars) : 0
        let needed = streamDone ? Double(remainingChars) * perChar * 1.3 + 0.5 : max(8, Double(remainingChars) * perChar * 1.3)
        if heldSeconds >= needed {
            releaseHeld()
        } else {
            detail = String(format: "Getting the voice ahead before it starts: %.0f s of speech ready, about %.0f s needed.", heldSeconds, needed)
        }
    }

    private func releaseHeld() {
        guard !held.isEmpty else { return }
        startedPlayback = true
        let ready = held
        held.removeAll()
        heldSeconds = 0
        for h in ready { schedule(h.samples, sampleRate: h.sampleRate, generation: generation) }
    }

    private func schedule(_ samples: [Float], sampleRate: Double, generation myGeneration: Int) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            pcm.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        Self.configureSession()
        if engineFormat != format {
            engine.stop()
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engineFormat = format
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                lastError = "Couldn't start the speaker (\(error.localizedDescription))."
                return
            }
        }
        // The speaker had finished everything before this sentence was ready: a gap was heard.
        if buffersOutstanding == 0 && playing {
            gaps += 1
            detail = (detail ?? "") + " The voice fell behind (gap \(gaps))."
        }
        buffersOutstanding += 1
        let bufferID = UUID()
        pendingBuffers.insert(bufferID)
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == myGeneration, self.pendingBuffers.remove(bufferID) != nil else { return }
                self.buffersOutstanding = max(0, self.buffersOutstanding - 1)
                self.checkFinished()
            }
        }
        if !player.isPlaying { player.play() }
        playing = true
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
        detail = (detail ?? "") + " Playing through \(route.isEmpty ? "no output" : route)."
        // If the speaker never reports the sound as played, say so (with what the engine was doing)
        // instead of showing Stop forever. The deadline counts from when this sentence should start,
        // which is after everything already queued ahead of it, not from now.
        let seconds = Double(samples.count) / sampleRate
        let startsAt = max(Date(), playbackEndsAt)
        playbackEndsAt = startsAt.addingTimeInterval(seconds)
        let deadline = playbackEndsAt.addingTimeInterval(4)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            // Still pending but sound is still coming out: something ahead of it ran long. Keep waiting
            // (up to a minute) while the player's clock moves, rather than declaring it lost.
            for _ in 0..<60 {
                guard let me = self, me.generation == myGeneration, me.pendingBuffers.contains(bufferID), me.playerIsAdvancing() else { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, self.generation == myGeneration, self.pendingBuffers.remove(bufferID) != nil else { return }
            let session = AVAudioSession.sharedInstance()
            self.lastError = "The speaker didn't play the speech (engine running: \(self.engine.isRunning ? "yes" : "no"), "
                + "player playing: \(self.player.isPlaying ? "yes" : "no"), output: \(route.isEmpty ? "none" : route), "
                + "volume \(Int(session.outputVolume * 100))%, category \(session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")))."
            self.buffersOutstanding = max(0, self.buffersOutstanding - 1)
            self.checkFinished()
        }
    }

    private var lastPlayerSample: AVAudioFramePosition?

    private func playerSampleTime() -> AVAudioFramePosition? {
        guard engine.isRunning, player.isPlaying, let node = player.lastRenderTime,
              let t = player.playerTime(forNodeTime: node) else { return nil }
        return t.sampleTime
    }

    /// True when the player's clock has moved since the last check (sound is still being played).
    private func playerIsAdvancing() -> Bool {
        guard let now = playerSampleTime() else { return false }
        defer { lastPlayerSample = now }
        guard let before = lastPlayerSample else { return true }
        return now > before
    }
}

extension Narrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.appleOutstanding = max(0, self.appleOutstanding - 1)
            self.checkFinished()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.appleOutstanding = max(0, self.appleOutstanding - 1)
        }
    }
}

/// Loads a voice model once and speaks a word into nothing, so any extra files it fetches on
/// first use (Kokoro's pronunciation dictionary) are stored for offline use.
enum NeuralVoiceWarmup {
    static func warm(directory: URL) async throws {
        let path = directory.path
        _ = try await MLXGate.shared.run(label: "preparing a downloaded voice") {
            try await withError { error in
                let model = try await TTS.loadModel(modelRepo: path, modelType: nil, cache: ModelStore.hubCache)
                let audio = try await model.generate(text: "Hello.", voice: "af_heart", refAudio: nil, refText: nil, language: nil)
                audio.eval()
                try error.check()
                MLX.Memory.clearCache()
                return true
            }
        }
    }
}
