import Foundation
import Observation

/// The Chat tab's conversation with the model: the open chat, the streamed reply, replies
/// read aloud (the same "Read replies aloud" setting as the Phonodeck), and hands-free talk
/// that works like the Phonodeck's (the reply is read, then the microphone opens; say the send
/// phrase to send).
@Observable
@MainActor
final class ChatEngine {
    /// The open chat. It is saved to the library once something has been said in it.
    private(set) var current = Conversation()
    private(set) var reply = ""
    private(set) var generating = false
    private(set) var handsFree = false
    /// The narrator is reading something from this chat (a reply as it is written, or a tapped one).
    private(set) var reading = false
    var error: String?

    private let llm: LLMService
    private let narrator: Narrator
    private let dictation: Dictation
    private let library: Library
    private var task: Task<Void, Never>?
    /// Counts replies, so a stopped reply finishing late can't touch the next one.
    private var turn = 0

    init(llm: LLMService, narrator: Narrator, dictation: Dictation, library: Library) {
        self.llm = llm
        self.narrator = narrator
        self.dictation = dictation
        self.library = library
    }

    // MARK: Chats

    func newChat() {
        stopAll()
        current = Conversation()
        error = nil
    }

    func open(_ c: Conversation) {
        stopAll()
        current = c
        error = nil
    }

    func delete(_ c: Conversation) {
        if c.id == current.id { newChat() }
        library.delete(c)
    }

    /// Forgets the open chat (the app is locking).
    func close() {
        stopAll()
        handsFree = false
        current = Conversation()
    }

    // MARK: Hands-free

    func setHandsFree(_ on: Bool) {
        handsFree = on
        if on {
            listenIfReady()
        } else {
            dictation.stop()
            narrator.stop()
        }
    }

    /// The narrator finished reading a reply.
    func narrationFinished() {
        reading = false
        listenIfReady()
    }

    // MARK: Reading aloud

    /// Reads a reply aloud, or stops if the voice is already going (tap to read, tap to stop).
    func toggleReading(_ text: String) {
        if reading && (narrator.speaking || narrator.preparing) {
            stopReading()
        } else {
            dictation.stop()
            reading = true
            narrator.speak(text)
            if !narrator.speaking { reading = false }
        }
    }

    func stopReading() {
        guard reading else { return }
        reading = false
        narrator.stop()
        ComputerSounds.shared.stopHum()
        listenIfReady()
    }

    private func listenIfReady() {
        guard handsFree, !generating, !dictation.listening, !narrator.speaking, !narrator.preparing else { return }
        Task { await dictation.start() }
    }

    // MARK: Talking

    func send(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !generating else { return }
        dictation.stop()
        dictation.clear()
        error = nil
        current.turns.append(ChatTurn(role: .user, text: input))
        library.save(current)
        let history = Array(current.turns.suffix(16))
        let speak = handsFree || Reading.readAloud
        let chatID = current.id
        reply = ""
        generating = true
        turn += 1
        let myTurn = turn
        if speak { narrator.begin(); reading = true }
        ComputerSounds.shared.startHum()
        task = Task {
            do {
                let custom = (UserDefaults.standard.string(forKey: Reading.chatInstructionsKey) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let system = custom.isEmpty
                    ? "You are a helpful, friendly assistant running privately on the user's iPhone. Be concise."
                        + (speak ? " Your replies are read aloud, so write plain sentences without lists, headings or formatting." : "")
                    : custom
                for try await piece in llm.stream(system: system, history: history, options: .init(maxTokens: 900, temperature: 0.7)) {
                    guard turn == myTurn else { return }
                    if reply.isEmpty && !speak { ComputerSounds.shared.stopHum() }
                    reply += piece
                    if speak { narrator.feed(piece) }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            guard turn == myTurn else { return }
            let done = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !done.isEmpty, current.id == chatID {
                current.turns.append(ChatTurn(role: .assistant, text: done))
                library.save(current)
            }
            reply = ""
            generating = false
            task = nil
            if speak && !Task.isCancelled { narrator.finish() }
            if speak && !narrator.speaking { reading = false }
            if !speak || !narrator.speaking { ComputerSounds.shared.stopHum() }
            // Nothing to read aloud (an error or an empty reply): listen again straight away.
            listenIfReady()
        }
    }

    /// Stops the reply being written and anything being read aloud.
    func stopAll() {
        // Keep what was written before Stop, as a reply.
        let partial = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if generating, !partial.isEmpty {
            current.turns.append(ChatTurn(role: .assistant, text: partial))
            library.save(current)
        }
        turn += 1
        task?.cancel()
        task = nil
        generating = false
        reply = ""
        reading = false
        narrator.stop()
        dictation.stop()
        ComputerSounds.shared.stopHum()
    }
}
