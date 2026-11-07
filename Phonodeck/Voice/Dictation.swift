import AVFoundation
import Foundation
import MLX
import MLXAudioSTT
import Observation
import Speech

/// Listens to the player. Say "make it so" at the end to send.
///
/// Two engines, both fully offline:
/// - Apple's on-device dictation (built in, words appear as you speak).
/// - A downloaded speech model (Parakeet): the app records, and each time you pause it
///   transcribes what you just said.
@Observable
@MainActor
final class Dictation {
    private(set) var listening = false
    private(set) var transcribing = false
    private(set) var text = ""
    var error: String?
    /// Called with the finished text when the player says the send phrase (or taps send).
    var onSend: ((String) -> Void)?
    /// Names from the story (characters, places), so Apple's recognizer spells them right.
    var vocabulary: [String] = []

    /// The words that send what you said (Settings > Story can change them).
    static var sendPhrase: String {
        let s = UserDefaults.standard.string(forKey: "sendPhrase")?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? "make it so" : s.lowercased()
    }

    private let store: ModelStore
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    /// Text from earlier segments (Apple ends a segment after a minute or a long pause).
    private var committed = ""
    private var session = 0

    // Downloaded model
    private var sttModel: (any STTGenerationModel)?
    private var sttModelID: String?
    private var pauseTimer: Timer?

    init(store: ModelStore) { self.store = store }

    // MARK: Thread-safe audio hand-off (the microphone tap runs on a real-time thread)

    private final class AudioBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var converter: AVAudioConverter?
        private let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        private var samples: [Float] = []
        private var heardSpeech = false
        private var lastLoud = Date()

        func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
        func endRequest() { lock.lock(); request?.endAudio(); request = nil; lock.unlock() }

        func reset(recording: Bool, from format: AVAudioFormat?) {
            lock.lock()
            samples.removeAll()
            heardSpeech = false
            lastLoud = Date()
            converter = recording ? format.flatMap { AVAudioConverter(from: $0, to: target) } : nil
            lock.unlock()
        }

        func push(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            request?.append(buffer)
            guard let converter else { return }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let ch = out.floatChannelData else { return }
            let n = Int(out.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: ch[0], count: n))
            samples.append(contentsOf: chunk)
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(n, 1)))
            if rms > 0.015 { heardSpeech = true; lastLoud = Date() }
        }

        /// Returns the recorded speech once the speaker has paused, and starts a new segment.
        func takeIfPaused(after seconds: TimeInterval) -> [Float]? {
            lock.lock()
            defer { lock.unlock() }
            let paused = Date().timeIntervalSince(lastLoud) > seconds
            let tooLong = samples.count > 16_000 * 25
            guard heardSpeech, paused || tooLong else {
                if !heardSpeech, samples.count > 16_000 * 4 { samples.removeFirst(samples.count - 16_000) }
                return nil
            }
            let out = samples
            samples.removeAll()
            heardSpeech = false
            return out
        }

        func takeAll() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            let out = heardSpeech ? samples : []
            samples.removeAll()
            heardSpeech = false
            return out
        }
    }

    private let box = AudioBox()

    // MARK: Permissions

    static func requestPermission(speech: Bool) async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech else { return mic }
        let ok = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return ok && mic
    }

    private var usingModel: Bool { store.listeningModel != nil }

    // MARK: Start and stop

    func start() async {
        guard !listening else { return }
        let model = store.listeningModel
        guard await Self.requestPermission(speech: model == nil) else {
            error = "Phonodeck needs the microphone\(model == nil ? " and speech recognition" : ""). Turn them on in Settings > Phonodeck."
            return
        }
        if model == nil {
            guard let recognizer, recognizer.isAvailable else {
                error = "Apple's dictation isn't available right now. Download a listening model in the Models tab to listen offline."
                return
            }
            if !recognizer.supportsOnDeviceRecognition {
                error = "Apple's dictation needs the internet on this phone. Download a listening model in the Models tab to listen offline."
            }
        }
        committed = ""
        text = ""
        if model != nil { error = nil }

        Narrator.configureSession()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        box.reset(recording: model != nil, from: format)
        input.removeTap(onBus: 0)
        let box = self.box
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in box.push(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "The microphone couldn't start: \(error.localizedDescription)"
            return
        }
        listening = true

        if let model {
            Task { await self.prepareModel(model) }
            pauseTimer?.invalidate()
            pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPause() }
            }
        } else {
            beginAppleSegment()
        }
    }

    /// Stops listening. With `send`, whatever was heard is sent.
    func stop(send: Bool = false) {
        let wasModel = pauseTimer != nil
        session += 1
        listening = false
        pauseTimer?.invalidate()
        pauseTimer = nil
        task?.cancel()
        task = nil
        box.endRequest()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        guard send else { return }
        if wasModel {
            let tail = box.takeAll()
            Task {
                if !tail.isEmpty { await self.transcribe(tail, session: self.session, sendAfter: false) }
                self.sendNow()
            }
        } else {
            sendNow()
        }
    }

    private func sendNow() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { onSend?(message) }
    }

    func clear() {
        text = ""
        committed = ""
    }

    // MARK: Apple

    private func beginAppleSegment() {
        guard listening, let recognizer else { return }
        session += 1
        let mySession = session
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.contextualStrings = Array(vocabulary.prefix(80)) + [Self.sendPhrase]
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        box.endRequest()
        box.setRequest(req)
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            let heard = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.session == mySession, self.listening else { return }
                if let heard { self.update(Self.join(self.committed, heard)) }
                if final || err != nil {
                    if let heard, !heard.isEmpty { self.committed = Self.join(self.committed, heard) }
                    self.beginAppleSegment()
                }
            }
        }
    }

    // MARK: Downloaded model

    private func prepareModel(_ entry: ModelEntry) async {
        guard sttModelID != entry.id else { return }
        guard let dir = ModelStore.snapshotDirectory(entry.id) else {
            error = "\(entry.name) isn't downloaded. Pick it again in the Models tab."
            return
        }
        transcribing = true
        defer { transcribing = false }
        do {
            sttModel = try await STT.loadModel(modelRepo: dir.path, modelType: "parakeet", cache: ModelStore.hubCache)
            sttModelID = entry.id
        } catch {
            self.error = "Couldn't load \(entry.name): \(error.localizedDescription)"
        }
    }

    func unloadModel() {
        sttModel = nil
        sttModelID = nil
    }

    private func checkPause() {
        guard listening, !transcribing, let samples = box.takeIfPaused(after: 0.9) else { return }
        Task { await self.transcribe(samples, session: self.session, sendAfter: true) }
    }

    private func transcribe(_ samples: [Float], session mySession: Int, sendAfter: Bool) async {
        guard let entry = store.listeningModel else { return }
        await prepareModel(entry)
        guard let model = sttModel else { return }
        transcribing = true
        defer { transcribing = false }
        let audio = MLXArray(samples)
        let heard = model.generate(audio: audio).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return }
        committed = Self.join(committed, heard)
        if sendAfter {
            guard session == mySession else { return }
            update(committed)
        } else {
            text = committed
        }
    }

    // MARK: Text

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }

    private func update(_ full: String) {
        let phrase = Self.sendPhrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s,]+")
        if let r = full.range(of: "\\b" + phrase + "\\b[.!,]?\\s*$", options: [.regularExpression, .caseInsensitive]) {
            text = String(full[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            stop()
            sendNow()
            return
        }
        text = full
    }
}
