import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import Observation

/// Reads the story aloud, sentence by sentence, while the model is still writing it.
///
/// Three tiers: Apple's built-in voices (instant, no download), Kokoro (a small neural voice
/// that sounds natural), and Qwen3-TTS (the most expressive, but slower and larger).
@Observable
@MainActor
final class Narrator: NSObject {
    private(set) var speaking = false
    private(set) var preparing = false
    var lastError: String?
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
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineFormat: AVAudioFormat?
    private var buffersOutstanding = 0
    private var generation = 0

    init(store: ModelStore) {
        self.store = store
        super.init()
        synth.delegate = self
        engine.attach(player)
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
    private(set) var playing = false

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
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
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
        buffer = ""
        streamDone = true
        speaking = false
        preparing = false
        auditionVoice = nil
        auditioningID = nil
        playing = false
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
        guard streamDone, appleOutstanding == 0, sentenceQueue.isEmpty, worker == nil, buffersOutstanding == 0 else { return }
        if speaking {
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

    private func loadNeural(_ entry: ModelEntry) async throws -> SpeechGenerationModel {
        if let m = ttsModel, ttsModelID == entry.id { return m }
        ttsModel = nil
        guard let dir = ModelStore.snapshotDirectory(entry.id) else {
            throw NSError(domain: "Phonodeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(entry.name) is not downloaded yet."])
        }
        preparing = true
        defer { preparing = false }
        let path = dir.path
        UserDefaults.standard.set(entry.id, forKey: "voiceInFlight")
        defer { UserDefaults.standard.removeObject(forKey: "voiceInFlight") }
        let m = try await MLXGate.shared.run(urgent: true) {
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
                if self.generation == myGeneration { self.worker = nil; self.checkFinished() }
            }
            do {
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
                    let samples = try await MLXGate.shared.run(urgent: true) {
                        // An MLX failure becomes a Swift error (and Apple's voice takes over) instead of a crash.
                        try await Self.onChosenDevice(onCPU) {
                            try await withError { error in
                                let audio = try await boxed.value.generate(
                                    text: sentence, voice: voiceArg, refAudio: nil, refText: nil, language: language)
                                audio.eval()
                                try error.check()
                                return audio.asArray(Float.self)
                            }
                        }
                    }
                    guard self.generation == myGeneration else { return }
                    self.schedule(samples, sampleRate: Double(model.sampleRate), generation: myGeneration)
                }
            } catch is CancellationError {
            } catch {
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
        if !engine.isRunning { try? engine.start() }
        buffersOutstanding += 1
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == myGeneration else { return }
                self.buffersOutstanding = max(0, self.buffersOutstanding - 1)
                self.checkFinished()
            }
        }
        if !player.isPlaying { player.play() }
        playing = true
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
        _ = try await MLXGate.shared.run {
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
