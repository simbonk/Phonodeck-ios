import Foundation
import NaturalLanguage
import Observation

/// The story engine: builds the world, runs each turn, keeps the clock, remembers what
/// happened, and writes the report card. Ported from the web app's engine.js and following the
/// same flow (see How the Phonodeck Works): recall before each reply, a short Game Master plan, the reply, a
/// memory pass after it, and housekeeping (the showrunner's notes, a bible rewrite) every ten
/// turns. Only one model call runs at a time and every prompt is held to the context size the
/// fit check planned for, so the extra steps never raise peak memory.
@Observable
@MainActor
final class StoryEngine {
    private(set) var adventure: Adventure? {
        // The room grid follows the story: whenever the world changes, the map catches up.
        didSet {
            guard !syncingGrid, var a = adventure else { return }
            syncingGrid = true
            if a.syncGrid() { adventure = a }
            syncingGrid = false
        }
    }
    @ObservationIgnored private var syncingGrid = false
    private(set) var streaming = ""
    private(set) var stage = ""
    /// Set when the player writes something that sounds like they may want to hurt themselves:
    /// the story shows a support card with the crisis line. The story itself carries on.
    var showSupport = false
    /// The question the rebuild after a reply is asking right now ("" when it is not running),
    /// so the World panel can show it live.
    private(set) var rebuildStep = ""
    /// A room drawn before the reply that is being written (the opening, or an arrival): the
    /// rebuild after that reply tops it up once with what the reply named.
    private var roomDrawnBeforeReply: UUID?
    private(set) var busy = false
    /// True while a new world is being designed (until the opening scene's first words).
    private(set) var building = false
    /// The build screen's progress, following the architect as it writes.
    private(set) var forge: Forge?
    /// True while a saved story is being picked back up (the storyteller loading into memory):
    /// the story screen shows the thinking animation instead of the reply box until it is ready.
    private(set) var resuming = false
    /// When the storyteller started on the current reply (for the "thinking" timer).
    private(set) var thinkingSince: Date?
    /// What the player just sent, shown in the transcript at once while the turn waits for the
    /// Game Master's review and recall (it joins the transcript proper when the reply starts).
    private(set) var pendingInput: String?
    var error: String?

    /// Names learned this turn, for the world check.
    private var namesThisTurn: [String] = []
    /// Set while a new story is built, once the model has read the opening hour off the player's
    /// own words: that hour is the one source of truth for the clock, so the opening reply's
    /// painting ("the desert night") does not move it.
    @ObservationIgnored private var clockFromPremise = false
    /// Every small question put to the model, in order, for the export: "[turn 2 · rebuild] Where are you now? → {...} (1.3s)".
    @ObservationIgnored private var questionLog: [String] = []
    @ObservationIgnored private var questionLogFor: UUID?
    private func noteQ(_ phase: String, _ label: String, _ raw: String, since t0: Date) {
        guard let a = adventure else { return }
        if questionLogFor != a.id { questionLog = []; questionLogFor = a.id }
        let ans = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let secs = Date().timeIntervalSince(t0)
        trace("ASK " + phase, label.replacingOccurrences(of: "\n", with: " ") + "\n│        ◀ ANSWER: " + clip(ans.isEmpty ? "(no answer)" : ans, 600) + String(format: "  (%.1fs)", secs), seconds: secs)
        questionLog.append("[turn \(a.playerTurns) · " + phase + "] " + label + " → " + clip(ans.isEmpty ? "(no answer)" : ans, 180) + String(format: " (%.1fs)", Date().timeIntervalSince(t0)))
        if questionLog.count > 900 { questionLog.removeFirst(questionLog.count - 900) }
    }

    /// The full trace: everything the engine does, in the order it happens, with the time since
    /// the story started. Always kept: it is the Live log tab.
    @ObservationIgnored private var traceLog: [String] = []
    @ObservationIgnored private var traceFor: UUID?
    @ObservationIgnored private var traceStart = Date()
    @ObservationIgnored private var traceSystem = ""
    static var tracing: Bool { true }
    /// The phase the trace is in (LOOK, PLAN, STORY, REBUILD, ROOM BUILD…), when it began, and how
    /// many model questions it has asked, so each phase closes with its count and time.
    @ObservationIgnored private var tracePhase = ""
    @ObservationIgnored private var tracePhaseStart = Date()
    @ObservationIgnored private var tracePhaseAsks = 0
    @ObservationIgnored private var tracePhaseModelTime = 0.0
    /// How much of each room's change log is already in the trace.
    @ObservationIgnored private var traceMapSeen: [UUID: Int] = [:]
    private func traceReset(_ a: Adventure) {
        traceLog = []; traceFor = a.id; traceStart = Date(); traceSystem = ""
        tracePhase = ""; tracePhaseAsks = 0; tracePhaseModelTime = 0
        traceMapSeen = Dictionary(uniqueKeysWithValues: a.rooms.map { ($0.id, $0.log.count) })
    }
    /// One line of the live log, with the line its entry began on (which sets its colour).
    struct LogLine { let text: String; let head: String }

    /// The trace as it stands, line by line, for the live log screen. A prompt or answer that
    /// spans lines keeps its first line as `head`, so every line of it gets the same colour.
    func liveLog() -> [LogLine] {
        guard let a = adventure, traceFor == a.id else { return [LogLine(text: "(nothing logged yet: the log starts with the next step)", head: "")] }
        var out: [LogLine] = []
        for entry in traceLog {
            let parts = entry.components(separatedBy: "\n")
            let head = parts.first ?? ""
            for p in parts { out.append(LogLine(text: p, head: head)) }
        }
        if !tracePhase.isEmpty {
            let l = String(format: "└── %@ still open: %d model question%@ so far", tracePhase, tracePhaseAsks, tracePhaseAsks == 1 ? "" : "s")
            out.append(LogLine(text: l, head: l))
        }
        if !stage.isEmpty { out.append(LogLine(text: "… " + stage, head: "⚙")) }
        if !streaming.isEmpty {
            let h = "############ STORY (writing) ############"
            out.append(LogLine(text: "", head: ""))
            for p in [h] + streaming.components(separatedBy: "\n") { out.append(LogLine(text: p, head: h)) }
        }
        return out
    }

    /// Empties the log; it starts again from now, and the story carries on.
    func clearLog() {
        guard let a = adventure else { return }
        traceReset(a)
        questionLog = []; questionLogFor = a.id
        traceLog.append("(log cleared; it starts again here)")
    }

    private func stamp() -> String {
        let t = Date().timeIntervalSince(traceStart)
        return String(format: "[%02d:%04.1f]", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
    private func closePhase() {
        guard !tracePhase.isEmpty else { return }
        let took = Date().timeIntervalSince(tracePhaseStart)
        traceLog.append(String(format: "└── end of %@: %d model question%@ (%.1fs of model time), %.1fs in all", tracePhase, tracePhaseAsks, tracePhaseAsks == 1 ? "" : "s", tracePhaseModelTime, took))
        traceLog.append("")
        tracePhase = ""
    }
    private func openPhase(_ p: String) {
        guard p != tracePhase else { return }
        closePhase()
        tracePhase = p; tracePhaseStart = Date(); tracePhaseAsks = 0; tracePhaseModelTime = 0
        traceLog.append("┌── " + p + " " + String(repeating: "─", count: max(4, 40 - p.count)))
    }
    /// One line of the trace. Kinds: "ASK <phase>" (a question to the model), "CODE" (worked out in
    /// code), "FILED" (saved to a card), "MAP" (placed or moved on the map), "SENT TO STORYTELLER",
    /// "TURN NOTE", "FLAGGED".
    private func trace(_ kind: String, _ text: String, seconds: Double? = nil) {
        guard Self.tracing, let a = adventure else { return }
        if traceFor != a.id { traceReset(a) }
        let phaseNames = ["turn": "LOOK", "plan": "PLAN", "rebuild": "REBUILD (after the reply, while you listen)", "room": "ROOM BUILD",
                          "cards": "CARDS", "place": "PLACE"]
        if kind.hasPrefix("ASK ") { openPhase(phaseNames[String(kind.dropFirst(4))] ?? String(kind.dropFirst(4)).uppercased()) }
        else if kind == "SENT TO STORYTELLER" || kind == "TURN NOTE" { openPhase("STORY") }
        // Map changes since the last line, wherever they came from.
        for r in a.rooms {
            let seen = traceMapSeen[r.id] ?? 0
            if r.log.count > seen {
                for l in r.log.dropFirst(seen) { traceLog.append(stamp() + " 📍 MAP (" + r.name + "): " + RoomMapView.logText(l)) }
                traceMapSeen[r.id] = r.log.count
            }
        }
        let marker: String
        switch kind {
        case _ where kind.hasPrefix("ASK "): marker = "🤖 MODEL ASKED"
        case "CODE": marker = "⚙️ CODE"
        case "FILED": marker = "💾 SAVED TO CARD"
        case "MAP": marker = "📍 MAP"
        case "SENT TO STORYTELLER": marker = "📝 PROMPT SENT TO THE STORYTELLER"
        case "TURN NOTE": marker = "ℹ️ NOTE"
        case "FLAGGED": marker = "🚩 FLAGGED"
        default: marker = kind
        }
        if kind.hasPrefix("ASK ") {
            tracePhaseAsks += 1
            tracePhaseModelTime += seconds ?? 0
        }
        traceLog.append("│ " + stamp() + " " + marker + ": " + text)
        if traceLog.count > 4000 { traceLog.removeFirst(traceLog.count - 4000) }
    }
    /// A loud block in the trace, for what the player said and what the story said.
    private func traceBlock(_ title: String, _ text: String) {
        guard Self.tracing, let a = adventure else { return }
        if traceFor != a.id { traceReset(a) }
        closePhase()
        let bar = String(repeating: "#", count: 12)
        traceLog += ["", bar + " " + title + " " + bar, text, bar + String(repeating: "#", count: title.count + 2) + bar, ""]
    }

    /// What the player put down or gave away this turn: the rebuild doesn't put it back in their hands.
    private var putDownThisTurn: [String] = []
    /// The look heard the player move within the room this turn ("I walk over to Dolores").
    private var walkedThisTurn = false
    /// The place someone is in after the story shows them leaving the room ("Everyone now?").
    static let goneOut = "gone out of the room"
    /// The model said the player stays, though the words looked like going somewhere new.
    @ObservationIgnored private var newPlaceRefused = false
    /// This turn's plan, by person: true when they stay where they are, false when the plan moved them.
    /// The rebuild leaves a planned person where the plan put them.
    private var plannedThisTurn: [String: Bool] = [:]
    /// The one person the player turned to this turn. The rebuild only looks between you and them.
    private var focusThisTurn = ""
    /// A turn that is only you talking to one person, staying put: the reply and the rebuild look
    /// at nothing but the two of you (and the date, the city and the weather).
    private var talkThisTurn = false
    /// The plan's plain reading of what the player did ("turned toward Dolores and smiled at her"),
    /// so a dictation slip ("I turned it, Dolores") isn't taken literally by the reply.
    private var didThisTurn = ""
    /// The look heard the player stay in this place this turn (no going anywhere new).
    private var stayingThisTurn = false
    /// How much the person faced gives back this turn, as the plan form judged it.
    private var answerSizeThisTurn = ""
    /// The turn each story's person last asked the player something back.
    private var askedBackAt: [UUID: Int] = [:]
    /// The player's message picks something up, puts it down, walks somewhere or needs a thing
    /// fetched: only then is what lies within reach told to the storyteller.
    private var physicalThisTurn = true
    /// A second person the player addressed with the first ("both of you"): in the moment too.
    private var alsoThisTurn = ""
    /// The plan already put the player where they went this turn (sat them down, walked them over).
    private var placedByPlan = false

    /// Read replies aloud as they are written.
    var narrate: Bool { didSet { UserDefaults.standard.set(narrate, forKey: "narrate") } }
    /// Hands-free: the microphone opens after every reply, and the send phrase sends.
    private(set) var handsFree = false

    private let llm: LLMService
    private let narrator: Narrator
    private let dictation: Dictation
    private let library: Library
    private var memoryJob: Task<Void, Never>?
    private var undoSnapshot: Adventure?
    /// A turn the app had to stop because it left the foreground mid-reply; it runs again on return.
    /// Where the player was when the turn began, so the review knows which place people were left in.
    private var placeBeforeTurn = ""
    /// Who the player last asked to come along, so "we leave together" brings the right person.
    private var invited = ""
    /// How the grounded engine read the player's last message, for the export.
    private var lastRead = ""
    /// What the catch-up on a place found this turn, for the turn guide.
    private var catchUpNotes: [String] = []
    /// The last turn was foveated, and the kinds of card item it marked yes (the rebuild after it
    /// asks only about those, the people and the place).
    private var foveaUsed = false
    private var foveaYes: Set<String> = []
    private var interruptedTurn: (input: String, hidden: Bool, forceFinal: Bool)?
    private var currentTask: Task<Void, Never>?

    static let secPerTurn = 90.0
    static let maxGap = 300.0

    init(llm: LLMService, narrator: Narrator, dictation: Dictation, library: Library) {
        self.llm = llm
        self.narrator = narrator
        self.dictation = dictation
        self.library = library
        narrate = UserDefaults.standard.object(forKey: "narrate") as? Bool ?? true
        narrator.onFinished = { [weak self] in self?.narrationFinished() }
        dictation.onSend = { [weak self] text in self?.send(text) }
    }

    var canUndo: Bool { undoSnapshot != nil && !busy }

    // MARK: Opening and closing

    func open(_ a: Adventure) {
        stopAll()
        forge = nil
        var a = a
        // Stories saved before the review was checked in code may hold its example text: drop it.
        if Self.echoesPrompt(a.storyTime) { a.storyTime = "" }
        if Self.echoesPrompt(a.scene) { a.scene = "" }
        if Self.echoesPrompt(a.nextMove) { a.nextMove = "" }
        a.facts.removeAll { Self.echoesPrompt($0) }
        a.fixes.removeAll { Self.echoesPrompt($0) }
        a.timeline.removeAll { Self.echoesPrompt($0) }
        a.whereabouts.removeAll { Self.echoesPrompt($0.at) || Self.echoesPrompt($0.name) }
        adventure = a
        undoSnapshot = nil
        refreshVocabulary()
        error = nil
        // Get the storyteller into memory now, so the first reply isn't a long silent wait.
        busy = true
        resuming = true
        currentTask = Task {
            do { try await llm.load() } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            guard !Task.isCancelled else { return }
            busy = false
            resuming = false
            listenIfReady()
        }
    }

    func close() {
        stopAll()
        handsFree = false
        if let a = adventure { library.save(a) }
        adventure = nil
    }

    func stopAll() {
        currentTask?.cancel()
        interruptedTurn = nil
        narrator.stop()
        dictation.stop()
        streaming = ""
        pendingInput = nil
        busy = false
        building = false
        resuming = false
        thinkingSince = nil
        saying = false
        didPart = ""
        forge?.abort()
        ComputerSounds.shared.stopHum()
    }

    /// Turns hands-free on or off. On, the story is read aloud and the microphone opens
    /// whenever the narrator is quiet.
    func setHandsFree(_ on: Bool) {
        handsFree = on
        saying = false
        didPart = ""
        if on {
            narrate = true
            listenIfReady()
        } else {
            dictation.stop()
        }
    }

    private func listenIfReady() {
        guard handsFree, let a = adventure, !a.ended, !busy, !dictation.listening, !narrator.speaking, !narrator.preparing else { return }
        let two = Self.doThenSay
        let cue: ComputerSounds.Cue = two && saying ? .say : .listen
        Task { await dictation.start(cue: cue, allowEmpty: two) }
    }

    /// Settings > Hands-free > Do, then say (on unless turned off): each spoken turn comes in two
    /// parts, each with its own chirp. First what you do, then what you say.
    static var doThenSay: Bool { UserDefaults.standard.object(forKey: "doThenSay") as? Bool ?? true }
    /// Hands-free, between the two parts: what you do has been heard; now what you say.
    private(set) var saying = false
    private var didPart = ""
    /// The two parts of the turn just sent, kept apart for the whole turn: what the player did
    /// (a silent action: the only part that can move them, turn them or pick things up) and what
    /// they said aloud (words to the person they face, never an action).
    private var pendingParts: (did: String, said: String)?
    private var partsThisTurn: (did: String, said: String)?

    /// What the microphone heard, hands-free. With Do, then say, the first part is held and the
    /// microphone opens again (a different chirp) for the words; then both go as one turn, the
    /// action plainly and the words in quotes, so it is clear which is which.
    func heard(_ text: String) {
        guard handsFree, Self.doThenSay else { send(text.trimmingCharacters(in: .whitespacesAndNewlines)); return }
        part(text)
    }

    /// What the player has said they do, held while they give their words.
    var heldDo: String { didPart }

    /// Back to the first step, with what was held handed back to be edited.
    func editDo() -> String {
        let held = didPart
        saying = false
        didPart = ""
        return held
    }

    /// One step of a two-step turn, typed or spoken: first what the player does, then what they
    /// say. An empty step (or "nothing") leaves that part out.
    func part(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, adventure?.ended == false else { return }
        // Saying just "nothing" or "skip" leaves that part out.
        let part = ["nothing", "skip", "pass", "none"].contains(t.lowercased().trimmingCharacters(in: .punctuationCharacters)) ? "" : t
        if !saying {
            didPart = part
            saying = true
            dictation.clear()
            // After the acknowledging chirp has played, so the two-note "say" chirp is heard on its own.
            if handsFree {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    self.listenIfReady()
                }
            }
            return
        }
        saying = false
        let act = didPart
        didPart = ""
        let words = part.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” "))
        var turn = act
        if !turn.isEmpty, let last = turn.last, !".!?".contains(last) { turn += "." }
        if !words.isEmpty { turn += (turn.isEmpty ? "I say: \"" : " Then I say: \"") + words + "\"" }
        if turn.isEmpty { dictation.clear(); if handsFree { listenIfReady() }; return }
        pendingParts = (act, words)
        send(turn)
    }

    func narrationFinished() {
        ComputerSounds.shared.stopHum()
        listenIfReady()
    }

    // MARK: Building a world

    /// Continue: the next part of a finished story, a new story linked to it with the same player,
    /// cast and world. `link` is how it connects (one of `Prompts.continueLinks`), `hook` what
    /// happens next (may be empty).
    func continueStory(from src: Adventure, link: String, hook: String, minutes: Int) {
        var e = src.setup
        e.id = UUID()
        e.title = ""
        e.minutes = minutes
        e.hook = hook.trimmingCharacters(in: .whitespacesAndNewlines)
        e.beats = ""
        var player = PlayerDetails.saved
        if player.name.isEmpty { player.name = src.playerName }
        // The final reply's memory pass and review may still be running. Continue reads the ending
        // itself (see `readEnding`), so they are stopped rather than waited for: on a slow phone
        // model they could hold the next part up for a minute.
        memoryJob?.cancel()
        let latest = (adventure?.id == src.id ? adventure : nil) ?? library.adventures.first { $0.id == src.id } ?? src
        create(e, player: player, source: latest, link: link)
    }

    /// Where a finished story stands at its last line, read from the final scene.
    struct Ending {
        var place = ""
        var time = ""
        var withYou = ""
        var people: [Whereabout] = []
        var facts: [String] = []
        var recap = ""
    }

    /// One short call that reads the end of a finished story: where the player is, the time, who is
    /// where, what is true now, and a recap of the whole story. The earlier part's tracker can lag
    /// behind its final scene, so the next part takes its starting state from this instead. With a
    /// GGUF model the answer is held to `JSONGrammar.ending`; either way it is checked in code.
    private func readEnding(_ src: Adventure) async -> Ending? {
        guard let last = src.transcript.last(where: { $0.role == .gm }) else { return nil }
        let player = src.playerName.isEmpty ? "you" : src.playerName
        var prompt = Prompts.ending + "\n\nTHE PLAYER: " + player + " (\"you\")"
        let cast = src.cast.prefix(8).map(\.name)
        if !cast.isEmpty { prompt += "\nPEOPLE IN THE STORY: " + cast.joined(separator: ", ") }
        prompt += "\nHOW IT BEGAN: " + clip(src.bible, 500)
        var went: [String] = []
        if !src.chapters.isEmpty { went = src.chapters.suffix(3).map { clip($0, 220) } }
        else if !src.events.isEmpty { went = src.events.suffix(6).map { clip($0, 140) } }
        else { went = src.timeline.suffix(5).map { clip($0, 140) } }
        if !went.isEmpty { prompt += "\nHOW IT WENT:\n" + went.map { "- " + $0 }.joined(separator: "\n") }
        let turns = Array(src.transcript.suffix(4))
        if turns.count > 2 {
            prompt += "\n\nJUST BEFORE THE LAST SCENE:\n" + turns.dropLast(2).map { ($0.role == .player ? "The player: " : "The story: ") + clip($0.text, 400) }.joined(separator: "\n")
        }
        if let said = turns.dropLast().last(where: { $0.role == .player }) { prompt += "\n\nTHE LAST SCENE\nThe player: " + clip(said.text, 500) }
        else { prompt += "\n\nTHE LAST SCENE" }
        prompt += "\nThe story: " + clip(last.text, 1800) + "\n\nWhere things stand at the last line, as one JSON object:"
        let reply = (try? await llm.complete(system: nil, prompt: prompt,
                                             options: .init(maxTokens: 450, temperature: 0.2, repetitionPenalty: 1.1, grammar: JSONGrammar.ending))) ?? ""
        let m = JSONExtract.object(reply) ?? Self.salvageJSON(reply)
        // Real content only: no copies of the instructions' own words, no empty placeholders.
        func ok(_ v: String) -> Bool {
            let probe = v.lowercased().prefix(28)
            return v.count > 2 && !(probe.count >= 12 && Prompts.ending.lowercased().contains(probe)) && !Self.echoesPrompt(v)
        }
        func text(_ k: String, _ cap: Int) -> String {
            let v = ((m[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ok(v) ? clip(v, cap) : ""
        }
        var end = Ending()
        end.place = text("place", 60)
        end.time = text("time", 120)
        end.withYou = text("with_you", 160)
        end.recap = text("recap", 700)
        for f in ((m["facts"] as? [Any]) ?? []).compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) })
        where ok(f) && !end.facts.contains(where: { Self.similar($0, f) }) {
            end.facts.append(clip(f, 200))
            if end.facts.count >= 8 { break }
        }
        let names = src.cast.flatMap { p in [p.name, p.name.split(separator: " ").first.map(String.init) ?? p.name] }
        end.people = Self.whereabouts(m["people"]).filter { w in
            ok(w.at) && names.contains { $0.caseInsensitiveCompare(w.name) == .orderedSame }
        }.prefix(6).map { $0 }
        return end.place.isEmpty && end.people.isEmpty && end.recap.isEmpty ? nil : end
    }

    /// The earlier story, as the architect reads it for the next part, within `budget` tokens (the
    /// architect's call has a 4,096-token conversation with 1,500 kept for its answer, so an
    /// over-long message would be cut in the middle). The ending matters most, then the state the
    /// story was left in and how it went; the bible and the cast give way first.
    private func sourceWorld(_ src: Adventure, budget: Int, ending: Ending?) -> String {
        // Whether the review read the final reply (stories finished before it did may be stale).
        let reviewedEnd = src.transcript.last?.after?.contains("REVIEW:") == true
        func build(_ k: Double) -> String {
            func n(_ chars: Int) -> Int { max(80, Int(Double(chars) * k)) }
            var s = "EARLIER STORY: \"" + (src.report?.title ?? src.title) + "\"\nBIBLE (as it began):\n" + clip(src.bible, n(1200))
            let lore = src.lore.filter { !$0.isPlayer }.prefix(12)
            if !lore.isEmpty { s += "\nPEOPLE, PLACES AND THINGS:\n" + lore.map { "- \($0.name) (\($0.kind.rawValue)): " + clip($0.desc, n(140)) }.joined(separator: "\n") }
            var went: [String] = []
            if let r = src.report, !r.summary.isEmpty { went = [clip(r.summary, n(700))] }
            else if !src.chapters.isEmpty { went = src.chapters.suffix(3).map { clip($0, n(240)) } }
            else if !src.events.isEmpty { went = src.events.suffix(8).map { clip($0, n(140)) } }
            else { went = src.timeline.suffix(6).map { clip($0, n(140)) } }
            if !went.isEmpty { s += "\nHOW IT WENT:\n" + went.map { "- " + $0 }.joined(separator: "\n") }
            var state: [String] = []
            if let end = ending {
                // Read from the final scene itself, so it is current.
                if !end.place.isEmpty { state.append("Place: " + end.place) }
                if !end.time.isEmpty { state.append("Time: " + end.time) }
                if !end.withYou.isEmpty { state.append("With the player: " + end.withYou) }
                state += end.people.map { "\($0.name): \($0.at)" + ($0.doing.isEmpty ? "" : ", " + $0.doing) }
                state += end.facts.map { clip($0, n(140)) }
            } else if reviewedEnd {
                // The tracker read the final reply. A tracker that didn't is left out: it describes
                // the scene before the ending, and a small model copies it.
                if !src.location.isEmpty { state.append("Place: " + src.location) }
                if !src.storyTime.isEmpty { state.append("Time: " + clip(src.storyTime, 120)) }
                if !src.scene.isEmpty { state.append("Scene: " + clip(src.scene, n(360))) }
                state += src.whereabouts.prefix(5).map { "\($0.name): \($0.at)" + ($0.doing.isEmpty ? "" : ", " + $0.doing) }
                state += src.facts.prefix(10).map { clip($0, n(140)) }
            }
            if !state.isEmpty {
                s += "\nWHERE THINGS STAND AT THE LAST LINE:\n" + state.map { "- " + $0 }.joined(separator: "\n")
            }
            if let last = src.transcript.last(where: { $0.role == .gm }) { s += "\nHOW IT ENDED (the last scene, word for word):\n" + clip(last.text, n(1100)) }
            return s
        }
        var s = ""
        for k in [1.0, 0.8, 0.6, 0.45, 0.33, 0.25] {
            s = build(k)
            if Self.tokens(s) <= budget { break }
        }
        return s
    }

    /// The stories this one continues, nearest first (none for a fresh start or a prequel, whose
    /// earlier events haven't happened).
    private func earlierStories(_ a: Adventure) -> [Adventure] {
        guard a.link.range(of: "fresh|prequel", options: [.regularExpression, .caseInsensitive]) == nil else { return [] }
        var out: [Adventure] = []
        var seen: Set<UUID> = [a.id]
        var next = a.sequelOf
        while let id = next, !seen.contains(id), let s = library.adventures.first(where: { $0.id == id }) {
            out.append(s)
            seen.insert(id)
            next = s.link.range(of: "fresh|prequel", options: [.regularExpression, .caseInsensitive]) == nil ? s.sequelOf : nil
        }
        return out
    }

    func create(_ e: Experience, player: PlayerDetails, source: Adventure? = nil, link: String = "") {
        stopAll()
        busy = true
        building = true
        error = nil
        let forge = Forge(name: e.title.isEmpty ? (source.map { $0.report?.title ?? $0.title } ?? "Your world") : e.title,
                          curated: CuratedExperiences.all.contains { $0.id == e.id }, onePlace: e.simulator)
        self.forge = forge
        ComputerSounds.shared.startHum()
        currentTask = Task {
            defer { busy = false; stage = "" }
            do { try await llm.load() } catch {
                self.error = error.localizedDescription
                ComputerSounds.shared.stopHum()
                building = false
                forge.abort()
                return
            }
            guard !Task.isCancelled else { return }

            var a = Adventure(setup: e, title: e.title.isEmpty ? "Untitled" : e.title, minutes: max(5, e.minutes))
            a.playerName = player.name
            a.nameless = true
            // The architect asks only for what the opening needs: no secrets, beats or roadmap.
            var request = e.simulator ? Prompts.architectGrounded + "\n" + Prompts.architectSimulatorGrounded : Prompts.architectGrounded
            if source != nil { request += "\n" + Prompts.continuation }
            request += "\n" + Prompts.architectNameless(playerNamed: !player.name.isEmpty)
            request += "\n" + Prompts.hardLimits
            var prompt = "PLAYER'S ANSWERS\n" + e.answers(player: player)
                + "\n\nFEELING TO ACHIEVE: " + (e.feeling.isEmpty ? "surprise me" : e.feeling)
                + "\nPLAY MODE: " + (e.simulator ? "experience (no plot)" : "story")
            var ending: Ending?
            if let src = source {
                stage = "Reading how the last part ended"
                ending = await readEnding(src)
                guard !Task.isCancelled else { return }
                stage = ""
                // Room left in the architect's 4,096-token conversation once its answer and the rest are counted.
                let room = LLMService.contextBudget - 1500 - Self.safetyTokens - Self.tokens(request + "\n\n" + prompt) - 40
                prompt = sourceWorld(src, budget: max(300, room), ending: ending) + "\n\nCONNECTION TO THE EARLIER STORY: " + link + "\n\n" + prompt
            }
            var plan: [String: Any]?
            // Streamed, so the build screen can follow the architect section by section.
            var raw = ""
            do {
                for try await piece in llm.stream(system: nil, history: [ChatTurn(role: .user, text: request + "\n\n" + prompt)],
                                                  options: .init(maxTokens: 1500, temperature: 0.7)) {
                    raw += piece
                    forge.feed(piece)
                }
            } catch {}
            guard !Task.isCancelled else { return }
            noteQ("cards", "Build the world (the architect)", raw, since: forge.started)
            // A reply cut off before its last brace still holds the place and the people: what
            // can be read of it is kept rather than thrown away.
            @MainActor func readPlan(_ text: String) -> [String: Any]? {
                if let whole = JSONExtract.object(text) { return whole }
                let part = Self.salvageJSON(text)
                return part["lore"] != nil || part["location"] != nil ? part : nil
            }
            plan = readPlan(raw)
            if plan == nil {
                let t0 = Date()
                if let retry = try? await llm.complete(system: nil, prompt: request + "\n\n" + prompt, options: .init(maxTokens: 1500, temperature: 0.5)) {
                    noteQ("cards", "Build the world again (the first reply could not be read)", retry, since: t0)
                    plan = readPlan(retry)
                }
            }
            guard !Task.isCancelled else { return }
            apply(plan ?? [:], to: &a, setup: e, player: player)
            // Still nobody but the player (the architect's reply was lost): one small question
            // names the people the story the player picked puts here, so the map has them.
            if !a.cast.contains(where: { !$0.isPlayer }) {
                stage = "Who is here?"
                let story = [e.describe, e.place, e.allies, e.goal].filter { !$0.isEmpty }.joined(separator: "\n")
                let q = "THE STORY THE PLAYER PICKED:\n" + clip(story, 900)
                    + "\nQUESTION: Who is in this place as the story opens, apart from the player? Up to three people the story names or plainly needs (a bartender, a regular), each with a name true to its time and place, and their role in a few words.\nOutput ONLY one JSON object:\n{\"people\":[{\"name\":\"a first and last name\",\"role\":\"a few words\"}]}\nThe form:"
                let t0 = Date()
                let raw2 = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 120, temperature: 0.5, repetitionPenalty: 1.1,
                                                                                         grammar: JSONGrammar.namedPeople(max: 3)))) ?? ""
                noteQ("cards", "Who is here? (the architect's reply was lost)", raw2, since: t0)
                let m = JSONExtract.object(raw2) ?? Self.salvageJSON(raw2)
                for d in ((m["people"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }).prefix(3) {
                    let n = ((d["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let r = ((d["role"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard n.count > 2, !Self.echoesPrompt(n) else { continue }
                    guard !a.lore.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else { continue }
                    var card = LoreEntry(name: n, kind: .person, desc: r)
                    card.role = r
                    _ = addLore(&a, card)
                    a.whereabouts.append(Whereabout(name: n, at: a.location.isEmpty ? "here" : a.location, here: true, engaged: false))
                }
                stage = ""
            }
            if let src = source {
                // The returning cast and world come along; the architect's own entries stay on top.
                a.sequelOf = src.id
                a.link = link
                for old in src.lore where !old.isPlayer {
                    if let i = a.lore.firstIndex(where: { $0.name.caseInsensitiveCompare(old.name) == .orderedSame }) {
                        if old.byPlayer { a.lore[i] = old } else { a.lore[i].known = true }
                    } else if a.lore.count < 40 {
                        var returning = old
                        returning.known = true
                        returning.updatedTurn = nil
                        a.lore.append(returning)
                    }
                }
                carryOver(from: src, into: &a, link: link)
                if let ending, !link.lowercased().contains("later") { startAtEnding(ending, into: &a) }
            }
            adventure = a
            undoSnapshot = nil
            refreshVocabulary()
            library.save(a)
            // The first room is drawn after the opening is written, from what the story dreamed up;
            // it is never redrawn after.
            // The plan sometimes comes back with nobody placed. Whoever the premise or the opening
            // scene names is in the opening room (else the whole cast, up to three), so the map and
            // the storyteller both have them.
            let me1 = Cards.first(a.playerName).lowercased()
            let others = a.cast.filter { !$0.isPlayer && Cards.first($0.name).lowercased() != me1 }
            if !others.isEmpty, !a.whereabouts.contains(where: { $0.here != false }) {
                let text = a.bible + " " + a.scene + " " + a.setup.place
                let named = others.filter { Cards.mentions($0, in: text) }
                for c in (named.isEmpty ? Array(others.prefix(3)) : named) where !a.whereabouts.contains(where: { $0.name == c.name }) {
                    a.whereabouts.append(Whereabout(name: c.name, at: a.location.isEmpty ? "here" : a.location, here: true, engaged: false))
                }
                adventure = a
                library.save(a)
            }
            // The clock first, from one source of truth: the player's own words. One small
            // question reads the opening hour off them ("two in the morning" is 2:00, "a stormy
            // night" is its likeliest hour), before anything else is made, so every later question
            // (looks, lives, the check) and the opening are grounded on the same time, and the
            // check can catch a fact that names another.
            clockFromPremise = false
            if source == nil {
                let own = [e.describe, e.place].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
                if !own.isEmpty {
                    stage = "What time is it?"
                    let q = "THE STORY AS THE PLAYER WROTE IT:\n" + clip(own, 700)
                        + "\nQUESTION: At what time of day does this story open? Go by the player's own words above: a time they name ('half past nine', 'two in the morning') is exactly that time; a part of the day ('a stormy night', 'a Saturday morning') is its likeliest hour for what happens there. On a 24-hour clock: the hour from 0 to 23 (midnight is 0, 9 in the morning is 9, 9 in the evening is 21) and the minute from 0 to 59.\nOutput ONLY one JSON object:\n{\"hour\":\"a number\",\"minute\":\"a number\"}\nThe form:"
                    let q0 = Date()
                    let raw = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 30, temperature: 0.1, repetitionPenalty: 1.0,
                                                                                         grammar: JSONGrammar.twoNumbers("hour", "minute")))) ?? ""
                    noteQ("cards", "What time does the story open?", raw, since: q0)
                    guard !Task.isCancelled else { return }
                    let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
                    if let h = Int((m["hour"] as? String) ?? ""), h >= 0, h <= 23 {
                        let mm = min(59, max(0, Int((m["minute"] as? String) ?? "") ?? 0))
                        a.clock = h * 60 + mm
                        a.storyTime = Continuity.storyTime(clock: h * 60 + mm, old: a.storyTime)
                        clockFromPremise = true
                    }
                    stage = ""
                    adventure = a
                    library.save(a)
                }
            }
            // The people here know each other somehow: one small question per pair (at most
            // three), so the bartender and the regular stay consistent about each other. Neither
            // tells the player unless asked.
            if source == nil {
                let here = a.cast.filter { c in !c.isPlayer && Cards.first(c.name).lowercased() != me1
                    && a.whereabouts.contains { $0.name == c.name && $0.here != false } }
                var pairs: [(LoreEntry, LoreEntry)] = []
                for i in here.indices { for j in here.indices where j > i { pairs.append((here[i], here[j])) } }
                for (x, y) in pairs.prefix(3) {
                    stage = "How do they know each other?"
                    func who(_ c: LoreEntry) -> String { c.name + (c.role.isEmpty ? "" : " (" + c.role + ")") }
                    let q = "THE STORY: " + clip(a.bible, 500) + Self.castAsWritten(a) + "\nPEOPLE: " + who(x) + ": " + clip(x.desc, 160) + "\n" + who(y) + ": " + clip(y.desc, 160)
                        + "\nQUESTION: How do " + x.name + " and " + y.name + " know each other? If WHO THEY ARE or THE STORY says how they are related (father and daughter, married, old friends), keep exactly to that. One short, concrete sentence of at most 30 words, true to the story and its feeling (how long, what they share, one small thing one does for the other). Something the player has not been told.\nOutput ONLY one JSON object:\n{\"tie\":\"one short line\"}\nThe form:"
                    let q0 = Date()
                    let raw = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 110, temperature: 0.6, repetitionPenalty: 1.1,
                                                                                         grammar: JSONGrammar.text("tie", chars: 220)))) ?? ""
                    noteQ("cards", "How do " + Cards.first(x.name) + " and " + Cards.first(y.name) + " know each other?", raw, since: q0)
                    guard !Task.isCancelled else { return }
                    let tie = ((JSONExtract.object(raw) ?? Self.salvageJSON(raw))["tie"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard tie.count > 8 else { continue }
                    for (c, other) in [(x, y), (y, x)] {
                        guard let k = a.lore.firstIndex(where: { $0.id == c.id }), !a.lore[k].byPlayer else { continue }
                        a.lore[k].ties += (a.lore[k].ties.isEmpty ? "" : " ") + Cards.first(other.name) + ": " + clip(tie, 160)
                    }
                }
                stage = ""
                adventure = a
                library.save(a)
            }
            // Who each person is, made in one order so nothing is written before what it has to
            // fit: first their age and years here (two numbers: the anchor), then how they come
            // across (grounded on that age), then three things from their life (grounded on
            // both). A look written before the age was decided is how "a man in his late fifties"
            // came out 38 years old.
            // The settled numbers about one person, as code wrote them: every later question
            // about them is handed these, and the check holds the rest up against them.
            @MainActor func settled(_ c: LoreEntry) -> [String] {
                a.facts.filter { f in Cards.mentions(c, in: f) && f.hasPrefix(c.name) && (f.hasSuffix(" years old.") || f.contains(" has lived and worked here for ")) }
            }
            if source == nil {
                let here = a.cast.filter { c in !c.isPlayer && !c.byPlayer && Cards.first(c.name).lowercased() != me1
                    && a.whereabouts.contains { $0.name == c.name && $0.here != false } }
                let storyYear = Int(Fovea.year(a))
                for c in here.prefix(3) {
                    stage = "How old is " + Cards.first(c.name) + "?"
                    // Their age and their years here, as two whole numbers: the model picks them,
                    // code keeps them possible (nobody started work as a small child) and works
                    // out the year they began. The model never writes a calendar year itself.
                    let others = a.facts.filter { f in f.contains(" years old") }.suffix(4)
                    let aq = "THE STORY: " + clip(a.bible, 500) + Self.castAsWritten(a) + "\nWHEN: " + Fovea.whenWhere(a)
                        + "\nTHE PERSON: " + c.name + (c.role.isEmpty ? "" : " (" + c.role + ")") + ": " + clip(c.desc, 200)
                        + (c.ties.isEmpty ? "" : "\nHOW THEY KNOW THE OTHERS: " + clip(c.ties, 240))
                        + (others.isEmpty ? "" : "\nALREADY DECIDED:\n" + others.map { "- " + $0 }.joined(separator: "\n"))
                        + "\nQUESTION: How old is " + c.name + ", and for how many years have they lived or worked in this place? Keep to THE STORY (old, grown, young), to how they know the others, and to ALREADY DECIDED: a parent is at least 18 years older than their child; someone who hired or trained another has usually been there longer. Two whole numbers.\nOutput ONLY one JSON object:\n{\"age\":\"a number\",\"years_here\":\"a number\"}\nThe form:"
                    let a0 = Date()
                    let araw = (try? await llm.complete(system: nil, prompt: aq, options: .init(maxTokens: 30, temperature: 0.3, repetitionPenalty: 1.0,
                                                                                          grammar: JSONGrammar.twoNumbers("age", "years_here")))) ?? ""
                    noteQ("cards", "How old is " + Cards.first(c.name) + ", and how long here?", araw, since: a0)
                    guard !Task.isCancelled else { return }
                    let am = JSONExtract.object(araw) ?? Self.salvageJSON(araw)
                    if let age = Int((am["age"] as? String) ?? ""), age >= 16, age <= 100 {
                        let years = max(0, min(Int((am["years_here"] as? String) ?? "") ?? 0, age - 16))
                        // What the setup guessed about their age or years gives way to these numbers.
                        a.facts.removeAll { f in Cards.mentions(c, in: f) && !f.contains(" uses ") && f.range(of: #"(?i)\byears?\b"#, options: .regularExpression) != nil }
                        a.facts.append(c.name + " is \(age) years old.")
                        if years > 0 {
                            a.facts.append(c.name + " has lived and worked here for \(years) year\(years == 1 ? "" : "s")" + (storyYear.map { ", since \($0 - years)" } ?? "") + ".")
                        }
                    }
                }
                stage = ""
                adventure = a
                library.save(a)
            }
            // Each person here, once: how they come across in a room (their look, what they wear,
            // their voice, one habit), written to fit the age just settled. It goes on their card
            // and comes along whenever they are in a scene, so they read as real people from the
            // first line.
            if source == nil {
                let here = a.cast.filter { c in !c.isPlayer && Cards.first(c.name).lowercased() != me1 && c.looks.isEmpty
                    && a.whereabouts.contains { $0.name == c.name && $0.here != false } }
                for c in here.prefix(3) {
                    stage = "Getting to know " + Cards.first(c.name)
                    let fixed = settled(c)
                    let q = "THE STORY: " + clip(a.bible, 500) + Self.castAsWritten(a) + "\nWHEN: " + Fovea.whenWhere(a)
                        + "\nTHE PERSON: " + c.name + (c.role.isEmpty ? "" : " (" + c.role + ")") + ": " + clip(c.desc, 200)
                        + (fixed.isEmpty ? "" : "\nSETTLED (true; their look must fit it):\n" + fixed.map { "- " + $0 }.joined(separator: "\n"))
                        + "\nQUESTION: How does " + Cards.first(c.name) + " come across to someone who walks in? Keep to what THE STORY, WHO THEY ARE and SETTLED say about them (their age, their work). Their look (face, build, one striking detail; they look exactly the age SETTLED gives, so name no other age), what they wear, how they sound when they talk (cadence, tone, accent, a phrase they lean on; never what they will or won't talk about, and no 'only' or 'never'), and one small habit of theirs. True to their time, place and work; specific and a little imperfect, like a real person. Each a complete phrase of at most 14 words.\nOutput ONLY one JSON object:\n{\"looks\":\"a short line\",\"wears\":\"a short line\",\"voice\":\"a short line\",\"habit\":\"a short line\"}\nThe form:"
                    let q0 = Date()
                    let raw = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 240, temperature: 0.7, repetitionPenalty: 1.1,
                                                                                         grammar: JSONGrammar.quad([("looks", 110), ("wears", 110), ("voice", 110), ("habit", 110)])))) ?? ""
                    noteQ("cards", "How does " + Cards.first(c.name) + " come across?", raw, since: q0)
                    guard !Task.isCancelled else { return }
                    let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
                    @MainActor func v(_ k: String) -> String {
                        let t = ((m[k] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
                        return t.count > 3 && !Self.echoesPrompt(t) ? t : ""
                    }
                    guard let k = a.lore.firstIndex(where: { $0.id == c.id }), !a.lore[k].byPlayer else { continue }
                    a.lore[k].looks = v("looks"); a.lore[k].wears = v("wears"); a.lore[k].voice = v("voice"); a.lore[k].habit = v("habit")
                }
                stage = ""
                adventure = a
                library.save(a)
            }
            // Each person here, once: three true things from their life (where they were before,
            // a memory from here, something they are fond of), saved as facts. Small talk ("how
            // long have you kept this light?") then has something on file to answer from, and the
            // answer is the same every time. The examples come from this place, never from
            // another story: a list that says "a ship sighted" puts a ship in the desert.
            if source == nil {
                let here = a.cast.filter { c in !c.isPlayer && !c.byPlayer && Cards.first(c.name).lowercased() != me1
                    && a.whereabouts.contains { $0.name == c.name && $0.here != false } }
                for c in here.prefix(3) {
                    stage = "The life of " + Cards.first(c.name)
                    let fixed = settled(c)
                    let known = a.facts.filter { f in a.cast.contains { Cards.mentions($0, in: f) } && !f.contains(" uses ") && !fixed.contains(f) }.suffix(10)
                    let q = "THE STORY: " + clip(a.bible, 500) + Self.castAsWritten(a) + "\nWHEN AND WHERE: " + Fovea.whenWhere(a)
                        + (a.setup.place.isEmpty ? "" : " " + clip(a.setup.place, 100))
                        + "\nTHE PERSON: " + c.name + (c.role.isEmpty ? "" : " (" + c.role + ")") + ": " + clip(c.desc, 200)
                        + (fixed.isEmpty ? "" : "\nSETTLED (true; every line must fit it):\n" + fixed.map { "- " + $0 }.joined(separator: "\n"))
                        + (c.ties.isEmpty ? "" : "\nHOW THEY KNOW THE OTHERS: " + clip(c.ties, 240))
                        + (c.privateLife.isEmpty ? "" : "\nPRIVATE: " + clip(c.privateLife, 200))
                        + (known.isEmpty ? "" : "\nALREADY ON FILE (keep to it; never repeat someone else's memory):\n" + known.map { "- " + clip($0, 160) }.joined(separator: "\n"))
                        + "\nQUESTION: Give three true things from " + c.name + "'s own life that they could tell a visitor: what they did or where they lived before, one memory from their time here, and one thing here they are proud of or fond of. Mundane, realistic and human-scale, made of what WHEN AND WHERE really has (its land and weather, its roads, its work, the people who pass through): nothing that could only happen in another kind of place, no tall tales, heroic rescues or large animals. Each fits SETTLED: nothing from before they could have been there, nothing older than they are. Theirs alone, different from anyone else's on file. No calendar years and no ages. Each a full sentence starting with their name, at most 20 words.\nOutput ONLY one JSON object:\n{\"life\":[\"three sentences\"]}\nThe form:"
                    let q0 = Date()
                    let raw = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 160, temperature: 0.6, repetitionPenalty: 1.1,
                                                                                         grammar: JSONGrammar.strings("life", max: 3, chars: 130)))) ?? ""
                    noteQ("cards", "What has " + Cards.first(c.name) + " lived?", raw, since: q0)
                    guard !Task.isCancelled else { return }
                    let life = (((JSONExtract.object(raw) ?? Self.salvageJSON(raw))["life"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    for l in life.prefix(3) where l.count > 12 && !Self.echoesPrompt(l) && !a.facts.contains(where: { Self.similar($0, l) }) {
                        a.facts.append(Cards.mentions(c, in: l) ? l : c.name + ": " + l)
                    }
                }
                stage = ""
                adventure = a
                library.save(a)
            }
            // Before the opening, the model reads back what was just made against the story as
            // the player wrote it, the clock and each person's settled numbers. The settled lines
            // are shown but can't be picked: they are the yardstick, not suspects. A line that
            // clashes ("a man in his late fifties" at 38, a boat in the desert, "early morning" at
            // 2 AM) is not simply dropped: the model writes it again with the reason in front of
            // it, a second short question confirms the new line fits, and only a line that still
            // fails is dropped.
            if source == nil {
                // One small check per person (everything written about them side by side: their
                // facts, their look, how they know the others, what they keep private), then one for
                // the rest. A short list is one a small model can actually hold up against itself.
                enum Line { case fact(Int), looks(Int), ties(Int), privateLife(Int) }
                var groups: [(who: String, fixed: [String], lines: [(String, Line)])] = []
                var claimed: Set<Int> = []
                let pronoun = { (f: String) in f.hasSuffix(" uses he/him.") || f.hasSuffix(" uses she/her.") || f.hasSuffix(" uses they/them.") }
                for (k, c) in a.lore.enumerated() where c.kind == .person && !c.isPlayer && !c.byPlayer {
                    let fixed = settled(c)
                    var l: [(String, Line)] = []
                    for (i, f) in a.facts.enumerated() where !pronoun(f) && Cards.mentions(c, in: f) {
                        claimed.insert(i)
                        if !fixed.contains(f) { l.append((f, .fact(i))) }
                    }
                    if !c.looks.isEmpty { l.append((c.name + " looks: " + c.looks, .looks(k))) }
                    if !c.ties.isEmpty { l.append((c.name + ", how they know the others: " + c.ties, .ties(k))) }
                    if !c.privateLife.isEmpty { l.append((c.name + ", private: " + c.privateLife, .privateLife(k))) }
                    if !l.isEmpty { groups.append((c.name + (c.role.isEmpty ? "" : " (" + c.role + ")"), fixed, l)) }
                }
                // Even one line is checked: a lone "It is early morning" is exactly the kind that
                // disagrees with the clock.
                let rest: [(String, Line)] = a.facts.enumerated().filter { !claimed.contains($0.offset) && !pronoun($0.element) }.map { ($0.element, .fact($0.offset)) }
                if !rest.isEmpty { groups.append(("", [], rest)) }
                var dropFacts: Set<Int> = []
                for g in groups {
                    stage = "Checking the story holds together"
                    let numbered = g.lines.enumerated().map { "\($0.offset + 1). " + clip($0.element.0, 180) }.joined(separator: "\n")
                    let ground = "THE STORY: " + clip(a.bible, 500) + Self.castAsWritten(a) + "\nWHEN AND WHERE: " + Fovea.whenWhere(a)
                        + (a.setup.place.isEmpty ? "" : " " + clip(a.setup.place, 100))
                        + (g.who.isEmpty ? "" : "\nABOUT: " + g.who)
                        + (g.fixed.isEmpty ? "" : "\nSETTLED (true):\n" + g.fixed.map { "- " + $0 }.joined(separator: "\n"))
                    let q = ground + "\nLINES:\n" + numbered
                        + "\nQUESTION: Read the LINES together, as one life. Which LINES can't be true alongside THE STORY, WHEN AND WHERE, SETTLED or the other lines? Check: an age or a look that gives a different age than SETTLED; years at their work that don't fit; how two people are related; a time of day other than WHEN; something that could not be in this place or time (water, boats or snow where there are none, a thing not yet invented). Usually none.\nOutput ONLY one JSON object:\n{\"wrong\":[\"line numbers\"]}\nThe form:"
                    let q0 = Date()
                    let raw = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 40, temperature: 0.1, repetitionPenalty: 1.1,
                                                                                         grammar: JSONGrammar.strings("wrong", max: 3, chars: 3)))) ?? ""
                    noteQ("cards", "Does anything clash" + (g.who.isEmpty ? "" : " about " + Cards.first(g.who)) + "?", raw, since: q0)
                    guard !Task.isCancelled else { return }
                    let picked = (((JSONExtract.object(raw) ?? Self.salvageJSON(raw))["wrong"] as? [Any]) ?? []).compactMap { Int("\($0)".trimmingCharacters(in: .whitespaces)) }
                    for n in Set(picked).sorted() where n >= 1 && n <= g.lines.count {
                        let line = g.lines[n - 1]
                        // What the line is, so the rewrite keeps its shape.
                        let (was, shape): (String, String) = {
                            switch line.1 {
                            case .fact(let i): return (a.facts[i], "one plain sentence that starts with the person's name, at most 20 words")
                            case .looks(let k): return (a.lore[k].looks, "how they look: face, build, one striking detail, at most 14 words")
                            case .ties(let k): return (a.lore[k].ties, "how they know the others: one short sentence")
                            case .privateLife(let k): return (a.lore[k].privateLife, "one concrete thing they keep to themselves, one sentence")
                            }
                        }()
                        stage = "Mending a line that didn't fit"
                        let rq = ground + "\nTHE LINE: " + clip(line.0, 200)
                            + "\nQUESTION: THE LINE was found not to fit: something in it can't be true alongside THE STORY, WHEN AND WHERE or SETTLED (an age, a time of day, a place, how people are related, something that doesn't belong here). Write it again so it fits all of them, keeping what it is about wherever that can be true. As " + shape + ".\nOutput ONLY one JSON object:\n{\"line\":\"the new line\"}\nThe form:"
                        let r0 = Date()
                        let rraw = (try? await llm.complete(system: nil, prompt: rq, options: .init(maxTokens: 80, temperature: 0.4, repetitionPenalty: 1.1,
                                                                                              grammar: JSONGrammar.text("line", chars: 180)))) ?? ""
                        noteQ("cards", "Write again: " + clip(was, 60), rraw, since: r0)
                        guard !Task.isCancelled else { return }
                        var fixedLine = (((JSONExtract.object(rraw) ?? Self.salvageJSON(rraw))["line"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if case .looks(let k) = line.1, fixedLine.hasPrefix(a.lore[k].name + " looks: ") { fixedLine = String(fixedLine.dropFirst((a.lore[k].name + " looks: ").count)) }
                        var holds = false
                        if fixedLine.count > 8, !Self.echoesPrompt(fixedLine), !Self.similar(fixedLine, was) {
                            // The mended line is checked once on its own: a yes keeps it.
                            let vq = ground + "\nTHE LINE: " + clip(fixedLine, 200)
                                + "\nQUESTION: Can THE LINE be true alongside THE STORY, WHEN AND WHERE and SETTLED: the same age, the same time of day, something that really could be in this place and time?\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:"
                            let v0 = Date()
                            let vraw = (try? await llm.complete(system: nil, prompt: vq, options: .init(maxTokens: 12, temperature: 0.0, repetitionPenalty: 1.0,
                                                                                                  grammar: JSONGrammar.one("answer", from: ["yes", "no"])))) ?? ""
                            noteQ("cards", "Does the new line fit?", vraw, since: v0)
                            guard !Task.isCancelled else { return }
                            holds = (((JSONExtract.object(vraw) ?? Self.salvageJSON(vraw))["answer"] as? String) ?? "").lowercased() == "yes"
                        }
                        switch line.1 {
                        case .fact(let i): if holds { a.facts[i] = fixedLine } else { dropFacts.insert(i) }
                        case .looks(let k): a.lore[k].looks = holds ? fixedLine : ""
                        case .ties(let k): a.lore[k].ties = holds ? fixedLine : ""
                        case .privateLife(let k): a.lore[k].privateLife = holds ? fixedLine : ""
                        }
                    }
                }
                if !groups.isEmpty {
                    a.facts = a.facts.enumerated().filter { !dropFacts.contains($0.offset) }.map(\.element)
                    stage = ""
                    adventure = a
                    library.save(a)
                }
            }
            forge.reach(forge.stages.count - 1)

            var told = ending?.recap ?? ""
            if told.count <= 40 { told = ((plan?["recap"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let opening = source.map { Prompts.continueOpening(link: link, recap: told.count > 40 ? clip(told, 700) : recap(of: $0),
                                                               ending: $0.transcript.last(where: { $0.role == .gm })?.text ?? "",
                                                               simulator: e.simulator, short: a.isShort) }
                ?? Prompts.openingInstruction(simulator: e.simulator, short: a.isShort)
            await runTurn(input: opening, hidden: true)
            building = false
            forge.close()
        }
    }

    /// The next part starts from the state the architect worked out from how the earlier story
    /// ended (place, time, who is where, facts, timeline): the earlier part's own tracker can lag
    /// behind its final scene, so it only fills what the architect left out. The mission map
    /// carries over, with the route from where the earlier part was to where this one opens.
    private func carryOver(from src: Adventure, into a: inout Adventure, link: String) {
        if a.timeline.isEmpty { a.timeline = Array(src.timeline.suffix(3)) }
        let later = link.lowercased().contains("later")
        let opening = a.location
        a.places = src.places
        a.links = src.links
        if !opening.isEmpty { a.visit(opening, from: src.location) }
        // Every place keeps its props from part to part, even after time passes; the new part's
        // own opening scene wins for the place it opens in.
        for (place, props) in src.placeThings where a.placeThings[place] == nil { a.placeThings[place] = props }
        guard !later else { return }
        if a.location.isEmpty, !src.location.isEmpty { a.location = src.location; a.visit(src.location, from: "") }
        if a.storyTime.isEmpty, let c = src.clock { a.clock = c; a.storyTime = src.storyTime }
        if a.whereabouts.isEmpty { a.whereabouts = src.whereabouts }
        if a.carrying.isEmpty { a.carrying = src.carrying }
        if a.things.isEmpty { a.things = src.things }
    }

    /// "Right where it left off": the new part opens where the final scene ended, set in code from
    /// `readEnding` so it never depends on the architect (a small model tends to copy the old
    /// bible's opening situation). The bible gets a first line saying where things stand now.
    private func startAtEnding(_ end: Ending, into a: inout Adventure) {
        if !end.place.isEmpty {
            let place = Self.placeName(end.place, known: a.lore.filter { $0.kind == .place }.map(\.name))
            if a.location.caseInsensitiveCompare(place) != .orderedSame { a.visit(place, from: a.location) }
            a.location = place
            if !a.lore.contains(where: { $0.name.caseInsensitiveCompare(place) == .orderedSame }) {
                addLore(&a, LoreEntry(name: place, kind: .place, desc: ""))
            }
        }
        if !end.time.isEmpty {
            if let m = Continuity.minutes(in: end.time) {
                a.clock = m
                a.storyTime = Continuity.storyTime(clock: m, old: end.time)
            } else {
                a.clock = nil
                a.storyTime = end.time
            }
        }
        if !end.people.isEmpty {
            // The ending says who was with the player at the last line; everyone else is elsewhere.
            let with = end.withYou.lowercased()
            a.whereabouts = end.people.map { p in
                var w = p
                if !with.isEmpty, let first = p.name.lowercased().split(separator: " ").first { w.here = with.contains(first) }
                return w
            }
        }
        if !end.facts.isEmpty {
            let people = a.cast.map(\.name) + [a.playerName]
            var facts = end.facts.compactMap { Continuity.lastingFact($0, people: people) }
            for f in a.facts where !facts.contains(where: { Self.similar($0, f) }) { facts.append(f) }
            a.facts = Array(facts.prefix(14))
        }
        var now: [String] = []
        if !a.location.isEmpty { now.append("you are at " + a.location) }
        if !end.withYou.isEmpty, end.withYou.lowercased() != "nobody" { now.append("with " + end.withYou) }
        if !a.storyTime.isEmpty { now.append(a.storyTime) }
        if !now.isEmpty { a.bible = "RIGHT NOW, where the last part ended: " + now.joined(separator: ", ") + ".\n\n" + a.bible }
        a.scene = ([a.location.isEmpty ? "" : "You are at " + a.location + "."]
                   + end.people.map { "\($0.name) is \($0.at)." }).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What happened in the earlier part, for the "Last time" recap at the start of the next one.
    private func recap(of src: Adventure) -> String {
        if let r = src.report, !r.summary.isEmpty { return clip(r.summary, 600) }
        if !src.chapters.isEmpty { return src.chapters.suffix(3).map { clip($0, 220) }.joined(separator: " ") }
        if !src.events.isEmpty { return src.events.suffix(6).map { clip($0, 140) }.joined(separator: " ") }
        return src.timeline.suffix(5).map { clip($0, 140) }.joined(separator: " ")
    }

    private func apply(_ plan: [String: Any], to a: inout Adventure, setup e: Experience, player: PlayerDetails) {
        func str(_ k: String, _ d: [String: Any]? = nil) -> String { ((d ?? plan)[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if !str("title").isEmpty, e.title.isEmpty { a.title = str("title") }
        a.bible = str("bible").isEmpty ? e.describe + "\n\n" + e.answers(player: player) : str("bible")
        let openingPlace = str("location").isEmpty ? e.place : str("location")

        // The player
        let p = plan["player"] as? [String: Any]
        let invented = !str("name", p).isEmpty ? str("name", p) : str("player_name")
        // Nameless: the player has no name until they say one in the story, so a name the
        // architect made up is taken back out of the bible.
        let playerName = !player.name.isEmpty ? player.name : a.nameless ? "" : invented
        if a.nameless, player.name.isEmpty, !invented.isEmpty {
            var t = a
            t.playerName = invented
            t.lore = []
            a.bible = Continuity.unnamed(a.bible, in: t, playerTold: false)
        }
        a.playerName = playerName
        a.lore = [LoreEntry(name: playerName.isEmpty ? "You" : playerName, kind: .person,
                            desc: [str("desc", p), e.who, e.traits].filter { !$0.isEmpty }.joined(separator: ". "), isPlayer: true)]

        // Places, people and things
        // An experience lives in the one place it opens in; places are added when the player goes somewhere.
        for place in e.simulator ? [] : (plan["places"] as? [Any]) ?? [] {
            let d = place as? [String: Any]
            let name = (place as? String) ?? str("name", d)
            if !name.isEmpty { addLore(&a, LoreEntry(name: name, kind: .place, desc: str("desc", d))) }
        }
        a.location = Self.placeName(openingPlace, known: a.lore.filter { $0.kind == .place }.map(\.name))
        a.visit(a.location, from: "")
        if !a.location.isEmpty, !a.lore.contains(where: { $0.name.caseInsensitiveCompare(a.location) == .orderedSame }) {
            addLore(&a, LoreEntry(name: a.location, kind: .place, desc: openingPlace == a.location ? "" : openingPlace))
        } else {
            Self.enrichPlace(&a, a.location, with: openingPlace)
        }
        let cap = (a.minutes >= 30 ? 3 : 2) + 1
        var people = 0
        for item in ((plan["lore"] as? [[String: Any]]) ?? []) + ((plan["cast"] as? [[String: Any]]) ?? []) {
            let name = str("name", item)
            guard !name.isEmpty, name.caseInsensitiveCompare(playerName) != .orderedSame else { continue }
            let kind = item["type"] is String ? LoreEntry.kind(from: str("type", item)) : .person
            // Places come only from "places": a place the architect slipped into the lore (the
            // flower shop the speakeasy hides behind) would put a second place on a one-place map.
            if kind == .place { continue }
            if kind == .person { people += 1; if people > cap + 1 { continue } }
            let pronouns = str("pronouns", item)
            if kind == .person, !pronouns.isEmpty { a.facts.append("\(name) uses \(pronouns).") }
            let at = addLore(&a, LoreEntry(name: name, kind: kind, desc: str("desc", item), role: str("role", item),
                                           known: kind != .person || (!a.nameless && (item["known"] as? Bool ?? false)), wants: str("wants", item)))
            if kind == .person { a.lore[at].privateLife = clip(str("private", item), 240) }
        }

        a.beats = ((plan["beats"] as? [Any]) ?? []).compactMap { b in
            (b as? String) ?? ((b as? [String: Any])?["beat"] as? String)
        }.map { Beat(text: $0) }
        a.roadmap = ((plan["roadmap"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let g = r["goal"] as? String else { return nil }
            return Act(from: (r["from"] as? NSNumber)?.doubleValue ?? 0, to: (r["to"] as? NSNumber)?.doubleValue ?? Double(a.minutes), goal: g)
        }
        // An experience has no acts: what the player does decides what happens next.
        if e.simulator {
            a.beats = []
            a.roadmap = []
        }
        a.facts += ((plan["facts"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(10)
        a.facts = Array(a.facts.prefix(14))
        a.storyTime = clip(str("time"), 160)
        if let m = Continuity.minutes(in: a.storyTime) {
            a.clock = m
            a.storyTime = Continuity.storyTime(clock: m, old: a.storyTime)
        }
        a.timeline = ((plan["timeline"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(5).map { clip($0, 200) }
        a.whereabouts = Self.whereabouts(plan["people"]).filter { w in
            w.name.caseInsensitiveCompare(playerName) != .orderedSame && w.name.caseInsensitiveCompare("you") != .orderedSame
        }.map { w in
            // Everyone the architect places is in the opening place (the regular in the corner booth
            // is in the room, not elsewhere); "with the player" only says who the player is dealing with.
            var w = w
            w.engaged = w.here
            w.here = true
            return w
        }
        // The opening scene: the room, its props and who is in it, set before the first line so
        // the globe and the storyteller start from the same place.
        a.scene = clip(str("scene"), 280)
        let props = ((plan["things"] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        a.things = Array(props.prefix(6)).map { clip($0, 60) }
        if !a.location.isEmpty, !a.things.isEmpty { a.placeThings[a.location.lowercased()] = a.things }
        checkPronouns(&a, texts: [a.bible, a.scene])
        a.secrets = (plan["secrets"] as? [String]) ?? []
        if !e.beats.isEmpty { a.secrets.append("Story guide: " + e.beats) }
    }

    /// Adds an entry, or updates the one with the same name (the player's own edits always win).
    @discardableResult
    /// `lately`: the entry is news from the latest exchange, not a new description of who a person is.
    private func addLore(_ a: inout Adventure, _ e: LoreEntry, lately: Bool = false) -> Int {
        let key = e.name.lowercased()
        if let i = a.lore.firstIndex(where: { $0.name.lowercased() == key || (e.kind == .person && !e.role.isEmpty && !$0.known && $0.role.lowercased() == e.role.lowercased()) }) {
            if !a.lore[i].byPlayer {
                if !e.desc.isEmpty {
                    if lately, a.lore[i].kind == .person, !a.lore[i].desc.isEmpty {
                        // Who someone is stays; what they are up to now is kept after it.
                        let base = a.lore[i].desc.components(separatedBy: " Lately: ").first ?? a.lore[i].desc
                        a.lore[i].desc = base + " Lately: " + e.desc
                    } else {
                        a.lore[i].desc = e.desc
                    }
                }
                if !e.wants.isEmpty { a.lore[i].wants = e.wants }
                if !e.role.isEmpty, a.lore[i].role.isEmpty { a.lore[i].role = e.role }
                if a.lore[i].kind == .other { a.lore[i].kind = e.kind }
            }
            return i
        }
        a.lore.append(e)
        return a.lore.count - 1
    }

    // MARK: Editing the world (the World panel)

    func saveLore(_ e: LoreEntry) {
        guard var a = adventure else { return }
        var e = e
        e.byPlayer = true
        if let i = a.lore.firstIndex(where: { $0.id == e.id }) { a.lore[i] = e } else { a.lore.append(e) }
        if e.isPlayer { a.playerName = e.name == "You" ? "" : e.name.trimmingCharacters(in: .whitespaces) }
        a.notesStale = a.notes != nil   // so the cast agendas stop describing the old version
        adventure = a
        library.save(a)
        refreshVocabulary()
    }

    /// A person or thing edited on the map. Your edit wins: what the story keeps about them (what
    /// they are doing, how they feel, their card) is updated to match, so the next turn uses it.
    func saveThing(_ t: Thing, in roomID: UUID) {
        guard var a = adventure, let ri = a.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        var r = a.rooms[ri]
        guard let i = r.index(t.id) else { return }
        let old = r.things[i]
        r.things[i] = t
        r.log.append("edit: " + t.name + " (your edit)")
        a.rooms[ri] = r
        if t.kind == .person {
            if let w = a.whereabouts.firstIndex(where: { $0.name.caseInsensitiveCompare(old.name) == .orderedSame }) {
                a.whereabouts[w].doing = t.doing
                a.whereabouts[w].name = t.name
            }
            if !t.feeling.isEmpty { a.feelings[t.name.lowercased()] = t.feeling }
        } else if t.kind == .player {
            a.carrying = t.holding
            a.feels = t.feeling
        } else if old.name != t.name {
            let key = r.name.lowercased()
            if var list = a.placeThings[key], let k = list.firstIndex(of: old.name) { list[k] = t.name; a.placeThings[key] = list }
            if let k = a.things.firstIndex(of: old.name) { a.things[k] = t.name }
        }
        adventure = a
        library.save(a)
    }

    /// Your name in this story, set from the World panel (never kept for other stories). Empty
    /// leaves you nameless until you say a name in the story.
    func setPlayerName(_ name: String) {
        guard var a = adventure else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n != a.playerName else { return }
        a.playerName = n
        if let i = a.lore.firstIndex(where: \.isPlayer) { a.lore[i].name = n.isEmpty ? "You" : n }
        adventure = a
        library.save(a)
        refreshVocabulary()
    }

    /// Hide names until they are said in the story (on), or let everyone go by name (off).
    func setNameless(_ on: Bool) {
        guard var a = adventure, a.nameless != on else { return }
        a.nameless = on
        adventure = a
        library.save(a)
    }

    func deleteLore(_ id: UUID) {
        guard var a = adventure else { return }
        a.lore.removeAll { $0.id == id && !$0.isPlayer }
        adventure = a
        library.save(a)
    }

    /// The whole story as plain text, for copying out to refine it. Kept short: the world as the
    /// app holds it now, then every turn with what happened behind the scenes (how the message was read, what was fetched and why, the prompt's size, and what was
    /// filed afterwards).
    /// The prompt as sent, cut down for the export: the system rules once (then "same as before"),
    /// the earlier story turns as one line with their size, the yes/no pass as one line (its marks
    /// are under WHAT MATTERS), and the moment's own block in full. What the model was sent is unchanged.
    static func compactPrompt(_ p: String, lastSystem: inout String) -> String {
        let parts = p.components(separatedBy: "\n\n").reduce(into: [String]()) { acc, piece in
            let heads = ["SYSTEM:\n", "USER:\n", "ASSISTANT:\n", "YES/NO PASS"]
            if heads.contains(where: { piece.hasPrefix($0) }) || acc.isEmpty { acc.append(piece) } else { acc[acc.count - 1] += "\n\n" + piece }
        }
        var out: [String] = []
        var history: [String] = []
        let lastUser = parts.lastIndex { $0.hasPrefix("USER:\n") }
        for (i, part) in parts.enumerated() {
            if part.hasPrefix("YES/NO PASS") {
                let items = part.components(separatedBy: "\n").filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }.count
                out.append("YES/NO PASS: asked first, over \(items) card items (\(tokens(part)) tokens); its marks are under WHAT MATTERS.")
            } else if part.hasPrefix("SYSTEM:\n") {
                if part == lastSystem { out.append("SYSTEM: the same rules as before (\(tokens(part)) tokens).") } else { out.append(part); lastSystem = part }
            } else if i == lastUser {
                if !history.isEmpty {
                    out.append("PLUS THE LAST \(history.count) TURNS OF THE STORY, as written above (\(history.reduce(0) { $0 + tokens($1) }) tokens).")
                    history = []
                }
                out.append(part)
            } else {
                history.append(part)
            }
        }
        return out.joined(separator: "\n\n")
    }

    /// A turn's notes, cut down for the export: WHAT MATTERS keeps only what went in (with a count
    /// of what was left out), and the rebuild leaves out answers that changed nothing.
    static func compactNotes(_ b: String) -> String {
        var out: [String] = []
        var section = ""
        var leftOut = 0
        func flushLeftOut() {
            if leftOut > 0 { out.append("  (\(leftOut) more left out)"); leftOut = 0 }
        }
        // Each heading says where it came from: the model's answers, or code reading the map.
        let labels: [(String, String)] = [
            ("LOOK:", "[MODEL ANSWERED] "), ("WHAT MATTERS", "[MODEL ANSWERED] "), ("REBUILT", "[MODEL ANSWERED] "),
            ("NAME CHECK", "[CODE] "), ("SETTLED IN CODE", "[CODE] "), ("FILED", "[CODE] "), ("THE ROOM AS TOLD", "[CODE, from the map] "),
            ("NOTES", "[CODE] "), ("PROMPT:", "[CODE] size of what was sent: "), ("TIMES", "[CODE] "), ("REFUSED", "[CODE] "),
        ]
        for raw in b.components(separatedBy: "\n") {
            var line = raw
            if !line.hasPrefix(" "), let l = labels.first(where: { line.hasPrefix($0.0) }) { line = l.1 + line }
            if !raw.hasPrefix(" ") { flushLeftOut(); section = raw }
            if section.hasPrefix("WHAT MATTERS"), line.hasPrefix("  - ") { leftOut += 1; continue }
            if section.hasPrefix("REBUILT"), line.hasPrefix("  - ") {
                let answer = line.components(separatedBy: " → ").last?.lowercased() ?? ""
                if ["nothing new", "no", "nothing", "not this turn", ""].contains(answer.trimmingCharacters(in: .whitespaces)) { continue }
            }
            out.append(line)
        }
        flushLeftOut()
        return out.joined(separator: "\n")
    }

    /// Just the conversation: the title, then what the player said and what the story said, in
    /// order. Everything behind the scenes is in the log.
    func dialogueText() -> String {
        guard let a = adventure else { return "" }
        var out = ["# " + a.title, ""]
        for t in a.transcript {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += [(t.role == .player ? "YOU: " : "") + text, ""]
        }
        return out.joined(separator: "\n")
    }

    func storyText(prompts: Bool = false) -> String {
        guard let a = adventure else { return "" }
        var out = ["# " + a.title, ""]
        if !a.setup.feeling.isEmpty { out.append("Feeling: " + a.setup.feeling) }
        if !a.setup.goal.isEmpty { out.append("Goal: " + a.setup.goal) }
        out.append("Foveated story (read, yes/no pass, paint, lean rebuild) · " + Self.build)
        let qs: [String] = questionLogFor == a.id ? questionLog : []
        if !qs.isEmpty {
            var perTurn: [String: Int] = [:]
            var order: [String] = []
            for q in qs {
                let k = String(q.prefix { $0 != "·" }).replacingOccurrences(of: "[", with: "").trimmingCharacters(in: .whitespaces)
                if perTurn[k] == nil { order.append(k) }
                perTurn[k, default: 0] += 1
            }
            out.append("Questions asked this session: \(qs.count) (" + order.map { $0 + ": \(perTurn[$0] ?? 0)" }.joined(separator: ", ") + "); every one is listed at the end")
        }
        out += ["", "## Premise (the storyteller's only standing view of the story)", Cards.premise(a)]
        out += ["", "## The world the app holds"]
        let names = a.nameless
        for p in a.lore where p.kind == .person && !p.isPlayer {
            let w = a.whereabouts.first { Cards.card(for: $0, in: a)?.id == p.id }
            let state = w.map { $0.here == false ? "elsewhere" : $0.engaged == true ? "with you" : "in the room" } ?? "not placed"
            let facts = Cards.facts(about: p, in: a).count
            let role: String = p.role.isEmpty ? "" : " (\(p.role))"
            let hidden: String = names && !p.known && !p.byPlayer ? " [name not said yet]" : ""
            let spot: String = w.map { ", " + Continuity.placed($0.at) } ?? ""
            let filed: String = facts == 0 ? "" : facts == 1 ? " · 1 fact on file" : " · \(facts) facts on file"
            out.append("- \(p.name)\(role)\(hidden): \(state)\(spot)\(filed)")
            if !p.privateLife.isEmpty { out.append("  kept from you until you ask: " + clip(p.privateLife, 160)) }
            if !p.ties.isEmpty { out.append("  how they know the others (unsaid): " + clip(p.ties, 200)) }
        }
        let placeCards = a.lore.filter { $0.kind == .place }.map(\.name)
        if !placeCards.isEmpty { out.append("- Place cards: " + placeCards.joined(separator: ", ")) }
        let items = a.lore.filter { $0.kind == .item || $0.kind == .faction || $0.kind == .other }.map(\.name)
        if !items.isEmpty { out.append("- Other cards: " + items.joined(separator: ", ")) }
        out.append("- Now: " + (a.location.isEmpty ? "on the move" : a.location) + (a.storyTime.isEmpty ? "" : " · " + a.storyTime))
        if !a.carrying.isEmpty { out.append("- You have: " + a.carrying.joined(separator: "; ")) }
        if !a.feels.isEmpty { out.append("- You feel: " + a.feels) }
        if !a.progress.isEmpty { out.append("- Toward the goal: " + a.progress.joined(separator: " · ")) }
        let here = Cards.props(a)
        if !here.isEmpty { out.append("- Props here: " + here.joined(separator: "; ")) }
        if !a.facts.isEmpty { out += ["", "## Facts on file (\(a.facts.count); each reply gets only the ones it needs)"] + a.facts.map { "- " + $0 } }
        for r in a.rooms {
            out += ["", "## Room: " + r.name + " (\(r.type), \(r.width) × \(r.depth) m" + (r.id == a.roomID ? ", you are here" : "") + ")",
                    "```", RoomGrid.ascii(r), "```"]
            if !r.log.isEmpty { out += ["How it was built and changed:"] + r.log.suffix(30).map { "- " + RoomMapView.logText($0) } }
        }
        // The full trace, when it is on: one log, in order, with times, instead of the sections.
        if prompts, Self.tracing, traceFor == a.id, !traceLog.isEmpty {
            out += ["", "## Full trace", "",
                    "Every step in order, [mm:ss] from the start, grouped into phases (┌ … └ with each phase's model questions and time):",
                    "🤖 MODEL ASKED = a question to the on-device model, with ◀ ANSWER under it · ⚙️ CODE = worked out in code, no model",
                    "💾 SAVED TO CARD = written to a person's or the story's card · 📍 MAP = placed, moved or changed on the map",
                    "📝 PROMPT SENT TO THE STORYTELLER = exactly what the reply was written from · ℹ️ NOTE = what the turn settled · 🚩 FLAGGED = needs a look",
                    "############ = what you said and what the story said", ""]
            out += traceLog
            if !tracePhase.isEmpty { out.append(String(format: "└── %@ still open: %d model question%@ so far", tracePhase, tracePhaseAsks, tracePhaseAsks == 1 ? "" : "s")) }
            if let said = pendingInput, !said.isEmpty { out += ["", "(STILL RUNNING when copied" + (stage.isEmpty ? "" : ": " + stage) + ")"] }
            if !streaming.isEmpty { out += ["", "STORY (so far):", streaming] }
            if !rebuildStep.isEmpty { out += ["(rebuild still running when copied: " + rebuildStep + ")"] }
            return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        out += ["", "## The story", ""]
        let me = a.playerName.isEmpty ? "YOU" : a.playerName.uppercased()
        var lastSystem = ""
        for t in a.transcript {
            if let b = t.before, !b.isEmpty { out += [Self.compactNotes(b), ""] }
            out.append((t.role == .player ? me : "GAME MASTER") + ":\n" + t.text)
            out.append("")
            if let b = t.after, !b.isEmpty { out += [Self.compactNotes(b), ""] }
            if prompts, let p = t.prompt, !p.isEmpty {
                out += ["[SENT TO THE MODEL] the prompt for this reply (only what is new this turn):", "<<<", Self.compactPrompt(p, lastSystem: &lastSystem), ">>>", ""]
            }
        }
        // Copied while a turn is still running: what the player said, and how far it got, so the
        // export never silently stops a turn short.
        if let said = pendingInput, !said.isEmpty, a.transcript.last(where: { $0.role == .player })?.text != said {
            out += [me + ":\n" + said, ""]
            var now = "STILL RUNNING when copied"
            if !stage.isEmpty { now += ": " + stage }
            out.append("(" + now + ")")
            if !streaming.isEmpty { out += ["", "GAME MASTER (so far):\n" + streaming] }
            out.append("")
        }
        if !rebuildStep.isEmpty { out += ["(The rebuild after the last reply was still running when copied: " + rebuildStep + ")", ""] }
        if !qs.isEmpty { out += ["", "## Every question asked, in order (\(qs.count))"] + qs.enumerated().map { "\($0.offset + 1). " + $0.element } }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Playing

    func send(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !busy, let a = adventure, !a.ended else { return }
        dictation.stop()
        dictation.clear()
        if Self.soundsLikeCrisis(input) { showSupport = true }
        busy = true
        pendingInput = input   // shown at once, while the Game Master finishes its review
        currentTask = Task {
            defer { busy = false; pendingInput = nil }
            await runTurn(input: input, hidden: false)
        }
    }

    /// Words that may mean the player themselves is thinking of suicide or self-harm (not a
    /// character in the story): "I want to kill myself", "I don't want to live anymore".
    static func soundsLikeCrisis(_ text: String) -> Bool {
        let p = #"(?i)\b(suicid\w*|kill(ing)? myself|hurt(ing)? myself|harm(ing)? myself|cut(ting)? myself|self[- ]harm\w*|end(ing)? (it all|my life|my own life)|take my (own )?life|want(ed)? to die|wish i (was|were) dead|better off dead|(don'?t|do not) want to (live|be alive|exist|be here)( any ?more)?|no reason to live|i can'?t go on (like this|any ?more))\b"#
        return text.range(of: p, options: .regularExpression) != nil
    }

    /// Back in the foreground: a reply that was cut off by leaving the app is written again.
    func resumeAfterBackground() {
        guard let t = interruptedTurn, adventure != nil, !busy else { return }
        interruptedTurn = nil
        busy = true
        currentTask = Task {
            defer { busy = false }
            await runTurn(input: t.input, hidden: t.hidden, forceFinal: t.forceFinal)
            if t.hidden { building = false; forge?.close() }
        }
    }

    /// Asks the Game Master to wrap up now, with a final reply.
    func endNow() {
        guard var a = adventure, !a.ended, !busy else { return }
        a.minutes = max(1, Int(a.elapsed / 60))
        a.left = 0
        adventure = a
        busy = true
        currentTask = Task {
            defer { busy = false }
            await runTurn(input: "(The player wants to end the story now. Bring it to its ending in this reply.)", hidden: false, forceFinal: true)
        }
    }

    func undo() {
        guard let snap = undoSnapshot, !busy else { return }
        stopAll()
        adventure = snap
        undoSnapshot = nil
        library.save(snap)
    }

    func editBible(_ text: String) {
        guard var a = adventure else { return }
        a.bible = text
        a.notesStale = a.notes != nil
        adventure = a
        library.save(a)
    }

    /// Kept free in every prompt, because token counts here are estimates.
    static let safetyTokens = 96
    /// The most the rules, bible and briefing can be squeezed (see `systemPrompt` and `briefingText`).
    static let tightest = 3
    /// Shown in the story export, so a playthrough can be matched to the code that ran it.
    static let build = "build 2026-11-18z109"

    /// Waits while a neural voice is still making speech, so background thinking never makes the
    /// narrator stop mid-sentence waiting for the GPU (at most a minute and a half).
    private func waitForVoice() async {
        var waited = 0.0
        while narrator.synthesizing, waited < 90, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 0.5
        }
    }

    /// The set-up's hard limits, for the Game Master and its reviews.
    private func limitsText(_ a: Adventure) -> String {
        var l: [String] = []
        if !a.setup.who.isEmpty { l.append("The player character: " + a.setup.who + (a.setup.traits.isEmpty ? "" : ". " + a.setup.traits)) }
        if !a.setup.avoid.isEmpty { l.append("The player asked: " + a.setup.avoid) }
        if a.setup.simulator { l.append("This is an experience with no threat, danger, villain or mystery.") }
        return l.map { "- " + $0 }.joined(separator: "\n")
    }

    private func factsText(_ a: Adventure) -> String {
        var s = ""
        // Facts tied to a place the player has left stay there, so its gramophone doesn't follow them.
        let facts = a.facts.filter { !Continuity.elsewhereFact($0, in: a) }
        if !facts.isEmpty { s += "FACTS (always true):\n" + facts.map { "- " + $0 }.joined(separator: "\n") }
        if !a.fixes.isEmpty { s += (s.isEmpty ? "" : "\n") + "SLIPS TO CORRECT FROM NOW ON (the true version):\n" + a.fixes.map { "- " + $0 }.joined(separator: "\n") }
        return s
    }

    // MARK: The grounded engine: read, fetch, paint, file

    /// How the player's new message was read: fixed choices, checked against what exists.
    struct PlayerRead {
        var to = ""          // a cast member's name, or "" for nobody
        var alsoTo = ""      // a second person addressed or invited with them ("both of you"), or ""
        var going = ""       // "" for staying, a known place, or "somewhere new"
        var newPlace = ""    // going somewhere new: its name, from the message
        var takes = ""       // what the player picks up or takes, in the read's words
        var putsDown = ""    // what the player puts down or gives away
        var spot = ""        // where in the place the player moves to
        var tells = ""       // what the player tells about themselves ("your name is Robert")
        var body = ""        // a change to the player's body ("sitting", "coat off")
        var feels = ""       // how the player says they feel
        var goalStep = ""    // what the player's own message does toward the goal
        /// The plan for the person faced, filled in by the same form as the look (one call, not two).
        var plan: [String: String] = [:]
        var looks: [Looks.Look] = []   // what the read asked to look up
        var answer = ""
        var beat = ""
        var does = ""        // the player's own action, restated: what the reply turns on
        var dropped = ""     // why the reader's next beat was not used, for the export
    }

    /// What both read questions see first (the same text, so llama.cpp reads it only once): the
    /// place, the names that exist, the end of the last reply and the player's new message.
    private func readContext(_ a: Adventure, input: String) -> String {
        let here = a.location
        let places = a.places.filter { $0.caseInsensitiveCompare(here) != .orderedSame }.suffix(5).map { $0 }
        let menu = Cards.menu(a, input: input)
        func state(_ name: String) -> String {
            guard let w = a.whereabouts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return "" }
            return w.here == false ? " [elsewhere]" : w.engaged == true ? " [with the player]" : " [in the place]"
        }
        var prompt = Prompts.readIntro + "\n\nFEELING: " + (a.setup.feeling.isEmpty ? "what the player came for" : a.setup.feeling)
        prompt += "\nTHE PLAYER IS IN: " + (here.isEmpty ? "(unnamed place)" : here)
        if !places.isEmpty { prompt += "\nOTHER PLACES: " + places.joined(separator: "; ") }
        let people: [String] = a.cast.map { $0.name + ($0.role.isEmpty ? "" : " (\($0.role))") + state($0.name) }
        prompt += "\nPEOPLE: " + (people.isEmpty ? "(none)" : people.joined(separator: "; "))
        // Who the player was already talking to: the read keeps them unless the player turns away.
        let talking: [String] = a.whereabouts.filter { $0.here != false && $0.engaged == true }.compactMap { w in
            Cards.card(for: w, in: a).map { $0.name + ($0.role.isEmpty ? "" : " (" + $0.role + ")") }
        }
        prompt += "\nTALKING WITH NOW: " + (talking.isEmpty ? "nobody yet" : talking.joined(separator: ", "))
        if !menu.isEmpty { prompt += "\nCARDS: " + menu.joined(separator: "; ") }
        let played = a.elapsed / 60
        if let act = a.roadmap.first(where: { played >= $0.from && played <= $0.to }) ?? a.roadmap.first(where: { played < $0.to }) {
            prompt += "\nTHE STORY IS HEADING TOWARD (only if the player goes along): " + clip(act.goal, 220)
        }
        if let last = a.transcript.dropLast().last(where: { $0.role == .gm }) {
            prompt += "\n\nTHE STORY JUST SAID (already answered; context only):\n" + clip("…" + String(last.text.suffix(400)), 420)
        }
        if let p = partsThisTurn {
            prompt += "\n\nTHE PLAYER'S NEW MESSAGE, in two parts:"
            prompt += "\nACTION OR WHAT HAPPENS (silent: what they physically do, or something they say happens, like someone arriving; the only part that can move them, turn them to someone or pick something up): " + (p.did.isEmpty ? "(none: they stay as they are, facing who they face)" : clip(p.did, 400))
            prompt += "\nSAID ALOUD (spoken words to who they face, never an action): " + (p.said.isEmpty ? "(nothing)" : "\"" + clip(p.said, 400) + "\"")
        } else {
            prompt += "\n\nTHE PLAYER'S NEW MESSAGE: " + clip(input, 800)
        }
        return prompt
    }

    /// Read, question 1: who the player turns to, where they go, and up to three lookups, all
    /// picked from what exists. Nil when the model gave nothing usable (code then settles the
    /// scene on its own).
    private func lookPlayer(_ a: Adventure, input: String, context: String) async -> PlayerRead? {
        let cast = a.cast.map(\.name)
        let here = a.location
        let places = a.places.filter { $0.caseInsensitiveCompare(here) != .orderedSame }.suffix(5).map { $0 }
        let menu = Cards.menu(a, input: input)
        let goal: String = a.setup.goal.isEmpty ? "" : "\nWHAT THE PLAYER CAME FOR: " + clip(a.setup.goal, 200)
        let prompt = context + goal + "\n\n" + Prompts.lookQuestion + "\nThe form:"
        let grammar = JSONGrammar.look(cast: cast, places: places, cards: menu, people: cast)
        let q0 = Date()
        let reply = (try? await llm.complete(system: nil, prompt: prompt,
                                             options: .init(maxTokens: 400, temperature: 0.2, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
        noteQ("turn", "What did the player do? (the look)", reply, since: q0)
        guard var m = JSONExtract.object(reply) ?? Optional(Self.salvageJSON(reply)), !m.isEmpty else { return nil }
        func s(_ k: String) -> String { (m[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var read = PlayerRead()
        // Whatever came back is matched to what exists; anything else is "nobody" or "staying".
        let to = s("to").lowercased()
        read.to = cast.first { $0.lowercased() == to } ?? cast.first { n in
            guard let first = n.lowercased().split(separator: " ").first.map(String.init), first.count >= 3 else { return false }
            return to.split(whereSeparator: { !$0.isLetter }).map(String.init).contains(first)
        } ?? ""
        // Words alone (no action part): spoken to who the player already faces. Nothing moves,
        // turns, or is picked up or put down; only the ACTION part can do that.
        if let p = partsThisTurn, p.did.isEmpty {
            if let now = Fovea.facing(a).first.flatMap({ w in cast.first { $0.caseInsensitiveCompare(w.name) == .orderedSame } }) { read.to = now }
            for k in ["going", "new_place", "spot", "takes", "puts_down", "body"] { m[k] = "" }
        }
        let also = s("also_to").lowercased()
        read.alsoTo = cast.first { $0.lowercased() == also && $0.lowercased() != to && $0 != read.to } ?? ""
        let going = s("going").lowercased()
        if going == "somewhere new" { read.going = "somewhere new" }
        else if let p = places.first(where: { $0.lowercased() == going }) { read.going = p }
        let named = s("new_place")
        if read.going == "somewhere new", named.count > 2, !Self.echoesPrompt(named) { read.newPlace = Self.ownPlace(named) }
        let takes = s("takes")
        func field(_ k: String) -> String {
            let v = s(k)
            return v.count > 2 && !Self.echoesPrompt(v) && !["nothing", "none", "empty", "n/a", "no change", "staying"].contains(v.lowercased()) ? v : ""
        }
        read.takes = field("takes")
        read.putsDown = field("puts_down")
        read.spot = field("spot")
        read.tells = field("tells")
        // "I introduce myself" with no name in it: a name the read came up with that the player
        // never said is no detail of theirs (the form once made everyone "Simon").
        if let r = read.tells.range(of: #"(?i)\bname is\s+([A-Za-z'-]+)"#, options: .regularExpression) {
            let name = read.tells[r].split(separator: " ").last.map(String.init) ?? ""
            if !name.isEmpty, input.range(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b", options: [.regularExpression, .caseInsensitive]) == nil {
                read.tells = ""
            }
        }
        read.body = field("body")
        read.feels = field("feels")
        read.goalStep = field("goal_step")
        for k in ["did", "avoids", "gets_up", "needs", "answer_size", "asks_back", "asks_room", "skips_hours", "weather"] {
            if let v = m[k] as? String { read.plan[k] = v }
        }
        let asked = ((m["look"] as? [Any]) ?? []).compactMap { $0 as? String }
        for raw in asked {
            if let l = Looks.parse(raw, cards: menu, people: cast), !read.looks.contains(l) { read.looks.append(l) }
        }
        return read
    }

    /// Read, question 2: the moment, planned from what was looked up.
    private func planPlayer(_ a: Adventure, input: String, context: String, looked: [Looks.Answer], into read: inout PlayerRead) async {
        var prompt = context
        let lines: [String] = looked.filter { !$0.lines.isEmpty }.map { "- " + $0.look.text + ": " + clip($0.text, 400) }
        prompt += "\n\nWHAT YOU LOOKED UP (from the app; an answer never contradicts it):\n" + (lines.isEmpty ? "- nothing" : lines.joined(separator: "\n"))
        let asked = Self.asks(input)
        prompt += "\n\n" + Prompts.planQuestion
        if asked { prompt += "\nTHE PLAYER ASKED SOMETHING: \"answer\" must not be empty. Give the real answer, plainly: a reason, a yes or no, a name, a number. It is what the person asked would say, about what the story already shows (what they are doing, what is around), true to the time and place." }
        prompt += "\nThe form:"
        let q0 = Date()
        let reply = (try? await llm.complete(system: nil, prompt: prompt,
                                             options: .init(maxTokens: 200, temperature: 0.2, repetitionPenalty: 1.1, grammar: JSONGrammar.plan(asked: asked)))) ?? ""
        noteQ("turn", "The plan", reply, since: q0)
        let m = JSONExtract.object(reply) ?? Self.salvageJSON(reply)
        func s(_ k: String) -> String { (m[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        read.answer = Self.echoesPrompt(s("answer")) || Self.outOfTime(s("answer"), a) ? "" : clip(s("answer"), 260)
        // The plan left a question unanswered (a model that ignores grammars, or an answer too
        // vague to use): one short question asks for the answer alone.
        if asked, read.answer.count < 6 || Self.vagueAnswer(read.answer) {
            let q: String = prompt.components(separatedBy: Prompts.planQuestion).first ?? context
            let ask: String = q + "\n\nQUESTION: The player asked: \"" + clip(input, 300) + "\". What plain, concrete answer does the person they asked give, in one short sentence? Never vague, never a riddle, never the player's own words. {\"answer\":\"one short sentence\"}\nThe form:"
            let q0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: ask,
                                               options: .init(maxTokens: 80, temperature: 0.2, repetitionPenalty: 1.1, grammar: JSONGrammar.text("answer", chars: 200)))) ?? ""
            noteQ("turn", "What is the answer?", raw, since: q0)
            let am = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
            let got: String = ((am["answer"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if got.count >= 6, !Self.echoesPrompt(got), !Self.vagueAnswer(got), !Self.outOfTime(got, a) { read.answer = clip(got, 260) }
        }
        read.beat = Self.echoesPrompt(s("beat")) ? "" : clip(s("beat"), 260)
        read.does = Self.echoesPrompt(s("does")) ? "" : clip(s("does"), 200)
        // The restated action must be the player's own words: one that adds what they didn't say
        // ("You tell her your name is Clara") is dropped, and the message itself is used.
        let castWords: String = a.cast.map { $0.name + " " + $0.role }.joined(separator: " ")
        let ownText: String = input + " you yourself ask asks tell tells say says " + castWords
        let own = Continuity.wordSet(ownText)
        // A name the player didn't say this turn is never put in their mouth.
        let myFirst: String = Cards.first(a.playerName).lowercased()
        let namesMe = myFirst.count > 1 && Continuity.wordSet(read.does).contains(myFirst) && !Continuity.wordSet(input).contains(myFirst)
        if !read.does.isEmpty, namesMe || !Continuity.grounded(read.does, in: own, share: 0.65) {
            read.dropped = "does not match the message: " + read.does
            read.does = ""
        }
        if read.beat.isEmpty, read.dropped.isEmpty { read.dropped = "empty" }
        // A beat lifted from the reply before would make the storyteller say it twice.
        if let last = a.transcript.dropLast().last(where: { $0.role == .gm }), read.beat.count > 20 {
            let b = PresenceFilter.key(read.beat)
            var lifted = false
            for sentence in PresenceFilter.sentences(last.text) {
                let k = PresenceFilter.key(sentence)
                if k == b || (k.count > 30 && (k.contains(b) || b.contains(k))) || Self.similar(sentence, read.beat) { lifted = true; break }
            }
            if lifted { read.beat = ""; read.dropped = "copied from the last reply" }
        }
    }

    /// Settles the scene in code from the reading, before the reply is written: who the player is
    /// with, who falls into the background, and who is left behind if the player goes. Returns the
    /// plan the storyteller follows, with the WHO line written from the settled scene.
    private func settle(_ a: inout Adventure, read given: PlayerRead, input: String) {
        var read = given
        let said = Continuity.wordSet(input)
        let knownPlaces: [String] = a.lore.filter { $0.kind == .place }.map(\.name) + a.places
        var backInside = false
        func bare(_ s: String) -> String {
            let l = s.lowercased().trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("the ") ? String(l.dropFirst(4)) : l
        }
        // A "new" place that is one already on the map, and that the message never names, is the
        // reading reaching for a name it doesn't have: the new place stays unnamed.
        if !read.newPlace.isEmpty, let k = knownPlaces.first(where: { bare($0) == bare(read.newPlace) }), !Continuity.names(place: k, in: input) {
            read.newPlace = ""
        }
        // Going back to a place on the map by its name ("I return to the Velvet Thorn") is a move
        // there, even when the reading missed it.
        if let k = knownPlaces.first(where: { $0.caseInsensitiveCompare(a.location) != .orderedSame && Self.goesTo($0, in: input) }) {
            read.going = k
        }
        // "Let's head back inside", "I go back in": back to the place the player came here from.
        let backIn = #"(?i)\b(back (inside|indoors|in there|in)|(go|goes|head|heads|step|steps|come|comes|walk|walks|get|gets) (back )?(inside|indoors))\b"#
        if read.going.isEmpty || read.going == "somewhere new", read.newPlace.isEmpty, !a.location.isEmpty,
           input.range(of: backIn, options: .regularExpression) != nil {
            let here = a.location
            let ties = a.links.filter { $0.from.caseInsensitiveCompare(here) == .orderedSame || $0.to.caseInsensitiveCompare(here) == .orderedSame }
            if let tie = ties.last {
                read.going = tie.from.caseInsensitiveCompare(here) == .orderedSame ? tie.to : tie.from
                backInside = true
            }
        }
        // "Back to the bar", "my old stool", "the speakeasy": a place on the map meant by a plain
        // word for it. The last place the message names is where the player ends up.
        if !a.location.isEmpty, let meant = Self.placeMeant(input, in: a) {
            var later = true
            if !read.going.isEmpty, read.going != "somewhere new",
               let word = read.going.lowercased().split(whereSeparator: { !$0.isLetter }).last,
               let at = input.lowercased().range(of: String(word), options: .backwards) {
                later = input.distance(from: input.startIndex, to: at.lowerBound) < meant.at
            }
            if later {
                read.going = meant.place
                read.newPlace = ""
                backInside = true
            }
        }
        // "Upstairs", "back up": the way the player came.
        // "Sit back down" is not a staircase: "back up" and "back down" count only after a moving word.
        let stairs = #"(?i)\b(upstairs|downstairs|up the stairs|down the stairs)\b|\b(go|goes|head|heads|climb|climbs|come|comes|walk|walks|run|runs|hurry|hurries|carry|carries|bring|brings|step|steps)\b(\s+\w+){0,3}?\s+back\s+(up|down)\b"#
        if read.going.isEmpty || read.going == "somewhere new", read.newPlace.isEmpty, !a.location.isEmpty,
           input.range(of: stairs, options: .regularExpression) != nil {
            let here = a.location
            let ties = a.links.filter { $0.from.caseInsensitiveCompare(here) == .orderedSame || $0.to.caseInsensitiveCompare(here) == .orderedSame }
            if ties.count == 1, let tie = ties.last {
                read.going = tie.from.caseInsensitiveCompare(here) == .orderedSame ? tie.to : tie.from
                backInside = true
            }
        }
        // "I go out to the street", "we walk to the corner": somewhere new, named by its plain word,
        // even when the reading said the player stays.
        if !newPlaceRefused, read.going.isEmpty || (read.going == "somewhere new" && read.newPlace.isEmpty), !a.location.isEmpty,
           let noun = Self.newPlaceWord(input, in: a) {
            read.going = "somewhere new"
            read.newPlace = "The " + noun
        }
        let me = a.playerName.lowercased().split(separator: " ").first.map(String.init) ?? ""
        // Whether the message names someone here (by first name or role).
        let namesSomeone = a.cast.contains { c in
            let f = Cards.first(c.name).lowercased()
            return said.contains(f) || Continuity.wordSet(c.role).contains(where: { $0.count > 3 && said.contains($0) })
        }
        // Someone the player asked along ("would you like company walking home?") is who "we" means.
        let asksAlong = #"(?i)\b(walk(ing)? (you |her |him )?home|come (with|along)|join me|with me|company|go outside|step outside|go for a walk|walk with)\b"#
        if !read.to.isEmpty, input.range(of: asksAlong, options: .regularExpression) != nil { invited = read.to }
        let weGo = input.range(of: #"(?i)\b(we|us|together)\b"#, options: .regularExpression) != nil
        if weGo, !namesSomeone, !invited.isEmpty, a.whereabouts.contains(where: { $0.name.caseInsensitiveCompare(invited) == .orderedSame && $0.here != false }) {
            read.to = invited
        }
        let everyone = input.range(of: #"(?i)\b(them|both|everyone|everybody|each of|all of (you|them)|you two|all three|the two of)\b"#, options: .regularExpression) != nil
        let addressed = read.to.lowercased().split(separator: " ").first.map(String.init) ?? ""
        // Leaving takes two things agreeing: the reading, and words that read like going somewhere
        // (or the player already being on the way).
        let named = !read.newPlace.isEmpty && read.newPlace.caseInsensitiveCompare(a.location) != .orderedSame
        let toKnown = read.going != "somewhere new" && knownPlaces.contains { $0.caseInsensitiveCompare(read.going) == .orderedSame }
            && (backInside || Self.goesTo(read.going, in: input))
        let leaving = !read.going.isEmpty && (Continuity.leavesPlace(input) || a.location.isEmpty || named || toKnown)
        // "Let's go", "she takes my arm", "with me": the person the player is with comes along.
        let together = input.range(of: #"(?i)\b(let'?s|we|us|together|with me|join me|come with|takes? (my|your|it|the) (arm|hand)|takes? it|arm in arm|follows? me|lead (her|him|them))\b"#, options: .regularExpression) != nil
        let from = a.location
        // Someone the player turns to who isn't placed yet is in the room with them.
        if !read.to.isEmpty, !a.whereabouts.contains(where: { $0.name.caseInsensitiveCompare(read.to) == .orderedSame }) {
            a.whereabouts.append(Whereabout(name: read.to, at: "with you", here: true, engaged: true))
        }
        for i in a.whereabouts.indices {
            let first = a.whereabouts[i].name.lowercased().split(separator: " ").first.map(String.init) ?? ""
            if first == me || first == "you" || first.isEmpty { continue }
            let named = first == addressed || said.contains(first)
            if leaving {
                // Only someone the player's own words bring along comes ("with Walter", "take the
                // bartender"); the person they were just talking to stays where they are.
                let role = Cards.card(for: a.whereabouts[i], in: a).map { Continuity.roleLabel($0.role).lowercased() } ?? ""
                let low = input.lowercased()
                let verbs: [String] = ["with ", "bring ", "take ", "follow ", "join "]
                var comes = false
                for r in [first, role] where r.count >= 3 && r != "the stranger" {
                    let andI: String = r + " and i"
                    let rComes: String = r + " comes"
                    var hit = low.contains(andI) || low.contains(rComes)
                    for v in verbs where !hit {
                        let phrase: String = v + r
                        if low.contains(phrase) { hit = true }
                    }
                    if hit { comes = true; break }
                }
                if !comes, together, a.whereabouts[i].here != false, first == addressed || said.contains(first) { comes = true }
                if comes {
                    a.whereabouts[i].here = true; a.whereabouts[i].engaged = true; a.whereabouts[i].leftAt = nil
                } else if a.whereabouts[i].here != false {
                    a.whereabouts[i].here = false; a.whereabouts[i].engaged = false; a.whereabouts[i].leftAt = from
                } else if let at = a.whereabouts[i].leftAt, !at.isEmpty, at.caseInsensitiveCompare(read.going) == .orderedSame {
                    a.whereabouts[i].here = true; a.whereabouts[i].leftAt = nil
                }
            } else if everyone, a.whereabouts[i].here != false {
                // "I ask them both": everyone in the room is part of it.
                a.whereabouts[i].engaged = true
            } else if !addressed.isEmpty {
                if named {
                    a.whereabouts[i].engaged = true
                    if a.whereabouts[i].here == nil { a.whereabouts[i].here = true }
                } else if a.whereabouts[i].here != false {
                    a.whereabouts[i].engaged = false
                }
            }
        }
        if leaving, read.going != "somewhere new" {
            a.visit(read.going, from: from)
            a.location = read.going
            a.things = a.placeThings[read.going.lowercased()] ?? []
        } else if leaving, !read.newPlace.isEmpty {
            // Somewhere new, named in the message: it gets its own card now, and is built before
            // the reply paints it.
            let loc = Self.placeName(read.newPlace, known: a.lore.filter { $0.kind == .place }.map(\.name) + a.places)
            a.visit(loc, from: from)
            a.location = loc
            a.things = a.placeThings[loc.lowercased()] ?? []
            if !a.lore.contains(where: { $0.kind == .place && $0.name.caseInsensitiveCompare(loc) == .orderedSame }) {
                _ = addLore(&a, LoreEntry(name: loc, kind: .place))
            }
        } else if leaving {
            // Somewhere not on the map yet: the old scene is cleared, and the update after the
            // reply names the new place and what is there.
            a.location = ""
            a.things = []
            a.scene = "On the way out of " + from + "."
        }
        lastRead = "to " + (read.to.isEmpty ? "nobody" : read.to) + "; " + (read.going.isEmpty ? "staying" : "going: " + read.going)
            + (!read.going.isEmpty && !leaving ? " (not acted on: the message does not read like leaving)" : "")
    }

    /// The moment the storyteller writes, from the settled scene and the plan: what the player
    /// does, the answer to their question, what happens next, and who is with them.
    private func momentText(_ a: Adventure, read: PlayerRead, input: String) -> String {
        let said = Continuity.wordSet(input)
        let me = a.playerName.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let leaving = !read.going.isEmpty && (Continuity.leavesPlace(input) || a.location.isEmpty || !read.newPlace.isEmpty)
        let others = a.whereabouts.filter { w in
            let first = w.name.lowercased().split(separator: " ").first.map(String.init) ?? ""
            return first != me && first != "you"
        }
        let with = others.filter { $0.here != false && $0.engaged == true }.map(\.name)
        let back = others.filter { $0.here != false && $0.engaged == false }.map(\.name)
        var who = with.isEmpty ? "You are with nobody in particular." : "You are with " + with.joined(separator: " and ") + "."
        if !back.isEmpty, !with.isEmpty { who += " " + back.joined(separator: " and ") + (back.count == 1 ? " stays" : " stay") + " in the background and does not join in." }
        if leaving {
            let dest: String = read.going == "somewhere new" ? (a.location.isEmpty ? "somewhere new" : "to " + a.location) : "to " + read.going
            who += " You are going " + dest + "; anyone not named stays behind, out of sight."
        }
        // An answer is only kept when the player asked something, and never when it is the player's
        // own words handed back (an order or a request written as "I'll have...").
        // A beat that opens on someone in the background would pull them into the conversation.
        var beat = read.beat
        if !with.isEmpty, let lead = beat.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init),
           back.contains(where: { $0.lowercased().split(separator: " ").first.map(String.init) == lead }), !said.contains(lead) {
            beat = ""
        }
        let why = !beat.isEmpty ? "" : read.dropped.isEmpty ? "it opened on someone in the background" : read.dropped
        if !why.isEmpty { lastRead += "; next beat not used (" + why + (read.beat.isEmpty ? "" : ": " + clip(read.beat, 120)) + ")" }
        let low = read.answer.lowercased()
        let own = ["i ", "i'll ", "i'd ", "i'm ", "yes, i", "my "].contains { low.hasPrefix($0) }
        let answer = Self.asks(input) && !own ? read.answer : ""
        var lines: [String] = ["PLAYER: " + clip(input.replacingOccurrences(of: "\n", with: " "), 300)]
        if !read.does.isEmpty { lines.append("THE PLAYER DOES: " + read.does) }
        if answer.isEmpty, Self.asks(input) {
            lines.append("ANSWER: nothing on file, so the person answers plainly with something ordinary that fits the place and the time (never a refusal or a riddle)")
        } else {
            lines.append("ANSWER: " + (answer.isEmpty ? "none" : answer))
        }
        let then = beat.isEmpty ? "the person the player is with responds right away to exactly what the player said and did" : beat
        lines.append("THEN: " + then)
        lines.append("WHO: " + who)
        return lines.joined(separator: "\n")
    }

    /// How long a new turn lets the filing of the last reply finish before it is dropped.
    static let fileGrace = 10.0

    /// One turn of the grounded engine. The world lives in the app (the cards in the World panel);
    /// the storyteller sees only what the player's action touches.
    /// 1. Read: one short call reads the message into fixed choices (who, where, what about).
    /// 2. Fetch: code settles the scene and picks the cards for this moment.
    /// 3. Paint: the reply, from short rules, a premise and those cards.
    /// 4. File: while the reply is read aloud, one small call notes what it added; code keeps the
    ///    place, who is where and the clock itself. The next turn never waits long for it.
    private func runTurn(input: String, hidden: Bool, forceFinal: Bool = false) async {
        guard var a = adventure else { return }
        partsThisTurn = hidden ? nil : pendingParts
        pendingParts = nil
        // The first turn the player plays: what is on file now is the core lore.
        if !hidden, a.coreFacts.isEmpty, !a.facts.isEmpty {
            a.coreFacts = a.facts
            adventure?.coreFacts = a.facts
        }
        let turnBegan = Date()
        // How long each step took, for the story export.
        var times: [String] = []
        var lapFrom = Date()
        func lap(_ label: String) {
            let now = Date()
            times.append(label + " " + String(format: "%.1fs", now.timeIntervalSince(lapFrom)))
            lapFrom = now
        }
        ComputerSounds.shared.startHum()
        if let job = memoryJob {
            stage = "Filing the last moment"
            let waiter = Task { await job.value }
            let grace = Self.fileGrace
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { await waiter.value }
                group.addTask { try? await Task.sleep(for: .seconds(grace)) }
                await group.next()
                group.cancelAll()
            }
            job.cancel()
            memoryJob = nil
            guard !Task.isCancelled else { return }
            a = adventure ?? a
            lap("waiting on the last rebuild")
        }
        let snapshot = a
        placeBeforeTurn = a.location
        lastRead = ""
        catchUpNotes = []
        // The opening place is built like any place the player arrives in, when the architect gave
        // it only a line.
        if hidden, a.transcript.isEmpty {
            // The premise's time of day is set before anything is painted, so the place and the
            // opening are written for it.
            let told = Self.premiseDayParts(a)
            if let lo = told.min(), let hi = told.max(), hi - lo <= 1 {
                if a.clock == nil || !told.contains(Continuity.part(of: a.clock!)) {
                    a.clock = Continuity.partStarts[hi]
                    a.storyTime = Continuity.storyTime(clock: Continuity.partStarts[hi], old: a.storyTime)
                }
            }
        }
        // The opening: the map is drawn first, straight from the story the player picked, and the
        // opening is then told from that map (the room, who is where, what is on the tables), so
        // the first words already match the grid. No separate description of the place is asked.
        if hidden, a.transcript.isEmpty, !a.location.isEmpty, !a.rooms.contains(where: { $0.name.caseInsensitiveCompare(a.location) == .orderedSame }) {
            stage = "Drawing " + a.location
            let premise = Cards.premise(a)
            var told: [String] = []
            if !premise.isEmpty { told.append("THE STORY: " + clip(premise, 600)) }
            let opens = [a.spot, a.scene].filter { !$0.isEmpty }.joined(separator: " ")
            if !opens.isEmpty { told.append("AS IT OPENS: " + clip(opens, 400)) }
            if !a.things.isEmpty { told.append("NAMED HERE: " + a.things.prefix(8).joined(separator: "; ")) }
            adventure = a
            await furnishRoom(story: told.joined(separator: "\n"))
            guard !Task.isCancelled else { return }
            if let drawn = adventure { a = drawn }
            // What each person wears, from their card, goes on them on the map.
            if var r = a.room, let i = a.rooms.firstIndex(where: { $0.id == r.id }) {
                for (j, t) in r.things.enumerated() where t.isPerson {
                    guard let c = a.lore.first(where: { $0.name == t.name }), !c.wears.isEmpty, !t.wearing.lowercased().contains(c.wears.lowercased().prefix(20)) else { continue }
                    r.things[j].wearing = t.wearing.isEmpty ? clip(c.wears, 110) : clip(c.wears, 110) + ", " + t.wearing
                }
                a.rooms[i] = r
                adventure = a
            }
            roomDrawnBeforeReply = a.room?.id
            lap("drawing the opening room")
        }
        let played = clockTick(&a, hidden: hidden, paused: Date().timeIntervalSince(turnBegan) + a.gmWait)
        let ticked = Date()
        // No time limit: the story runs until the player finishes it ("Finish the experience now").
        a.left = forceFinal ? 0 : nil
        // The story's time does not tick with the real minutes played: it moves only when the
        // player says so ("two hours later") or the story itself moves it on.
        _ = played
        if !hidden, let said = Continuity.statedTime(input, near: a.clock) {
            a.clock = said
            a.storyTime = Continuity.storyTime(clock: said, old: a.storyTime)
        } else if !hidden, let c = a.clock, let skip = Continuity.laterBy(input, clock: c) {
            // "15 hours later": the clock jumps by what the player says.
            a.clock = c + skip
            a.storyTime = Continuity.storyTime(clock: c + skip, old: a.storyTime)
            catchUpNotes.append("Time skipped: " + Self.span(skip) + ", now " + Continuity.clockText(c + skip))
        }
        // The last turn the player was in this place, for a catch-up when they come back.
        if !a.location.isEmpty {
            a.placeSeen[a.location.lowercased()] = a.playerTurns
            if let c = a.clock { a.placeClock[a.location.lowercased()] = c }
        }
        let opening = hidden && a.transcript.isEmpty
        var maxOut = opening ? 520 : 300
        let playerNarrates = !hidden && Self.narrates(input)
        let playerAsks = !hidden && !playerNarrates && Self.asks(input)
        // Foveated: no lookups and no plan; one yes/no pass over the cards picks what the reply sees.
        let fov = !hidden && !playerNarrates
        foveaUsed = fov
        foveaYes = []
        var foveaTold = ""
        namesThisTurn = []
        putDownThisTurn = []
        walkedThisTurn = false
        plannedThisTurn = [:]
        focusThisTurn = ""
        talkThisTurn = false
        alsoThisTurn = ""
        didThisTurn = ""
        stayingThisTurn = false
        placedByPlan = false
        var introduced = hidden ? false : learnPlayerName(&a, input: input)
        // "I walk over to introduce myself": the player gives the name the story already knows.
        // With no name known yet, the person they turn to still gives theirs.
        if !hidden, a.nameless,
           input.range(of: #"(?i)\bintroduc(e|es|ed|ing) (myself|me)\b"#, options: .regularExpression) != nil { introduced = true }

        // Picking something up is the player's own act: it is in their hands the moment they say
        // it, when the thing is in the scene (the last reply, the place, its props, the premise).
        var pickedNow: String? = nil
        let lastGMBefore: String = a.transcript.last(where: { $0.role == .gm })?.text ?? ""
        /// Puts a thing in the player's hands when it is really in the scene (the last reply, the
        /// premise, the place, its props or facts), and takes it off the place's props.
        func take(_ raw: String) -> Bool {
            let item = raw.lowercased().hasPrefix("the ") ? String(raw.dropFirst(4)) : raw
            let names: Set<String> = Set(a.cast.flatMap { Continuity.wordSet($0.name) }.filter { $0.count > 2 })
            guard item.count > 2, Continuity.wordSet(item).isDisjoint(with: names),
                  Continuity.wordSet(item).isDisjoint(with: Self.personWords),
                  !a.carrying.contains(where: { Self.similar($0, item) }) else { return false }
            let props = Cards.props(a)
            let scene: String = ([lastGMBefore, a.bible, Cards.premise(a), Cards.placeCard(a)?.desc ?? ""] + props + a.facts).joined(separator: " ")
            guard Continuity.grounded(item, in: Continuity.wordSet(scene)) else { return false }
            a.carrying = Array((a.carrying + [item]).suffix(8))
            pickedNow = item
            // In your hands now, so no longer lying about the place.
            let key = a.location.lowercased()
            if !a.location.isEmpty, var here = a.placeThings[key] {
                here.removeAll { Self.similar($0, item) }
                a.placeThings[key] = here
            }
            a.things.removeAll { Self.similar($0, item) }
            return true
        }
        /// The rest of the player's own act, filed the moment they send it (the rebuild revisits it
        /// after the reply): what they put down or give away, where they move in the room, what they
        /// tell about themselves, and their body. Each is kept only when the message itself says it.
        var actsNow: [String] = []
        func playerActs(_ r: PlayerRead) -> [String] {
            let before = actsNow.count
            let said = Continuity.wordSet(input)
            let pointsAt = input.range(of: #"(?i)\b(it|them|this|that|these|those|everything|all)\b"#, options: .regularExpression) != nil
            if !r.putsDown.isEmpty, Continuity.grounded(r.putsDown, in: said, share: 0.5) || pointsAt,
               let held = a.carrying.first(where: { Self.similar($0, r.putsDown) || Continuity.grounded($0, in: Continuity.wordSet(r.putsDown), share: 0.5) }) {
                a.carrying.removeAll { $0 == held }
                putDownThisTurn.append(held)
                let given = input.range(of: #"(?i)\b(give|gives|hand|hands|pass|passes|offer|offers|pay|pays|slide|slides|toss|tosses)\b"#, options: .regularExpression) != nil
                if given, !r.to.isEmpty {
                    actsNow.append("Gone from your hands → " + held + " (to " + r.to + ")")
                } else {
                    let key = a.location.lowercased()
                    if !a.location.isEmpty { a.placeThings[key] = Array(((a.placeThings[key] ?? a.things) + [held]).suffix(30)) }
                    a.things = Array((a.things + [held]).suffix(30))
                    actsNow.append("You put down → " + held)
                }
            }
            // Any move the look hears keeps the room question after the reply, which places you on the map.
            if !r.spot.isEmpty { walkedThisTurn = true }
            if !r.spot.isEmpty, Continuity.grounded(r.spot, in: said, share: 0.5), a.spot.caseInsensitiveCompare(r.spot) != .orderedSame {
                a.spot = clip(r.spot, 90)
                actsNow.append("You are now → " + r.spot)
            }
            // Asking someone something tells them nothing about you ("you are asking what she wears").
            let onlyAsking = r.tells.range(of: #"(?i)\b(ask|asks|asking|asked|wonder|wondering|want to know|wants to know|curious)\b"#, options: .regularExpression) != nil
            if !r.tells.isEmpty, !onlyAsking, Continuity.grounded(r.tells, in: said, share: 0.6) {
                let heard: [String] = r.to.isEmpty
                    ? a.whereabouts.filter { $0.here != false && $0.engaged == true }.map(\.name)
                    : [r.to]
                for name in heard {
                    guard let c = a.cast.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                    let key = c.name.lowercased()
                    var known: [String] = a.knows[key] ?? []
                    guard !known.contains(where: { Self.similar($0, r.tells) }) else { continue }
                    known.append(clip(r.tells, 110))
                    a.knows[key] = Self.keepKnown(known)
                    actsNow.append(c.name + " now knows → " + r.tells)
                }
            }
            // Seated on the map: "standing" from the look doesn't stand you up unless you said so.
            let seatedNow = a.room?.player?.on != nil
            let saysStand = input.range(of: #"(?i)\b(stand|stood|get up|got up|rise|rose|on my feet)\b"#, options: .regularExpression) != nil
            let standsWrongly = seatedNow && !saysStand && r.body.lowercased().contains("stand")
            if !r.body.isEmpty, !standsWrongly, Continuity.grounded(r.body, in: said, share: 0.5), a.body.caseInsensitiveCompare(r.body) != .orderedSame {
                a.body = clip(r.body, 70)
                actsNow.append("You are → " + r.body)
            }
            if !r.feels.isEmpty, Continuity.grounded(r.feels, in: said, share: 0.5), a.feels.caseInsensitiveCompare(r.feels) != .orderedSame {
                a.feels = clip(r.feels, 70)
                actsNow.append("You feel → " + r.feels)
            }
            if !r.goalStep.isEmpty, !a.setup.goal.isEmpty, Continuity.grounded(r.goalStep, in: said, share: 0.5),
               !a.progress.contains(where: { Self.similar($0, r.goalStep) }) {
                a.progress = Array((a.progress + [clip(r.goalStep, 130)]).suffix(8))
                actsNow.append("Toward the goal → " + r.goalStep)
            }
            guard actsNow.count > before else { return [] }
            adventure?.carrying = a.carrying
            adventure?.things = a.things
            adventure?.placeThings = a.placeThings
            adventure?.spot = a.spot
            adventure?.knows = a.knows
            adventure?.body = a.body
            adventure?.feels = a.feels
            adventure?.progress = a.progress
            return Array(actsNow[before...])
        }
        if !hidden, !playerNarrates {
            // "I pick up every single barstool", or "I take it" after the watch is set in front of you.
            if let named = Self.pickedUp(input) { _ = take(named) }
            else if let it = Self.pickedUpIt(input, lastReply: lastGMBefore, props: Cards.props(a)) { _ = take(it) }
        }
        if !hidden { a.transcript.append(StoryTurn(role: .player, text: input)) }
        pendingInput = nil
        adventure = a
        streaming = ""
        thinkingSince = Date()
        // The turn guide moves to the new turn the moment the player speaks, and shows each step
        // worked out before the reply as it is settled.
        var pre: [String] = []
        func step(_ line: String) {
            trace("CODE", line)
            pre.append(line)
            Self.updateFrame(&a, looked: [], asked: [], notes: catchUpNotes, steps: [], pre: pre)
            adventure?.frames = a.frames
        }
        if let pickedNow { step("You pick up → " + pickedNow + " (in your hands now)") }
        if hidden { traceBlock("OPENING", "(no player words: the app asks for the opening scene)") } else { traceBlock("YOU SAID", input) }
        if !hidden { step("You said → " + clip(input.replacingOccurrences(of: "\n", with: " "), 140)) }

        // 1. Look. One short call: who the player turns to, where they go, and what to look up.
        var read: PlayerRead? = nil
        let context = readContext(a, input: input)
        if !hidden, !playerNarrates {
            stage = "Who are you talking to?"
            lapFrom = Date()
            read = await lookPlayer(a, input: input, context: context)
            guard !Task.isCancelled else { adventure = snapshot; return }
            lap("look")
            // A skip the player narrates in any words ("12 hours pass and the fog clears"): the
            // look form gives the hours and the new weather, and the clock and the sky move before
            // any room is drawn or the reply is written.
            if let c = a.clock, Continuity.laterBy(input, clock: c) == nil, Continuity.statedTime(input, near: c) == nil,
               let hours = Int(read?.plan["skips_hours"] ?? ""), hours > 0, hours <= 72 {
                a.clock = c + hours * 60
                a.storyTime = Continuity.storyTime(clock: c + hours * 60, old: a.storyTime)
                adventure?.clock = a.clock
                adventure?.storyTime = a.storyTime
                step("Time skipped → " + Self.span(hours * 60) + ", now " + Continuity.clockText(c + hours * 60))
            }
            if let sky = read?.plan["weather"]?.trimmingCharacters(in: CharacterSet(charactersIn: " .\n")), sky.count > 3, !Self.echoesPrompt(sky),
               !["none", "empty", "no change", "same", "unchanged"].contains(sky.lowercased()),
               Continuity.grounded(sky, in: Continuity.wordSet(input), share: 0.5), var r = a.room {
                r.outside = clip(sky, 100)
                a.room = r
                adventure?.room = r
                step("The weather now → " + sky)
            }
            // What the read says the player takes, in any words ("I scoop up the stools", "I'll hang on
            // to it"), when the words above missed it. The player's message must name it or point at it.
            if pickedNow == nil, let takes = read?.takes, !takes.isEmpty {
                let pointsAt = input.range(of: #"(?i)\b(it|them|this|that|these|those|everything|all)\b"#, options: .regularExpression) != nil
                if Continuity.grounded(takes, in: Continuity.wordSet(input), share: 0.5) || pointsAt, take(takes), let got = pickedNow {
                    adventure?.carrying = a.carrying
                    adventure?.things = a.things
                    adventure?.placeThings = a.placeThings
                    step("You pick up → " + got + " (in your hands now, from the read)")
                }
            }
            if let r = read { for l in playerActs(r) { step(l) } }
            if read != nil, let meant = Self.addressedByDeed(a, input: input), read!.to.caseInsensitiveCompare(meant) != .orderedSame {
                read!.to = meant
                step("Who do you mean? → " + meant + " (the one the story just showed doing that)")
            }
        }

        // 2. Settle and look up. Code settles who the player is with and where, then answers each
        // lookup from the store (and adds a few of its own: the person the player turns to, a card
        // the message names).
        var moment = ""
        var extra: [String] = []
        if let pickedNow { extra.append("THE PLAYER PICKS UP THE " + pickedNow.uppercased() + " and is holding it now: show them doing it in this reply.") }
        var looked: [Looks.Answer] = []
        if !hidden, !playerNarrates {
            let wasWith: [String] = a.whereabouts.filter { $0.here != false && $0.engaged == true }.map(\.name)
            // The words alone suggest a new place ("I walk over to the costume sewer" read as a
            // place called The costume) while the look heard the player stay: the model is asked
            // plainly whether they leave this place before anything is built.
            newPlaceRefused = false
            if let r = read, r.going.isEmpty, r.newPlace.isEmpty, !a.location.isEmpty, let noun = Self.newPlaceWord(input, in: a) {
                let q = "THE PLAYER IS IN: " + a.location + "\nTHE PLAYER SAYS: " + clip(input, 300)
                    + "\nQUESTION: Does the player leave " + a.location + " now for another place (\"the " + noun + "\")? Walking over to someone or something here, or turning to them, is no.\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:"
                let q0 = Date()
                let raw = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 24, temperature: 0.1, repetitionPenalty: 1.0,
                                                                                         grammar: JSONGrammar.one("answer", from: ["yes", "no"])))) ?? ""
                noteQ("turn", "Do you leave for another place?", raw, since: q0)
                guard !Task.isCancelled else { adventure = snapshot; return }
                if ((JSONExtract.object(raw)?["answer"] as? String) ?? "").lowercased().hasPrefix("n") {
                    newPlaceRefused = true
                    step("Do you leave for another place? → no: \"the " + noun + "\" is here")
                }
            }
            settle(&a, read: read ?? PlayerRead(), input: input)
            if read == nil { lastRead = "no usable reading; " + lastRead }
            // Turning away from the person you're talking to is something people announce ("hey
            // Dolores", turning to her). When the reading moved the talk to someone else, the model
            // is asked plainly whether the player did that; if not, the talk stays where it was.
            let movedTo: [String] = a.whereabouts.filter { $0.here != false && $0.engaged == true }.map(\.name)
            if !wasWith.isEmpty, !movedTo.isEmpty, Set(movedTo.map { $0.lowercased() }).isDisjoint(with: wasWith.map { $0.lowercased() }) {
                let q = "THE PLAYER WAS TALKING TO: " + wasWith.joined(separator: ", ") + "\nTHE PLAYER NOW SAYS: " + clip(input, 300)
                    + "\nQUESTION: How sure are you, from 0 to 100, that the player turns away to " + movedTo.joined(separator: ", ") + " instead: naming them, calling to them or turning toward them? A 'her' or 'him' about someone else, or a speech slip, is not turning; people announce it when they turn. {\"sure\":\"0 to 100\"}\nThe form:"
                let q0 = Date()
                let raw = (try? await llm.complete(system: nil, prompt: context + "\n\n" + q,
                                                   options: .init(maxTokens: 40, temperature: 0.1, repetitionPenalty: 1.1,
                                                                  grammar: JSONGrammar.one("sure", from: stride(from: 0, through: 100, by: 5).map(String.init))))) ?? ""
                noteQ("turn", "Did you turn to someone else?", raw, since: q0)
                guard !Task.isCancelled else { adventure = snapshot; return }
                let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
                // Only a clear turn moves the talk: a coin toss (50/50) keeps you with who you were with.
                let sure = Int((m["sure"] as? String) ?? "") ?? 0
                if sure < 70 {
                    for i in a.whereabouts.indices where a.whereabouts[i].here != false {
                        a.whereabouts[i].engaged = wasWith.contains { $0.caseInsensitiveCompare(a.whereabouts[i].name) == .orderedSame }
                    }
                    step("Did you turn to someone else? → \(sure)/100, not clear: still " + wasWith.joined(separator: ", "))
                } else {
                    step("Did you turn to someone else? → \(sure)/100: now " + movedTo.joined(separator: ", "))
                }
            }
            let facingNow: [String] = a.whereabouts.filter { $0.here != false && $0.engaged == true }.map(\.name)
            step("Who are you talking to? → " + (facingNow.isEmpty ? "nobody in particular" : facingNow.joined(separator: ", ")))
            let movedNow = a.location.caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
            step("Are you going anywhere? → " + (movedNow ? (a.location.isEmpty ? "somewhere new" : a.location) : "staying"))
            // Arriving somewhere with no description yet: the place is built before the reply, so
            // the reply can bring it to life.
            let arrived = !a.location.isEmpty && a.location.caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
            // Arriving somewhere with no map yet: the room is drawn first (you watch it go up), from
            // what the player said and the place itself, and the reply is then told from that map.
            if arrived, !a.rooms.contains(where: { $0.name.caseInsensitiveCompare(a.location) == .orderedSame }) {
                stage = "Drawing " + a.location
                lapFrom = Date()
                adventure = a
                await furnishRoom(story: "THE PLAYER: " + clip(input, 300) + "\nTHE PLAYER GOES TO: " + a.location)
                guard !Task.isCancelled else { adventure = snapshot; return }
                if let drawn = adventure { a = drawn }
                if let r = a.room, r.name.caseInsensitiveCompare(a.location) == .orderedSame {
                    roomDrawnBeforeReply = r.id
                    step("What is this place like? → drawn: " + r.objects.prefix(6).map { Zone.short($0.name) }.joined(separator: ", "))
                }
                lap("drawing " + a.location)
            }
            // Back in a place after a good while away: one short question catches it up.
            let back = !a.location.isEmpty && a.location.caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
            // "A good while" is five turns, or an hour of the story's own time.
            let seenClock: Int? = a.placeClock[a.location.lowercased()]
            var awayMinutes = 0
            if let c = a.clock, let then = seenClock { awayMinutes = max(0, c - then) }
            if back, let seen = a.placeSeen[a.location.lowercased()], a.playerTurns - seen >= Self.catchUpTurns || awayMinutes >= 60 {
                let gap = a.playerTurns - seen
                stage = "Catching up on " + a.location
                lapFrom = Date()
                let changes = await catchUp(&a, turns: gap, minutes: awayMinutes, then: seenClock)
                guard !Task.isCancelled else { adventure = snapshot; return }
                lap("catching up")
                if !changes.isEmpty {
                    extra.append("SINCE YOU WERE LAST HERE: " + changes.joined(separator: " "))
                    catchUpNotes += changes.map { "While you were away: " + $0 }
                    lastRead += "; caught up on " + a.location + " after \(gap) turns away"
                    step("What changed while you were away? → " + changes.joined(separator: " "))
                }
            }
        }
        if !hidden {
            let asked = read?.looks ?? []
            // In the foveated story the person you face already has their whole card, so code only
            // adds the lookups the model didn't ask for that aren't that card.
            let looks = asked + Looks.auto(a, input: input, to: read?.to ?? "", asked: asked).filter { !(fov && $0.kind == .lookAt && $0.target.caseInsensitiveCompare(read?.to ?? "") == .orderedSame) }
            if looks.contains(where: { $0.kind == .otherQuestion }) { trace("FLAGGED", "no lookup covers this question: " + input) }
            stage = looks.isEmpty ? "Gathering the world" : "Looking things up"
            lapFrom = Date()
            for l in looks {
                var ans = Looks.answer(l, in: a)
                if l.kind == .remember {
                    // Everything older than the last exchange the reply already sees: "Who is Sarah?"
                    // finds the reply two turns back that first named her.
                    let recent = Set(a.transcript.suffix(2).map(\.id))
                    let older = a.transcript.enumerated().filter { !recent.contains($0.element.id) }.map { ($0.offset + 1, $0.element) }
                    let found = await Recall.memories(for: a, input: l.target, olderTurns: older, chaptersInPrompt: 0, budget: 700, earlier: earlierStories(a))
                    guard !Task.isCancelled else { adventure = snapshot; return }
                    // Items nobody has brought up are not recalled.
                    let shut = Cards.locked(a, spoken: a.transcript.map(\.text).joined(separator: " "))
                    let kept = found.filter { m in !shut.contains { m.lowercased().hasPrefix($0) } }.prefix(2).map { clip($0, 200) }
                    ans.lines = Array(kept) + ans.lines
                    if ans.lines.isEmpty { ans.lines = ["Nothing earlier on that."] }
                }
                looked.append(ans)
                step(l.text.prefix(1).uppercased() + String(l.text.dropFirst()) + "? → " + clip(ans.text.isEmpty ? "nothing" : ans.text, 160))
            }
            if !looks.isEmpty { lap("lookups") }
        }
        // Is the player bringing someone new in? Asked every turn (a word list missed "Into the
        // shop walks a police inspector"); the newcomer gets a card before the reply, so nobody
        // else is swapped in.
        if !hidden, !playerNarrates {
            stage = "Is someone new coming in?"
            lapFrom = Date()
            let q0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: context + "\n\n" + Prompts.newcomer + "\nThe form:",
                                               options: .init(maxTokens: 70, temperature: 0.2, repetitionPenalty: 1.1,
                                                              grammar: JSONGrammar.yesNo("new", then: "name", 30, and: "role", 60)))) ?? ""
            noteQ("turn", "Is someone new coming in?", raw, since: q0)
            guard !Task.isCancelled else { adventure = snapshot; return }
            lap("someone new")
            let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
            var came: String? = nil
            let recent: String = a.transcript.suffix(6).map(\.text).joined(separator: " ")
            if (m["new"] as? String) == "yes" {
                let role = (m["role"] as? String) ?? ""
                came = addNewcomer(&a, name: (m["name"] as? String) ?? "", role: role, about: input + " " + recent, engaged: true)
                // A name the message never gave ("Inspector Valmont" for "a police inspector") is
                // refused: they come in under what they are, "The police inspector".
                if came == nil, let byRole = Self.roleName(role) {
                    came = addNewcomer(&a, name: byRole, role: role, about: input + " " + recent, engaged: true)
                }
            }
            // The player said plainly that someone came in: they get a card even when the
            // question missed it.
            if came == nil, let d = Self.describedArrival(input) {
                came = addNewcomer(&a, name: d.name, role: d.role, about: input + " " + recent, engaged: true)
            }
            if let came {
                let others: String = a.cast.filter { $0.name != came }.map(\.name).joined(separator: " or ")
                extra.append("A NEW PERSON COMES IN: " + came + ". They are their own person" + (others.isEmpty ? "" : ", not " + others)
                             + ": show them arriving, and let them speak for themselves.")
                lastRead += "; new person: " + came
                step("Is someone new coming in? → " + came)
            } else {
                step("Is someone new coming in? → no")
            }
        }
        // Could the player do that? Asked only when the action leans on a thing they must have.
        let needs = #"(?i)\b(pull out|take out|draw my|unlock|shoot|fire my|light (a|my|the)|use my|with my|from my (pocket|bag|coat))\b"#
        if !hidden, !playerNarrates, input.range(of: needs, options: .regularExpression) != nil {
            stage = "Could you do that?"
            lapFrom = Date()
            let have: String = a.carrying.isEmpty ? "nothing in particular" : a.carrying.joined(separator: "; ")
            let props: String = Cards.props(a).prefix(8).joined(separator: "; ")
            let q: String = context + "\n\nTHE PLAYER HAS: " + have + "\nAROUND THEM: " + (props.isEmpty ? "nothing notable" : props) + "\n\n" + Prompts.canDo + "\nThe form:"
            let q0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: q,
                                               options: .init(maxTokens: 50, temperature: 0.2, repetitionPenalty: 1.1, grammar: JSONGrammar.yesNo("can", then: "missing", chars: 60)))) ?? ""
            noteQ("turn", "Could you do that?", raw, since: q0)
            guard !Task.isCancelled else { adventure = snapshot; return }
            lap("could you do that")
            let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
            let can: String = (m["can"] as? String) ?? "yes"
            let missing: String = ((m["missing"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
            if can == "no", missing.count > 2, !Self.echoesPrompt(missing) {
                extra.append("THE PLAYER CANNOT DO THAT AS SAID: they have no " + missing + ". Show it not working, plainly and kindly; nothing appears from nowhere.")
                step("Could you do that? → no, missing: " + missing)
            } else {
                step("Could you do that? → yes")
            }
        }
        // Read, question 2: the moment, planned from what was looked up.
        if read != nil, !fov {
            stage = "What happens next?"
            lapFrom = Date()
            await planPlayer(a, input: input, context: context, looked: looked, into: &read!)
            guard !Task.isCancelled else { adventure = snapshot; return }
            lap("plan")
            if let r = read {
                if !r.answer.isEmpty { step("What's the answer? → " + r.answer) }
                if !r.beat.isEmpty { step("What happens next? → " + r.beat) }
            }
        }
        if fov {
            foveaTold = revealName(&a, input: input, to: read?.to ?? "", introduced: introduced)
            adventure = a
        } else if !hidden, !playerNarrates {
            moment = momentText(a, read: read ?? PlayerRead(), input: input)
            let told = revealName(&a, input: input, to: read?.to ?? "", introduced: introduced)
            if !told.isEmpty { moment = Self.withAnswer(moment, told) }
            else if Self.answerNamesHidden(moment, a) {
                moment = moment.components(separatedBy: "\n").map { $0.hasPrefix("ANSWER:") ? "ANSWER: none" : $0 }.joined(separator: "\n")
            }
            // What the player did goes on the timeline, in code, at the story time it happened.
            if let does = read?.does, !does.isEmpty {
                let when = a.clock.map { Continuity.clockText($0) } ?? ""
                a.timeline.append(clip((when.isEmpty ? "" : when + ": ") + does, 200))
                if a.timeline.count > 24 { a.timeline = Array(a.timeline.prefix(2) + a.timeline.suffix(22)) }
            }
            adventure = a
        } else if playerNarrates {
            let told = revealName(&a, input: input, to: "", introduced: introduced)
            if !told.isEmpty { extra.append("NAME: " + told + " Say it in this reply.") }
            adventure = a
        }
        stage = "Gathering the world"
        // Arriving somewhere paints the whole place: its card and what is in it.
        let arrivedNow = !hidden && !a.location.isEmpty && a.location.caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
        let around = arrivedNow || looked.contains { $0.look.kind == .around }
        let pick = Cards.pick(a, input: hidden ? "" : input, opening: opening, around: around, asking: playerAsks)
        // What the briefing shows from the lookups: everything but what the scene already holds
        // (the place card, the full card of whoever the player is facing, the things around).
        let facing = a.whereabouts.filter { $0.here != false && $0.engaged == true }.map(\.name)
        let lookedLines: [String] = looked.compactMap { ans in
            if ans.lines.isEmpty || ans.look.kind == .around { return nil }
            if ans.look.kind == .whereAmI, !a.location.isEmpty, ans.lines.count < 2 { return nil }
            if ans.look.kind == .lookAt, facing.contains(where: { $0.caseInsensitiveCompare(ans.look.target) == .orderedSame }) { return nil }
            if ans.look.kind == .lookAt, a.location.caseInsensitiveCompare(ans.look.target) == .orderedSame { return nil }
            let label: String = ans.look.text.prefix(1).uppercased() + String(ans.look.text.dropFirst())
            let said: String = clip(ans.text, 420)
            return label + ": " + said
        }
        extra += a.fixes.filter { $0.hasPrefix(Self.checked) }.suffix(2).map { "CORRECTION: " + String($0.dropFirst(Self.checked.count)) }
        if !a.playerName.isEmpty, !nameTold(a), !a.nameless {
            let knew = a.cast.filter(\.known).map(\.name)
            extra.append("Nobody here knows the player's name (\(a.playerName)) because the player has not said it"
                         + (knew.isEmpty ? "" : ", except " + knew.joined(separator: ", ") + ", who already knew them") + ". No one else says it.")
        }

        // 3. Paint.
        // Moving, by the read (or, with no read, by the words alone).
        let going = read.map { !$0.going.isEmpty } ?? Continuity.moves(input)
        var notes = groundedNotes(a, input: input, going: going, opening: opening, playerNarrates: playerNarrates, playerAsks: playerAsks)
        if arrivedNow {
            notes.insert("THE PLAYER ARRIVES AT " + a.location.uppercased() + ": bring it to life from the place card and what is around, with sound, smell, light and texture, before anything else happens.", at: 0)
        }
        // Someone whose name the story hasn't said gives none, and never a made-up one.
        if a.nameless {
            for w in a.whereabouts where w.here != false && w.engaged == true {
                guard let c = Cards.card(for: w, in: a), !c.known, !c.byPlayer, !c.role.isEmpty else { continue }
                if namesThisTurn.contains(c.name) { continue }
                let role: String = Continuity.roleLabel(c.role)
                let who: String = role.prefix(1).uppercased() + String(role.dropFirst())
                extra.append(who + " has not said a name yet: they give none in this reply, and never a made-up one.")
            }
        }
        var system = groundedSystem(a)
        let card = Cards.briefing(a, pick: pick, looked: lookedLines, extra: extra, notes: notes, moment: moment)
        // The yes/no pass's question and answer, for "Copy with prompts".
        var gateLog = ""
        // What the yes/no pass let in and left out, for the story export.
        var foveaView: [String] = []
        // The room as the grid holds it, in plain words (the opening and other briefings get it too).
        var roomSent: [String] = Fovea.roomView(a)
        let roomBlock: String = roomSent.isEmpty ? "" : "\n" + roomSent.joined(separator: "\n") + "\nKeep to this layout: who stands where, and what is between you."
        var lead = "[GAME MASTER BRIEFING: private, for this reply only]\n" + card + roomBlock + "\n[END OF BRIEFING]\n\n" + (hidden ? "INSTRUCTION: " : "THE PLAYER: ") + input
        if fov {
            // Every card item, marked yes or no for this moment; only the yeses reach the storyteller.
            stage = "What matters right now?"
            lapFrom = Date()
            let items: [Fovea.Item] = Fovea.items(a, input: input, asking: playerAsks)
            // Talking to one person, staying where you are: no pass over the cards at all. The reply
            // gets only the two of you, the date, the city and the weather, and more room to answer.
            // A "spot" the look hears only counts as a move when it is somewhere else on the map
            // ("at the bar" while already on a stool at the bar is not a move).
            var spotSaid = read?.spot ?? ""
            // "beside her at the workbench": her is the person you're turning to.
            if let to = read?.to, !to.isEmpty, spotSaid.range(of: #"(?i)\b(her|him|them)\b"#, options: .regularExpression) != nil {
                spotSaid = spotSaid.replacingOccurrences(of: #"(?i)\b(her|him|them)\b"#, with: Cards.first(to), options: .regularExpression)
            }
            // The look often misses a walk across the room ("I walk over to the bartender" read as
            // sitting at the bar). When it heard none, the person the player turns to is out of
            // reach and the words move, the model is asked that one thing plainly.
            var walkConfirmed = false
            let movingWords = #"(?i)\b(walk|walks|go|goes|step|steps|move|moves|head|heads|cross|crosses|come|comes|wander|wanders|join|joins|approach|approaches|stroll|strolls|over to|up to)\b"#
            if spotSaid.isEmpty, !arrivedNow, (read?.newPlace ?? "").isEmpty, let to = read?.to, !to.isEmpty,
               let r = a.room, let me = r.player, let them = r.named(to), them.isPerson, RoomGrid.distance(me, them) > 1.6,
               input.range(of: movingWords, options: .regularExpression) != nil {
                let role = a.cast.first { $0.name.caseInsensitiveCompare(to) == .orderedSame }?.role ?? ""
                let who = to + (role.isEmpty ? "" : " (" + role + ")")
                let q = "THE PLAYER SAID: " + clip(input, 300) + "\nQUESTION: Does the player walk over to " + who
                    + " now, so they end up beside them? Talking or calling across the room without moving is no.\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:"
                let q0 = Date()
                let raw = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 24, temperature: 0.1, repetitionPenalty: 1.0,
                                                                                         grammar: JSONGrammar.one("answer", from: ["yes", "no"])))) ?? ""
                noteQ("turn", "Did you walk over to them?", raw, since: q0)
                guard !Task.isCancelled else { adventure = snapshot; return }
                if ((JSONExtract.object(raw)?["answer"] as? String) ?? "").lowercased().hasPrefix("y") {
                    spotSaid = "beside " + Cards.first(to)
                    walkConfirmed = true
                    walkedThisTurn = true
                }
            }
            var moves = !spotSaid.isEmpty
            var whereTo = ""
            if moves, let r = a.room, let me = r.player, let z = Adventure.zone(from: spotSaid, in: r) {
                let c = Placer.centroid(Placer.cells(z, in: r, forPeople: true))
                moves = hypot(c.0 - me.centre.x, c.1 - me.centre.y) > 1.6
                whereTo = z.text
            }
            let going = read?.going ?? ""
            // The map would walk you across the room ("in her chair beside you" read as somewhere
            // 3 m away): the model says whether you really got up and went, from your own words.
            if moves, !walkConfirmed, !arrivedNow, (read?.newPlace ?? "").isEmpty {
                let q0 = Date()
                let mq = "THE LAST REPLY: " + Fovea.clip(lastGMBefore, 500) + "\nTHE PLAYER SAID: " + input
                    + "\nQUESTION: Did the player get up or walk somewhere else in the room just now" + (whereTo.isEmpty ? "" : " (to " + whereTo + ")")
                    + ", in their own words? Asking to join someone or to sit beside them counts as yes (they will be welcome). Asking a question, talking, sitting back or turning to someone is no.\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:"
                let mraw = (try? await llm.complete(system: nil, prompt: mq, options: .init(maxTokens: 24, temperature: 0.1, repetitionPenalty: 1.0,
                                                                                         grammar: JSONGrammar.one("answer", from: ["yes", "no"])))) ?? ""
                noteQ("turn", "Did you walk somewhere just now?", mraw, since: q0)
                guard !Task.isCancelled else { adventure = snapshot; return }
                let mm: [String: Any] = JSONExtract.object(mraw) ?? Self.salvageJSON(mraw)
                if ((mm["answer"] as? String) ?? "").lowercased().hasPrefix("n") { moves = false; spotSaid = "" }
            }
            let talk = !arrivedNow && !(read?.to ?? "").isEmpty && (going.isEmpty || going == "staying")
                && (read?.newPlace ?? "").isEmpty && !moves
            talkThisTurn = talk
            if talk { maxOut = 420 }
            // Arriving somewhere new asks for a lot (the time, the place, the weather, who is there):
            // 300 tokens cut the river scene off mid-sentence.
            if arrivedNow { maxOut = max(maxOut, 460) }
            var keep: [Bool] = []
            if !items.isEmpty, !talk {
                var intent = Fovea.PlayerIntent()
                if let r = read {
                    intent.to = r.to; intent.going = r.going; intent.newPlace = r.newPlace
                    intent.takes = r.takes; intent.putsDown = r.putsDown; intent.tells = r.tells
                }
                let ask: String = Fovea.gatePrompt(a, input: input, intent: Fovea.intent(intent), lastReply: lastGMBefore, items: items)
                let q0 = Date()
                let raw = (try? await llm.complete(system: nil, prompt: ask,
                                                   options: .init(maxTokens: 12 + items.count * 9, temperature: 0.1, repetitionPenalty: 1.0,
                                                                  grammar: JSONGrammar.gate(count: items.count)))) ?? ""
                noteQ("turn", "Which cards does the reply need? (yes/no pass)", raw, since: q0)
                guard !Task.isCancelled else { adventure = snapshot; return }
                let m: [String: Any] = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
                keep = Fovea.chosen(items, answer: m, input: input)
                gateLog = ask + " " + raw
                lap("what matters")
            }
            var kept: [Fovea.Item] = []
            for (i, item) in items.enumerated() where i < keep.count && keep[i] { kept.append(item) }
            if talk {
                // Talking to one person: their whole card goes along, picked by code (how they feel
                // about you, what they want, what has passed between you, their facts), and nothing else.
                let first = Cards.first(read?.to ?? "").lowercased()
                if first.count > 1 {
                    // (The goal line is a log of earlier steps, "You ask Elias for his name": it is
                    // left out of a talk, where it read as what to answer now.)
                    kept = items.filter { !$0.text.hasPrefix("Toward what you came for") && $0.text.lowercased().range(of: "\\b" + NSRegularExpression.escapedPattern(for: first) + "\\b", options: .regularExpression) != nil }
                }
            }
            // A second person in focus: someone the player names in their own words ("tell me about
            // Walter", "what does the bartender dream of?") brings their card along too.
            let said = input.lowercased()
            for c in a.lore where c.kind == .person && !c.isPlayer && !c.byPlayer && c.name.caseInsensitiveCompare(read?.to ?? "") != .orderedSame {
                let first = Cards.first(c.name).lowercased()
                let role = c.role.lowercased().replacingOccurrences(of: #"^(the|a|an)\s+"#, with: "", options: .regularExpression)
                func named(_ w: String) -> Bool { w.count > 2 && said.range(of: "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b", options: .regularExpression) != nil }
                let invited = !(read?.alsoTo ?? "").isEmpty && c.name.caseInsensitiveCompare(read?.alsoTo ?? "") == .orderedSame
                guard invited || named(first) || named(role) else { continue }
                for item in items where !kept.contains(where: { $0.text == item.text })
                    && item.text.lowercased().range(of: "\\b" + NSRegularExpression.escapedPattern(for: first) + "\\b", options: .regularExpression) != nil {
                    kept.append(item)
                }
            }
            foveaYes = Set(kept.map(\.kind))
            foveaView = []
            // Marked by what was actually sent (the yes/no answers plus what code added for the
            // person you're talking to), so the + and - match the prompt below.
            for item in items {
                let mark: String = kept.contains(where: { $0.text == item.text }) ? "  + " : "  - "
                foveaView.append(mark + Fovea.clip(item.text, 90))
            }
            // The notes that only apply now (the final reply, the player moving, phrases that keep
            // coming back) still go with the moment.
            var events: [String] = extra + notes
            if !foveaTold.isEmpty { events.insert(foveaTold + " Say it in this reply.", at: 0) }
            // The moment is planned on the map first: you walk over if you said so, and the person
            // you face stays or gets up, with what is in their reach.
            stage = "Planning the moment"
            stayingThisTurn = (read?.going ?? "") == "staying" && (read?.newPlace ?? "").isEmpty
            answerSizeThisTurn = ""
            let needSaid = (read?.plan["needs"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased()
            physicalThisTurn = !talk || !(read?.takes ?? "").isEmpty || !(read?.putsDown ?? "").isEmpty || !(read?.spot ?? "").isEmpty
                || (read?.plan["gets_up"] ?? "") == "yes" || !["", "empty", "none", "nothing", "n/a", "no"].contains(needSaid)
            let plan = await planMoment(&a, input: input, walk: spotSaid, to: read?.to ?? "", body: read?.body ?? "", pre: read?.plan ?? [:])
            guard !Task.isCancelled else { adventure = snapshot; return }
            adventure?.room = a.room
            adventure?.spot = a.spot
            if !plan.log.isEmpty { step("Plan → " + plan.log); lastRead += "; plan: " + plan.log }
            lap("plan")
            events.insert(contentsOf: plan.brief, at: 0)
            // The room gets on with its own small business while you talk: three ordinary things
            // the people here do, decided once for the room, one coming up every third turn as a
            // passing touch.
            if let room = a.room, room.name.caseInsensitiveCompare(a.location) == .orderedSame {
                let key = a.location.lowercased() + " ~steps"
                let folk = room.people.filter { $0.kind == .person }.map(\.name)
                if a.ambience[key] == nil, !folk.isEmpty {
                    stage = "What goes on here"
                    let things = room.objects.filter { $0.icon != "rug" }.map { Fovea.bare($0.name) }.prefix(8).joined(separator: ", ")
                    let q = "THE STORY: " + clip(a.bible, 400) + "\nWHEN: " + Fovea.whenWhere(a) + "\nTHE ROOM: " + a.location + " (" + things + ")"
                        + "\nTHE PEOPLE HERE: " + folk.joined(separator: ", ")
                        + "\nQUESTION: Name three small, ordinary things the people here get on with over the next while, in order, using only what is in THE ROOM (stirring the pot, setting out bowls, trimming a lamp). Each one sentence starting with a person's name, at most 12 words. Never the player.\nOutput ONLY one JSON object:\n{\"steps\":[\"three sentences\"]}\nThe form:"
                    let q0 = Date()
                    let raw = (try? await llm.complete(system: nil, prompt: q, options: .init(maxTokens: 120, temperature: 0.6, repetitionPenalty: 1.1,
                                                                                         grammar: JSONGrammar.strings("steps", max: 3, chars: 90)))) ?? ""
                    noteQ("plan", "What goes on here?", raw, since: q0)
                    guard !Task.isCancelled else { adventure = snapshot; return }
                    let steps = (((JSONExtract.object(raw) ?? Self.salvageJSON(raw))["steps"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { $0.count > 8 && !Self.echoesPrompt($0) }
                    a.ambience[key] = steps.joined(separator: " | ")
                    adventure?.ambience = a.ambience
                }
                let steps = (a.ambience[key] ?? "").components(separatedBy: " | ").filter { !$0.isEmpty }
                let turn = a.playerTurns
                if !steps.isEmpty, turn >= 3, turn % 3 == 0 {
                    events.append("Meanwhile in the room (one passing touch, then back to the talk): " + steps[(turn / 3 - 1) % steps.count])
                }
            }
            system = Fovea.system(a, nameless: a.nameless, playerNamed: !a.nameless || nameTold(a), age: PlayerDetails.saved.age, talk: talk)
            // A question about the room or who is in it ("Who else is here?"), on any turn: a
            // second pass, straight from the map, puts everyone and everything in view into the
            // moment, so the reply names the real people and never invents more.
            let roomKinds: Set<Looks.Kind> = [.whoIsHere, .around, .whereIs, .lookAt]
            // "Who is Sarah?" is about something said, not about the room.
            // Only when the look form says outright that the player asks about the room: a lookup
            // alone ("who is here", added to almost any question) used to flood a story about a
            // storm with the kitchen's props.
            let roomAsked = playerAsks && (read?.plan["asks_room"] ?? "") == "yes" && (read?.looks ?? []).contains(where: { roomKinds.contains($0.kind) })
                && !looked.contains(where: { $0.look.kind == .remember })
            // Every other lookup the model asked for (the time, what someone holds, their
            // backstory, what has passed between you): code's answer, from the store.
            let lookedLines: [String] = looked.filter { l in
                !(roomAsked && [.whoIsHere, .around].contains(l.look.kind)) && !l.text.isEmpty
            }.map { $0.look.text + ": " + clip($0.text, 260) }
            if !lookedLines.isEmpty { events.append("LOOKED UP for this moment (from the store, always true): " + lookedLines.joined(separator: " | ")) }
            if roomAsked {
                let view = Fovea.roomView(a).filter { !$0.hasPrefix("THE ROOM:") }
                if !view.isEmpty { events.append("THE PLAYER ASKED ABOUT THE ROOM. Everyone and everything here, from the map (always true), and nobody else: " + view.joined(separator: " ")) }
            }
            let alsoTo = (read?.alsoTo ?? "").caseInsensitiveCompare(read?.to ?? "") == .orderedSame ? "" : (read?.alsoTo ?? "")
            alsoThisTurn = alsoTo
            if !alsoTo.isEmpty, !(read?.to ?? "").isEmpty {
                events.append("The player speaks to both " + Cards.first(read?.to ?? "") + " and " + Cards.first(alsoTo) + ": both are in this moment. Each may answer, move or do what was asked (sit down, serve, join the player), in their own words and in turn.")
            }
            if talk {
                events.append("Answer what the player said, directly, as the person's own spoken words in quotation marks, with real specifics (a place, a name). As long as the PLAN says: a few words, a sentence or two, or a short story. No scenery.")
                let y = Fovea.year(a)
                events.append((y.isEmpty ? "" : "It is " + y + ": what they mention (tools, prices, news) belongs to that year. ") + "Ages, dates and how long: say them loosely, the way people do ('getting on for sixty', 'since she was small', 'a good many years'), never as exact figures or sums.")
            }
            if !didThisTurn.isEmpty { events.append("WHAT THE PLAYER DID, read plainly (their words may be a speech slip): " + didThisTurn) }
            lead = Fovea.lead(a, input: input, arrived: arrivedNow, events: events, kept: kept, talkTo: talk ? (read?.to ?? "") : nil,
                              to: read?.to ?? "", also: alsoTo, reach: physicalThisTurn, parts: partsThisTurn)
            roomSent = lead.components(separatedBy: "\n").filter { $0.hasPrefix("THE ROOM") || $0.hasPrefix("WHERE YOU ARE") || $0.contains(" Now: ") }
            let shown: String = talk ? "only you and " + (read?.to ?? "them") + (alsoTo.isEmpty ? "" : " and " + alsoTo) + ", the date, the city and the weather" : kept.isEmpty ? "only the room and who you face" : kept.map { Fovea.clip($0.text, 50) }.joined(separator: "; ")
            step("What matters right now? → " + shown + " (\(items.count - kept.count) of \(items.count) left out)")
            lastRead += "; foveated: \(kept.count) of \(items.count) card items in"
        } else if opening {
            // The opening gets the same short prompt as every turn: the room from the map, who is
            // where, who you are, and a few lines on how to open. No long rulebook.
            let items: [Fovea.Item] = Fovea.items(a, input: "", asking: false)
            // Everyone is introduced in the opening, even someone behind you: the "out of sight,
            // never described" line is for later turns.
            let kept: [Fovea.Item] = Array(items.filter { ["you", "other", "person", "have", "around"].contains($0.kind) && !$0.text.contains("out of sight") }.prefix(10))
            foveaView = items.map { it in (kept.contains(where: { $0.text == it.text }) ? "  + " : "  - ") + Fovea.clip(it.text, 90) }
            system = Fovea.system(a, nameless: a.nameless, playerNamed: !a.nameless || nameTold(a), age: PlayerDetails.saved.age)
            lead = Fovea.lead(a, input: input, arrived: true, events: extra + notes, kept: kept, instruction: true)
            roomSent = lead.components(separatedBy: "\n").filter { $0.hasPrefix("THE ROOM") || $0.hasPrefix("WHERE YOU ARE") || $0.contains(" Now: ") }
        }
        // The story's own last turns keep its voice and thread: as many of the last four as fit.
        // Anything older is reached with a "remember" lookup.
        let budget = LLMService.contextBudget - maxOut - Self.safetyTokens
        var used = Self.tokens(system) + Self.tokens(lead)
        var kept: [StoryTurn] = []
        let past = hidden ? a.transcript : Array(a.transcript.dropLast())
        // Talking to one person: only the last exchange goes along (what they said, and what you said).
        for t in past.suffix(talkThisTurn ? 2 : 4).reversed() {
            var t = t
            if t.text.count > 1400 { t.text = "…" + String(t.text.suffix(1400)) }
            let cost = Self.tokens(t.text) + 8
            if !kept.isEmpty, used + cost > budget { break }
            kept.insert(t, at: 0)
            used += cost
        }
        var history = kept.map { ChatTurn(role: $0.role == .player ? .user : .assistant, text: $0.text) }
        if history.first?.role == .assistant { history.insert(ChatTurn(role: .user, text: "(The story begins.)"), at: 0) }
        history.append(ChatTurn(role: .user, text: lead))
        if a.nameless {
            let told = nameTold(a)
            system = Continuity.unnamed(system, in: a, playerTold: told)
            history = history.map { ChatTurn(role: $0.role, text: Continuity.unnamed($0.text, in: a, playerTold: told)) }
            // "the bartender (the bartender)" once the name is hidden: the role is said once.
            func once(_ t: String) -> String {
                t.replacingOccurrences(of: #"(?i)\b(the [a-z' -]{2,40}?) \(\1\)"#, with: "$1", options: .regularExpression)
            }
            system = once(system)
            history = history.map { ChatTurn(role: $0.role, text: once($0.text)) }
        }
        // Exactly what the storyteller was sent, for "Copy with prompts".
        var sent: [String] = ["SYSTEM:\n" + system]
        for t in history { sent.append((t.role == .user ? "USER" : "ASSISTANT") + ":\n" + t.text) }
        if !gateLog.isEmpty { sent.insert("YES/NO PASS (asked before the reply):\n" + gateLog, at: 0) }
        let sentPrompt: String = sent.joined(separator: "\n\n")
        stage = "The storyteller is writing"
        a.gmWait = Date().timeIntervalSince(ticked)
        lapFrom = Date()
        var firstWord = true
        if narrate { narrator.begin() }
        var reply = ""
        var interrupted = false
        var presence: PresenceFilter? = nil
        var redrawn = false
        if !opening, !hidden {
            let f = PresenceFilter(absent: absentPeople(a, input: input, plan: moment),
                                   earlier: a.transcript.filter { $0.role == .gm }.suffix(3).map(\.text), player: input)
            if !f.idle { presence = f }
        }
        do {
            for try await piece in llm.stream(system: system, history: history, options: .init(maxTokens: maxOut, temperature: 0.85)) {
                if firstWord {
                    firstWord = false
                    lap("first word of the reply")
                }
                if stage != "" {
                    stage = ""; thinkingSince = nil; forge?.close()
                    if !narrate { ComputerSounds.shared.stopHum() }
                }
                if presence != nil {
                    let ok = presence!.feed(piece)
                    reply = presence!.accepted
                    streaming = presence!.preview
                    if narrate, !ok.isEmpty { narrator.feed(ok) }
                } else {
                    reply += piece
                    streaming = reply
                    if narrate { narrator.feed(piece) }
                }
            }
            if presence != nil {
                let ok = presence!.finish(restore: false)
                reply = presence!.accepted
                streaming = reply
                if narrate, !ok.isEmpty { narrator.feed(ok) }
            }
        } catch LLMError.interrupted {
            interrupted = true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        // Every sentence was a copy of an earlier reply, so nothing new was told: the reply is
        // written once more, hotter and with a firmer push away from words already used. Nothing
        // was shown or spoken yet, so the player only notices the wait.
        if !interrupted, !Task.isCancelled, let first = presence, first.echoes > 0, Self.tidy(reply).isEmpty {
            redrawn = true
            var f = PresenceFilter(absent: absentPeople(a, input: input, plan: moment),
                                   earlier: a.transcript.filter { $0.role == .gm }.suffix(3).map(\.text), player: input)
            do {
                for try await piece in llm.stream(system: system, history: history,
                                                  options: .init(maxTokens: maxOut, temperature: 1.1, repetitionPenalty: 1.3)) {
                    let ok = f.feed(piece)
                    reply = f.accepted
                    streaming = f.preview
                    if narrate, !ok.isEmpty { narrator.feed(ok) }
                }
                let ok = f.finish(restore: false)
                reply = f.accepted
                streaming = reply
                if narrate, !ok.isEmpty { narrator.feed(ok) }
            } catch LLMError.interrupted {
                interrupted = true
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            presence = f
        }
        if interrupted {
            narrator.stop()
            ComputerSounds.shared.stopHum()
            stage = ""
            thinkingSince = nil
            streaming = ""
            adventure = snapshot
            interruptedTurn = (input, hidden, forceFinal)
            return
        }
        if narrate { narrator.finish() }
        if !narrate || !narrator.speaking { ComputerSounds.shared.stopHum() }
        stage = ""
        thinkingSince = nil
        reply = Self.tidy(reply)
        reply = Self.endAtSentence(reply)
        if !nameTold(a), !a.cast.contains(where: \.known) { reply = Self.dropName(a.playerName, from: reply) }
        reply = Self.dropNameFromNarration(a.playerName, from: reply)
        guard !reply.isEmpty, !Task.isCancelled else {
            streaming = ""
            adventure = snapshot
            return
        }
        if let now = adventure, now.id == a.id { a.takeMemory(from: now) }
        if opening { checkPronouns(&a, texts: [a.bible, reply]) }
        // A name the storyteller made up for the person the player is with is put right in code.
        var nameFix = ""
        if !hidden, !opening {
            let namey = Continuity.asksName(input) != nil || introduced
            if let fixed = Self.fixMadeUpName(&a, reply: reply, namey: namey, playerSaid: input) {
                reply = fixed.reply
                nameFix = fixed.note
                namesThisTurn.append(fixed.name)
            }
        }
        settleClock(&a, reply: reply, opening: opening)
        if !opening {
            a.fixes.removeAll { $0.hasPrefix(Self.checked) }
            a.fixes += continuitySlips(a, reply: reply).map { Self.checked + $0 }
            for p in presence?.caught ?? [] {
                a.fixes.append(Self.checked + "\(p.name) is not with the player: \(p.name) is \(Continuity.placed(p.at)) and stays out of the scene until the story shows them arriving.")
            }
        }
        a.scene = Cards.sceneLine(a)

        lap(redrawn ? "rest of the reply (written twice)" : "rest of the reply")
        // Behind the scenes, for the story export: short, and every step shown.
        var before: [String] = []
        if !nameFix.isEmpty { before.append("NAME CHECK: " + nameFix) }
        if !hidden {
            if read == nil, !playerNarrates {
                before.append("READ: nothing usable came back; code settled the scene alone")
            } else if let r = read {
                let to: String = r.to.isEmpty ? "nobody" : r.to
                let motion: String = r.going.isEmpty ? "staying" : "going: " + r.going
                let asked: String = r.looks.isEmpty ? "nothing" : r.looks.map(\.text).joined(separator: ", ")
                var l = "LOOK: to \(to) · \(motion) · asked to look up: \(asked)"
                for (k, v) in [("takes", r.takes), ("puts down", r.putsDown), ("moves to", r.spot), ("tells", r.tells), ("body", r.body), ("feels", r.feels), ("toward the goal", r.goalStep)] where !v.isEmpty { l += " · " + k + ": " + v }
                if !r.does.isEmpty { l += "\nPLAN:\n  does: " + r.does }
                if !r.answer.isEmpty { l += "\n  answer: " + r.answer }
                if !r.beat.isEmpty { l += "\n  next: " + r.beat }
                before.append(l)
            } else {
                before.append("READ: skipped (the player is narrating; their words are canon)")
            }
            if !lastRead.isEmpty { before.append("SETTLED IN CODE: " + lastRead) }
            if let pickedNow { before.append("IN YOUR HANDS NOW: " + pickedNow) }
            if !actsNow.isEmpty { before.append("FILED AS YOU SENT IT:\n" + actsNow.map { "  - " + $0 }.joined(separator: "\n")) }
        }
        if !looked.isEmpty {
            let lines: [String] = looked.map { ans in
                let who: String = ans.look.byCode ? " (added by code)" : ""
                return "  - " + ans.look.text + who + " → " + clip(ans.text.isEmpty ? "nothing" : ans.text, 160)
            }
            before.append("LOOKED UP:\n" + lines.joined(separator: "\n"))
        }
        if fov || opening {
            before.append("WHAT MATTERS (+ in, - left out):\n" + (foveaView.isEmpty ? "  (no card items)" : foveaView.joined(separator: "\n")))
        } else {
            let inView: [String] = pick.why.map { "  - " + $0 }
            before.append("IN VIEW:\n" + inView.joined(separator: "\n"))
        }
        if !roomSent.isEmpty { before.append("THE ROOM AS TOLD (from the map):\n" + roomSent.map { "  " + $0 }.joined(separator: "\n")) }
        let noteLines: [String] = extra.map { clip($0, 90) } + notes.map { clip($0, 90) }
        if !noteLines.isEmpty { before.append("NOTES: " + noteLines.joined(separator: " | ")) }
        let turnTokens = kept.reduce(0) { $0 + Self.tokens($1.text) + 8 }
        let systemTokens: Int = Self.tokens(system)
        let leadTokens: Int = Self.tokens(lead)
        let total: Int = systemTokens + leadTokens + turnTokens
        before.append("PROMPT: about \(total) of \(LLMService.contextBudget) tokens (rules and premise \(systemTokens), scene and cards \(leadTokens), last \(kept.count) turns \(turnTokens)); \(maxOut) kept for the reply")
        if let f = presence, !f.dropped.isEmpty {
            var why: [String] = f.caught.map { "\($0.name) is \(Continuity.placed($0.at)), not with the player" }
            if f.echoes > 0 { why.append("\(f.echoes) sentence\(f.echoes == 1 ? "" : "s") copied from earlier replies") }
            if f.spokeForPlayer > 0 { why.append("the reply put words in the player's mouth") }
            let cut = clip(f.dropped.joined().trimmingCharacters(in: .whitespacesAndNewlines), 300)
            before.append("REPLY CHECK: " + (redrawn ? "too little was left, so the reply was written again. Left out first: " + cut
                                                : why.joined(separator: "; ") + ". Left out: " + cut))
        }
        let took = String(format: "%.1fs", Date().timeIntervalSince(turnBegan))
        before.append("TIMES: " + times.joined(separator: " · ") + " · total " + took + " before the rebuild")
        if Self.tracing {
            for b in before { trace("TURN NOTE", b) }
            var sys = traceSystem
            trace("SENT TO STORYTELLER", "\n" + Self.compactPrompt(sentPrompt, lastSystem: &sys))
            traceSystem = sys
            traceBlock("STORY SAID", reply)
        }
        a.transcript.append(StoryTurn(role: .gm, text: reply, before: before.joined(separator: "\n"), prompt: sentPrompt))
        // What the person you faced said aloud goes on their card, word for word (read off the
        // reply's quotes; only the person the moment was planned for speaks in it).
        if !hidden, !focusThisTurn.isEmpty,
           let k = a.lore.firstIndex(where: { $0.kind == .person && !$0.isPlayer && Cards.first($0.name).caseInsensitiveCompare(Cards.first(focusThisTurn)) == .orderedSame }),
           let re = try? NSRegularExpression(pattern: #"["“]([^"“”]{3,500})["”]"#) {
            let ns = reply as NSString
            let lines = re.matches(in: reply, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
            if !lines.isEmpty {
                a.lore[k].said.append("turn \(a.playerTurns): " + lines.joined(separator: " … "))
                if a.lore[k].said.count > 60 { a.lore[k].said.removeFirst(a.lore[k].said.count - 60) }
            }
        }
        streaming = ""
        if a.left == 0 && !hidden { a.ended = true }
        adventure = a
        undoSnapshot = hidden ? nil : snapshot
        library.save(a)
        refreshVocabulary()

        // The turn guide's snapshot of what was in view and looked up; the rebuild fills in the rest.
        let lookedNotes: [String] = looked.map { $0.look.text + ($0.look.byCode ? " (code)" : "") + " → " + clip($0.text.isEmpty ? "nothing" : $0.text, 140) }
        recordFrame(looked: lookedNotes)

        // 4. Rebuild, while the reply is read aloud: short questions, each saved as it comes back,
        // and dropped if the player is quicker.
        let exchange = "THE PLAYER: " + input + "\n\nTHE STORY: " + reply
        memoryJob = Task {
            await self.waitForVoice()
            // Housekeeping in code only (names the story has said, chapters), then the questions.
            if !hidden { await self.remember(exchange) }
            await self.rebuild()
        }
        if !a.ended && (!narrate || !narrator.speaking) {
            busy = false
            listenIfReady()
        }
    }

    /// The storyteller's standing rules for the grounded engine: short rules, the premise, the
    /// feeling, and the player's own limits. No bible, no notes, no lists: the cards come per turn.
    private func groundedSystem(_ a: Adventure) -> String {
        var s = Prompts.groundedRules
        if a.nameless { s += "\n- " + Prompts.namelessRule }
        if !a.playerName.isEmpty, !a.nameless || nameTold(a) {
            s += "\n- The player character is \(a.playerName), and that is \"you\". The name appears only in other characters' dialogue."
        }
        s += "\n\n" + Prompts.feelingRules(a.setup.feeling)
        let age = PlayerDetails.saved.age
        if age > 0 { s += "\n\n" + Prompts.ageRules(age) }
        var limits: [String] = []
        if !a.setup.avoid.isEmpty { limits.append("The player asked: " + a.setup.avoid) }
        if a.setup.simulator { limits.append("This is an experience with no threat, danger, villain or mystery.") }
        if !limits.isEmpty { s += "\n\n## SET-UP LIMITS (never break them)\n" + limits.map { "- " + $0 }.joined(separator: "\n") }
        s += "\n\n" + Prompts.hardLimits
        let premise = Cards.premise(a)
        if !premise.isEmpty { s += "\n\n## THE STORY\n" + premise }
        let pinned = a.lore.filter { $0.byPlayer && !$0.isPlayer }
        if !pinned.isEmpty {
            s += "\n\n## FACTS THE PLAYER SET (always true)\n" + pinned.prefix(6).map { "- \($0.name): " + clip($0.desc, 200) }.joined(separator: "\n")
        }
        return s
    }

    /// A first-person wish ("I take a stool at the bar") turned to the second person ("you take a
    /// stool at the bar"), word by word.
    static func asYou(_ text: String) -> String {
        var t = text
        for (from, to) in [(#"\bI am\b"#, "you are"), (#"\bI'm\b"#, "you're"), (#"\bI was\b"#, "you were"), (#"\bI've\b"#, "you've"),
                           (#"\bI'll\b"#, "you'll"), (#"\bI'd\b"#, "you'd"), (#"\bI\b"#, "you"), (#"\b[Mm]yself\b"#, "yourself"),
                           (#"\b[Mm]ine\b"#, "yours"), (#"\b[Mm]y\b"#, "your"), (#"\b[Mm]e\b"#, "you")] {
            t = t.replacingOccurrences(of: from, with: to, options: .regularExpression)
        }
        return t
    }

    /// How the opening ends: on the person the player is with, by their role, speaking to them
    /// (a vague "someone turns toward you" loses who the player is talking to).
    static func openingEnd(_ a: Adventure) -> String {
        let me = Cards.first(a.playerName).lowercased()
        let w = a.whereabouts.first { $0.here != false && $0.engaged == true && Cards.first($0.name).lowercased() != me && Cards.first($0.name).lowercased() != "you" }
        guard let w else { return "End on a sound or a small change in the room that invites the player to act." }
        let c = Cards.card(for: w, in: a)
        let role: String = c.map { Continuity.roleLabel($0.role) } ?? ""
        let who: String = role.isEmpty || (c?.known ?? false) ? w.name : role
        return "End with " + who + " speaking to the player: one short line of dialogue that leaves room to answer. Name them as " + who + ", never \"someone\"."
    }

    /// At most a few notes for this reply, only where they apply: the opening, a question, the
    /// player moving, narrating, the end of the session, and phrases that keep coming back.
    private func groundedNotes(_ a: Adventure, input: String, going: Bool, opening: Bool, playerNarrates: Bool, playerAsks: Bool) -> [String] {
        if opening {
            let me = a.lore.first(where: \.isPlayer)?.desc ?? ""
            var lines: [String] = []
            if !a.scene.isEmpty { lines.append("WHERE YOU ARE AS IT OPENS: " + clip(a.scene, 280)) }
            // The premise is the player's own wish, often written as "I": told back to them as "you",
            // so the storyteller never takes the "I" for its own voice (it spoke as the bartender).
            let premise = Self.asYou(Cards.premise(a))
            if !premise.isEmpty { lines.insert("THE STORY (the player's wish, told to them as \"you\"): " + clip(premise, 260), at: 0) }
            return lines + [
                "Paint the place: what you see, hear, smell and feel. People only from the outside; their hopes and past stay unsaid. You are the storyteller, never one of the people: they speak only in quotes.",
                me.isEmpty ? "Make clear who the player is." : "The player: " + clip(me, 120),
                Self.openingEnd(a),
            ]
        }
        var notes: [String] = []
        if playerNarrates {
            notes.append("THE PLAYER IS NARRATING: their passage is canon. Do not retell it; continue where it ends, in their voice. Keep it short.")
        } else if going {
            notes.append("THE PLAYER IS MOVING: show them going where they said and what they find when they arrive. Nobody left behind comes along.")
        }
        if playerAsks { notes.append("THE PLAYER ASKED A QUESTION: answer it in the opening lines, plainly and concretely.") }
        if a.left == 0 {
            let feeling = a.setup.feeling.isEmpty ? "the feeling the player came for" : a.setup.feeling
            notes.append("THIS IS THE FINAL REPLY: bring it to a storybook ending that lands \(feeling), right where the player is and with whoever is there, using only what is already in the story. Do not ask what they do next.")
        } else if a.left == 1 {
            notes.append("One reply left after this: start bringing it home.")
        } else if (a.left ?? 99) <= 3 && secsLeft(a, live: false) < Double(a.minutes) * 60 * 0.4 {
            notes.append("The session is nearly over: no new threads.")
        }
        let repeats = repeatedPhrases(a)
        if !repeats.isEmpty { notes.append("Avoid these phrases from recent replies: " + repeats.joined(separator: ", ")) }
        return notes
    }

    /// Rebuild: after a reply, while it is read aloud, short questions about the moment, one at a
    /// time and each with a locked answer: where the player is, who is with them, what each of
    /// them is doing, what the player has, what is around and what lasting facts came out. Every
    /// answer is checked against the story's own words and saved the moment it comes back, so the
    /// turn guide fills in live and a quick player only loses the questions not yet asked. They
    /// all start with the same moment, so llama.cpp reads it once.
    private func rebuild() async {
        guard !Task.isCancelled, let start = adventure, let last = start.transcript.last, last.role == .gm else { return }
        let lastID = last.id
        let reply = last.text
        let playerSaid = start.transcript.dropLast().last.flatMap { $0.role == .player ? $0.text : nil } ?? ""
        let me = Cards.first(start.playerName).lowercased()
        var filed: [String] = []
        var refused: [String] = []
        var asked: [String] = []
        var times: [String] = []
        // What each question changed, beside it, for the World panel's live feed.
        var stepChanges: [[String]] = []
        var filedSeen = 0
        let began = Date()
        // Notes the turn already made (a catch-up on a place) stay with the snapshot.
        let open: WorldFrame? = start.frames.last.flatMap { $0.turn == start.playerTurns ? $0 : nil }
        var notes: [String] = open?.notes ?? []
        defer { rebuildStep = "" }
        // After a foveated turn, questions about things that were out of view are skipped.
        let lean = foveaUsed
        var drawnNow = false
        let wanted = foveaYes
        let plannedNow = plannedThisTurn
        // Foveated: after a turn spent with one person, only the space between you and them is
        // looked at again. Everyone else stays as they were (no questions spent on them).
        let focus = lean ? focusThisTurn : ""
        func inFocus(_ name: String) -> Bool {
            focus.isEmpty || Cards.first(name).lowercased() == Cards.first(focus).lowercased() || plannedNow[name] != nil
        }

        func roleOf(_ c: LoreEntry) -> String { c.role.isEmpty ? "" : " (the story may call them \"" + Continuity.roleLabel(c.role) + "\")" }
        var base = Prompts.rebuildIntro
        base += "\n\nPLACE BEFORE: " + (start.location.isEmpty ? "(not named yet: the player just went somewhere new)" : start.location)
        let peopleLines: [String] = start.cast.map { $0.name + roleOf($0) }
        base += "\nPEOPLE IN THE STORY: " + (peopleLines.isEmpty ? "(none)" : peopleLines.joined(separator: "; "))
        if !playerSaid.isEmpty { base += "\n\nTHE PLAYER: " + clip(playerSaid, 500) }
        base += "\n\nTHE STORY: " + clip(reply, 1400) + "\n\nQUESTION: "

        // A quiet turn (talking with one person, staying put) is booked from one state-diff call,
        // made below: each question it covers is answered from that object, the ones it doesn't
        // cover keep their old answer, and only a proposed fact still gets its own check.
        var diff: [String: Any]? = nil
        func ask(_ label: String, _ question: String, _ grammar: String, _ tokens: Int) async -> [String: Any]? {
            guard !Task.isCancelled else { return nil }
            // No longer asked after a turn: what is "still hanging", whether the player "got an
            // answer", and what someone "wants" now. A small model guessed at them and the guesses
            // stuck to the cards ("She said she would keep the books", a want that changed with
            // every story told). A person's wants are set once, when they are made.
            if ["What's still hanging?", "Did you get an answer?"].contains(label) || label.hasSuffix("want, and what did they learn?") {
                return [:]
            }
            if let d = diff, label != "Does it last?", label != "Did anyone give their name?", !label.hasPrefix("What object is ") {
                switch label {
                case "How long did that take?", "Everyone now?", "What do you have?", "What's still hanging?", "Did you get an answer?", "Anything lasting?":
                    return (d[label] as? [String: Any]) ?? [:]
                default:
                    times.append(label + " skipped (state diff)")
                    return [:]
                }
            }
            // The room was drawn from this very reply a moment ago: what is in it and where you
            // are were just decided, so they are not asked again.
            if drawnNow, ["What is around?", "Where are you in the room?"].contains(label) {
                times.append(label + " skipped (room just drawn)")
                return [:]
            }
            // Once this place's room is drawn, the map says what is in it: the story's passing
            // words ("a sunlight smile", "warm glow behind you") don't become props.
            if label == "What is around?", let a = adventure, let r = a.room, r.name.caseInsensitiveCompare(a.location) == .orderedSame {
                times.append(label + " skipped (the room is drawn)")
                return [:]
            }
            if lean, foveaSkip(label, wanted: wanted, start: start, playerSaid: playerSaid) {
                times.append(label + " skipped (out of view)")
                return [:]
            }
            rebuildStep = label
            let t0 = Date()
            let q0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: base + question,
                                               options: .init(maxTokens: tokens, temperature: 0.2, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
            noteQ("rebuild", label, raw, since: q0)
            let took: String = String(format: "%.1fs", Date().timeIntervalSince(t0))
            times.append(label + " " + took)
            guard !Task.isCancelled else { return nil }
            // The small model sometimes slips into another script mid-answer: those characters go.
            let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value < 0x2E80 }))
            return JSONExtract.object(plain) ?? Self.salvageJSON(plain)
        }
        func strings(_ m: [String: Any]?, _ k: String, cap: Int) -> [String] {
            var out: [String] = []
            for item in ((m?[k] as? [Any]) ?? []) {
                guard let v = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), v.count > 3, !Self.echoesPrompt(v),
                      !Self.brokenEntry(v) else { continue }
                if !out.contains(where: { Self.similar($0, v) }) { out.append(v) }
                if out.count >= cap { break }
            }
            return out
        }
        // Every entry must be in the story's own words (the bible and everything said so far).
        let story = Continuity.wordSet(start.bible + " " + start.transcript.map(\.text).joined(separator: " "))
        func checked(_ entries: [String], share: Double = 0.6) -> [String] {
            entries.filter { e in
                if Continuity.grounded(e, in: story, share: share) { return true }
                refused.append(e)
                return false
            }
        }
        func commit(_ change: (inout Adventure) -> Void) {
            guard var now = adventure, now.id == start.id else { return }
            change(&now)
            now.scene = Cards.sceneLine(now)
            for f in filed.dropFirst(filedSeen) { trace("FILED", f) }
            if !asked.isEmpty {
                while stepChanges.count < asked.count { stepChanges.append([]) }
                stepChanges[asked.count - 1] += filed.dropFirst(filedSeen)
            }
            filedSeen = filed.count
            if let i = now.transcript.firstIndex(where: { $0.id == lastID }) {
                var note = "REBUILT:" + (asked.isEmpty ? " nothing asked yet" : "\n" + asked.map { "  - " + $0 }.joined(separator: "\n"))
                if !filed.isEmpty { note += "\nFILED:\n" + filed.map { "  - " + $0 }.joined(separator: "\n") }
                if !refused.isEmpty { note += "\nREFUSED (not in the story's words): " + refused.prefix(6).joined(separator: "; ") }
                if !times.isEmpty {
                    let sofar: String = String(format: "%.1fs", Date().timeIntervalSince(began))
                    note += "\nTIMES: " + times.joined(separator: " · ") + " · " + sofar + " so far"
                }
                now.transcript[i].after = note
            }
            Self.updateFrame(&now, asked: asked, notes: notes, steps: stepChanges)
            adventure = now
        }

        // The state diff: one call for a quiet turn. Hands and clothes are sticky in code: they
        // change only when the diff names a thing changing hands, and never from a fresh "what do
        // you have?" guess.
        let quiet = lean && stayingThisTurn && talkThisTurn && !walkedThisTurn && !playerSaid.isEmpty && !focus.isEmpty
            && start.room != nil && start.room?.name.caseInsensitiveCompare(start.location) == .orderedSame
        if quiet, let room = start.room {
            let steps = Self.timeSteps.map(\.0)
            let others: [String] = room.people.filter { $0.kind == .person }.map(\.name)
            let holders: [String] = ["you"] + others + ["the room"]
            let hands: [String] = ["you: " + (start.carrying.isEmpty ? "nothing" : start.carrying.joined(separator: ", "))]
                + room.people.filter { $0.kind == .person }.map { $0.name + ": " + ($0.holding.isEmpty ? "nothing" : $0.holding.joined(separator: ", ")) }
            let was = start.whereabouts.first { Cards.first($0.name).lowercased() == Cards.first(focus).lowercased() }?.doing ?? ""
            let q = "IN HAND BEFORE: " + hands.joined(separator: "; ")
                + "\n" + focus + " WAS: " + (was.isEmpty ? "nothing in particular" : clip(was, 80))
                + "\nFill in this form about the moment, only from what THE PLAYER and THE STORY plainly say. Output ONLY one JSON object:\n"
                + "{\"passed\":\"how long the moment took: " + steps.prefix(4).joined(separator: ", ") + "…\","
                + "\"moved\":[{\"item\":\"a thing that plainly changed hands or was set down\",\"from\":\"who had it\",\"to\":\"who has it now, or the room if it was set down\"}],"
                + "\"doing\":\"what " + focus + " is busy with at the end, a few words (never where they sit or stand: the map has that); 'nothing in particular' if only talking\","
                + "\"mood\":\"" + focus + "'s mood toward the player, one or two words\","
                + "\"facts\":[\"a concrete fact " + focus + " stated outright that stays true tomorrow (hometown, age, work, family, years here), as one plain sentence with their name; never from a question anyone asked, never small talk or a compliment\"],"
                + "\"answered\":\"yes if the player's question got a real answer, or they asked nothing; no if it was dodged or ignored\"}\n"
                + "moved is [] unless a thing plainly changed hands. facts is [] unless something lasting was said aloud.\nThe form:"
            rebuildStep = "What changed?"
            let t0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: base + q,
                                               options: .init(maxTokens: 260, temperature: 0.2, repetitionPenalty: 1.1,
                                                              grammar: JSONGrammar.stateDiff(steps: steps, holders: holders)))) ?? ""
            noteQ("rebuild", "What changed?", raw, since: t0)
            times.append("What changed? " + String(format: "%.1fs", Date().timeIntervalSince(t0)))
            guard !Task.isCancelled else { return }
            let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value < 0x2E80 }))
            let m: [String: Any] = JSONExtract.object(plain) ?? Self.salvageJSON(plain)
            if !m.isEmpty {
                let words = Continuity.wordSet(reply + " " + playerSaid)
                var has: [String] = start.carrying
                var handsNow: [String: [String]] = [:]
                for t in room.people where t.kind == .person { handsNow[t.name] = t.holding }
                var movedNotes: [String] = []
                for e in ((m["moved"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }) {
                    let item = ((e["item"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
                    let from = (e["from"] as? String) ?? "", to = (e["to"] as? String) ?? ""
                    // A thing changes hands only when the moment's own words name it.
                    guard item.count > 2, from != to, !Self.echoesPrompt(item), Continuity.grounded(item, in: words, share: 0.6) else {
                        if item.count > 2 { refused.append(item + " (didn't plainly change hands)") }
                        continue
                    }
                    func same(_ h: String) -> Bool { Self.similar(h, item) || Continuity.grounded(item, in: Continuity.wordSet(h), share: 0.6) || Continuity.grounded(h, in: Continuity.wordSet(item), share: 0.6) }
                    if from == "you" { has.removeAll(where: same) } else if handsNow[from] != nil { handsNow[from]?.removeAll(where: same) }
                    if to == "you" { if !has.contains(where: same) { has.append(clip(item, 60)) } }
                    else if handsNow[to] != nil, handsNow[to]?.contains(where: same) == false { handsNow[to]?.append(clip(item, 50)) }
                    movedNotes.append(item + ": " + from + " → " + to)
                }
                asked.append("What changed hands? → " + (movedNotes.isEmpty ? "nothing" : movedNotes.joined(separator: "; ")))
                commit { now in
                    guard var r = now.room else { return }
                    for (name, list) in handsNow {
                        guard let t = r.named(name), t.holding != list else { continue }
                        var p = t
                        p.holding = list
                        Placer.put(&r, p)
                        filed.append(name + " holds: " + (list.isEmpty ? "nothing" : list.joined(separator: ", ")))
                    }
                    now.room = r
                }
                let mood = ((m["mood"] as? String) ?? "")
                let answered = ((m["answered"] as? String) ?? "yes")
                let person: [String: Any] = ["name": focus, "doing": (m["doing"] as? String) ?? "", "expression": mood, "holding": "", "dressed": "no",
                                             "wearing": "", "moved": "no", "where": "", "facing": "", "feels": mood]
                var d: [String: Any] = [:]
                d["How long did that take?"] = ["passed": (m["passed"] as? String) ?? ""] as [String: Any]
                d["Everyone now?"] = ["people": [person]] as [String: Any]
                d["What do you have?"] = ["has": has] as [String: Any]
                // What was hanging is settled once the player has their answer.
                d["What's still hanging?"] = ["open": answered == "no" ? start.pending : []] as [String: Any]
                d["Did you get an answer?"] = ["answered": answered] as [String: Any]
                d["Anything lasting?"] = ["facts": (m["facts"] as? [Any]) ?? []] as [String: Any]
                diff = d
            }
        }
        let stickyHands = diff != nil

        // 1. Where is the player now? A place picked from the map, or a new one by name.
        let known = start.places.filter { !$0.isEmpty }
        var options: [String] = start.location.isEmpty ? [] : [start.location]
        options += known.filter { $0.caseInsensitiveCompare(start.location) != .orderedSame }.suffix(6)
        options.append("somewhere new")
        // Asked as a change from where the player was: a short line that never names the place
        // ("I am sitting on the stool") keeps them there, it doesn't move them somewhere new.
        // On the way out, the room the player is still standing in on the map is where they are
        // unless the reply shows them arriving somewhere else.
        let lastIn = start.location.isEmpty ? (start.room?.name ?? "") : start.location
        let wasIn = lastIn.isEmpty ? "" : (start.location.isEmpty
            ? "The player set out to leave " + lastIn + ". Did this reply show them arrive somewhere else, or are they still in " + lastIn + "? Unless the reply shows them arriving somewhere, they are still there.\n"
            : "The player was in " + lastIn + ". Did this reply show them leave it and arrive somewhere else, or are they still in " + lastIn + "? Unless the reply shows them going, they are still there.\n")
        let pm = await ask("Where are you now?", wasIn + Prompts.rebuildPlace + "\nTHE LIST: " + options.joined(separator: "; "),
                           JSONGrammar.pickOne("where", from: options, free: "name", chars: 40), 40)
        guard pm != nil else { return }
        let whereSaid = (pm?["where"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nameSaid = (pm?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var placeSaid = whereSaid == "somewhere new" ? nameSaid : whereSaid
        if Self.echoesPrompt(placeSaid) { placeSaid = "" }
        asked.append("Where are you? → " + (placeSaid.isEmpty ? whereSaid : placeSaid))
        commit { now in
            guard placeSaid.count > 2 else { return }
            let loc = Self.placeName(placeSaid, known: now.lore.filter { $0.kind == .place }.map(\.name) + now.places)
            // A new place counts when the player is on the move (code cleared the place), when no
            // place is known yet, or when the read missed a move the exchange plainly shows.
            let missed = !now.location.isEmpty && loc.caseInsensitiveCompare(now.location) != .orderedSame && Continuity.moves(playerSaid)
                && Continuity.leavesPlace(playerSaid + " " + reply) && Continuity.mentions(place: loc, in: reply)
            guard now.location.isEmpty || missed else { return }
            // On the way somewhere unnamed, a place already on the map counts only when the
            // exchange names it; otherwise the small model is reaching for the last name it knows.
            let knownLoc = (now.lore.filter { $0.kind == .place }.map(\.name) + now.places).contains { $0.caseInsensitiveCompare(loc) == .orderedSame }
            // The room still on the map is no reach: the player never got out of it.
            let stillIn = loc.caseInsensitiveCompare(now.room?.name ?? "") == .orderedSame
            if now.location.isEmpty, !missed, knownLoc, !stillIn, !now.transcript.isEmpty,
               !Continuity.names(place: loc, in: playerSaid + " " + reply), !Self.goesTo(loc, in: playerSaid) {
                refused.append(loc + " (the moment never goes there)")
                return
            }
            let from = now.location.isEmpty ? placeBeforeTurn : now.location
            if missed {
                // Whoever the reply does not show coming along stays where the player left them.
                for i in now.whereabouts.indices where now.whereabouts[i].here != false {
                    let f = Cards.first(now.whereabouts[i].name)
                    if f.lowercased() == me || f.lowercased() == "you" || reply.contains(f) { continue }
                    now.whereabouts[i].here = false
                    now.whereabouts[i].engaged = false
                    now.whereabouts[i].leftAt = from
                }
                filed.append("Move the read missed: " + from + " to " + loc)
            }
            // Whoever was left at the place the player has come back to is there again.
            for i in now.whereabouts.indices where now.whereabouts[i].here == false {
                guard let at = now.whereabouts[i].leftAt, !at.isEmpty,
                      at.caseInsensitiveCompare(loc) == .orderedSame || Continuity.names(place: at, in: loc) else { continue }
                if missed, at.caseInsensitiveCompare(from) == .orderedSame { continue }
                now.whereabouts[i].here = true
                now.whereabouts[i].leftAt = nil
                filed.append("Back in view: " + now.whereabouts[i].name)
            }
            now.visit(loc, from: from)
            now.location = loc
            now.things = now.placeThings[loc.lowercased()] ?? []
            if !now.lore.contains(where: { $0.kind == .place && $0.name.caseInsensitiveCompare(loc) == .orderedSame }) {
                let look = PresenceFilter.sentences(reply).filter { !$0.contains("\"") && !$0.contains("“") }.prefix(2).joined(separator: " ")
                _ = addLore(&now, LoreEntry(name: loc, kind: .place, desc: clip(look.trimmingCharacters(in: .whitespacesAndNewlines), 240)))
                filed.append("New place card: " + loc)
            } else {
                filed.append("Place: " + loc)
            }
        }
        commit { now in
            // A place card with no description takes one from the reply.
            guard let i = now.lore.firstIndex(where: { $0.kind == .place && !now.location.isEmpty && $0.name.caseInsensitiveCompare(now.location) == .orderedSame }),
                  now.lore[i].desc.isEmpty, !now.lore[i].byPlayer else { return }
            let look = PresenceFilter.sentences(reply).filter { !$0.contains("\"") && !$0.contains("“") }.prefix(2).joined(separator: " ")
            let desc = look.trimmingCharacters(in: .whitespacesAndNewlines)
            if desc.count > 20 { now.lore[i].desc = clip(desc, 240); filed.append("Place card described: " + now.location) }
        }

        // A room the story has just entered is laid out now, while the reply is read aloud. People
        // it places from this same reply are not moved again by the questions below.
        let roomBefore = adventure?.rooms.count ?? 0
        await furnishRoom(story: (playerSaid.isEmpty ? "" : "THE PLAYER: " + clip(playerSaid, 300) + "\n") + "THE STORY: " + clip(reply, 900))
        drawnNow = (adventure?.rooms.count ?? 0) > roomBefore
        // The opening, or an arrival, was told from a map drawn before it: what that reply added is
        // put on the map now, once. From here on the room is locked.
        if !drawnNow, let id = roomDrawnBeforeReply, adventure?.room?.id == id {
            roomDrawnBeforeReply = nil
            await topUpRoom(story: (playerSaid.isEmpty ? "THE OPENING: " : "THE PLAYER: " + clip(playerSaid, 300) + "\nTHE ARRIVAL: ") + clip(reply, 900))
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }

        // How long the moment took: the story clock moves by it (unless the player set the time).
        if start.clock != nil, !playerSaid.isEmpty, Continuity.statedTime(playerSaid, near: start.clock) == nil,
           Continuity.laterBy(playerSaid, clock: start.clock) == nil {
            let steps = Self.timeSteps
            let tm = await ask("How long did that take?", Prompts.rebuildTime + "\nTHE LIST: " + steps.map(\.0).joined(separator: "; "),
                               JSONGrammar.one("passed", from: steps.map(\.0)), 20)
            let said = (tm?["passed"] as? String) ?? ""
            if var minutes = steps.first(where: { $0.0 == said })?.1 {
                // Hours only pass when the words say so; going somewhere takes at least a few minutes.
                let longWords = #"(?i)\b(hours?|sleep|slept|asleep|bed|night|morning|nap|wait(ed|ing)?|later|rest|all day)\b"#
                if minutes >= 60, playerSaid.range(of: longWords, options: .regularExpression) == nil { minutes = 30 }
                let moved = !placeBeforeTurn.isEmpty && (adventure?.location ?? "").caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
                if moved, minutes < 5 { minutes = 5 }
                asked.append("How long did that take? → " + said)
                commit { now in
                    guard let c = now.clock else { return }
                    now.clock = c + minutes
                    now.storyTime = Continuity.storyTime(clock: c + minutes, old: now.storyTime)
                    filed.append("Clock: +" + Self.span(minutes) + ", now " + Continuity.clockText(c + minutes))
                }
            }
        }

        // 2. Who is with the player at the end? Someone counts as arriving or leaving only when the
        // reply itself shows them.
        let cast = start.cast
        if !cast.isEmpty {
            let wereHere: [String] = start.whereabouts.filter { $0.here != false }.compactMap { w in Cards.card(for: w, in: start)?.name }
            let wasWith = wereHere.isEmpty ? "" : wereHere.joined(separator: " and ") + (wereHere.count == 1 ? " was" : " were") + " here with the player. Did anyone leave or arrive in this reply, or are the same people still here? Unless the reply shows someone going or coming, they are still here.\n"
            let hm = await ask("Who is with you?", wasWith + Prompts.rebuildPeople + "\nTHE LIST: " + cast.map { $0.name + roleOf($0) }.joined(separator: "; "),
                               JSONGrammar.names("here", from: cast.map(\.name), max: 6), 80)
            guard hm != nil else { return }
            let listed = ((hm?["here"] as? [Any]) ?? []).compactMap { $0 as? String }
            // Skipped (a talk turn): nobody comes or goes on an answer that was never asked.
            if hm?.isEmpty == false {
            asked.append("Who is with you? → " + (listed.isEmpty ? "nobody" : listed.joined(separator: ", ")))
            let leaves = #"(?i)\b(leaves|walks out|heads (out|off)|goes out|disappears|slips out|steps out|is gone|walks away|hurries off)\b"#
            commit { now in
                for c in cast {
                    let isListed = listed.contains { $0.caseInsensitiveCompare(c.name) == .orderedSame }
                    let shown = Cards.mentions(c, in: reply)
                    guard shown else { continue }
                    if let i = now.whereabouts.firstIndex(where: { Cards.card(for: $0, in: now)?.id == c.id }) {
                        if isListed, now.whereabouts[i].here == false, Self.showsArriving(c, in: reply) {
                            now.whereabouts[i].here = true
                            now.whereabouts[i].engaged = false
                            now.whereabouts[i].leftAt = nil
                            if !now.location.isEmpty { now.whereabouts[i].at = now.location }
                            filed.append("Came into view: " + c.name)
                        } else if !isListed, now.whereabouts[i].here != false, reply.range(of: leaves, options: .regularExpression) != nil {
                            now.whereabouts[i].here = false
                            now.whereabouts[i].engaged = false
                            now.whereabouts[i].leftAt = now.location.isEmpty ? nil : now.location
                            filed.append("Out of view: " + c.name)
                        }
                    } else if isListed {
                        now.whereabouts.append(Whereabout(name: c.name, at: now.location.isEmpty ? "here" : now.location, here: true, engaged: false))
                        filed.append("Came into view: " + c.name)
                    }
                }
            }
            }
        }

        // Anyone new? The model lists everyone the moment shows here; anyone not already on file
        // is put to the model against the cast: one of them, or someone new.
        let lm = await ask("Who does the moment show?", Prompts.rebuildPeopleShown, JSONGrammar.strings("people", max: 6, chars: 60), 120)
        guard lm != nil else { return }
        let shown: [String] = ((lm?["people"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 2 }
        asked.append("Who does the moment show? → " + (shown.isEmpty ? "nobody" : shown.joined(separator: "; ")))
        let me1 = Cards.first(start.playerName).lowercased()
        for who in shown {
            let l = who.lowercased()
            if ["you", "the player", "yourself"].contains(l) || (!me1.isEmpty && l.contains(me1)) { continue }
            // Named as someone on file: nothing to ask.
            if start.cast.contains(where: { c in l.contains(c.name.lowercased()) || Continuity.wordSet(who).contains(Cards.first(c.name).lowercased()) }) { continue }
            let castList = start.cast.map { $0.name + roleOf($0) }.joined(separator: "; ")
            let pm = await ask("Who is " + clip(who, 40) + "?",
                               "In this moment the story shows \"" + who + "\". Is that one of these people, or someone new?\nPEOPLE: " + castList
                               + "\nAnswer with their name, or \"someone new\". If someone new, role: what they are, two or three plain words (e.g. 'police inspector'); otherwise empty.",
                               JSONGrammar.pickOne("who", from: start.cast.map(\.name) + ["someone new"], free: "role", chars: 40), 50)
            guard pm != nil else { return }
            guard (pm?["who"] as? String) == "someone new" else { asked.append("Who is " + who + "? → " + ((pm?["who"] as? String) ?? "?")); continue }
            let roleSaid = ((pm?["role"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            asked.append("Who is " + who + "? → someone new" + (roleSaid.isEmpty ? "" : " (" + roleSaid + ")"))
            // Their name if the story gives one ("Mr. Elias"), otherwise what they are ("The police inspector").
            let named = who.first?.isUppercase == true && !["the ", "a ", "an "].contains { who.lowercased().hasPrefix($0) }
            let name = named ? who : (Self.roleName(roleSaid) ?? Self.roleName(who) ?? "")
            commit { now in
                guard !name.isEmpty else { return }
                if let added = addNewcomer(&now, name: name, role: roleSaid.isEmpty ? who : roleSaid, about: reply + " " + playerSaid + " " + who, engaged: false) {
                    filed.append("New person card: " + added + (roleSaid.isEmpty ? "" : " (" + roleSaid + ")"))
                } else {
                    refused.append(name + " (could not add as someone new)")
                }
            }
        }

        // What the player tells people about themselves is kept in their own words, for everyone
        // who heard it.
        if let told = Self.toldAboutSelf(playerSaid) {
            commit { now in
                let all = told.all || !now.whereabouts.contains { $0.engaged == true && $0.here != false }
                for w in now.whereabouts where w.here != false && (all || w.engaged == true) {
                    guard let c = Cards.card(for: w, in: now), !c.isPlayer else { continue }
                    let key = c.name.lowercased()
                    var known: [String] = now.knows[key] ?? []
                    if known.contains(where: { Self.similar($0, told.what) }) { continue }
                    known.append(told.what)
                    now.knows[key] = Self.keepKnown(known)
                    filed.append(c.name + " now knows: " + told.what)
                }
            }
        }

        // 3. What is each person in view doing? One short question each, for the ones the reply shows.
        let mid: Adventure = adventure ?? start
        var inView: [LoreEntry] = []
        for w in mid.whereabouts where w.here != false {
            let f = Cards.first(w.name).lowercased()
            guard f != me, f != "you", let c = Cards.card(for: w, in: mid), Cards.mentions(c, in: reply) else { continue }
            if !inFocus(c.name) { times.append(c.name + " skipped (outside the fovea)"); continue }
            inView.append(c)
        }
        // Each of them on the grid: what they are doing, their expression, what they hold, where
        // they are and what they face. One question each, only for people the moment shows (the
        // rest were out of view, so nothing the player saw could have changed them).
        let gridNow: Room? = mid.room
        let justDrawn = (adventure?.rooms.count ?? 0) > roomBefore || (start.room == nil && mid.room != nil)
        let personZones: [String] = gridNow.map { Zone.menu($0, people: true) } ?? []
        var faceList: [String] = ["you", "the door"]
        if let g = gridNow {
            if !g.windows.isEmpty { faceList.append("the window") }
            faceList += g.people.filter { $0.kind == .person }.map(\.name)
            faceList += Array(g.objects.filter { !Rules.rule($0.icon).small && $0.icon != "rug" }.map(\.name).prefix(6))
        }
        // Everyone in view, and everyone the player is with, in one batch: what each is doing,
        // their expression, what they hold and wear, where they are and what they face, and (for
        // the ones the player is with) how they feel about the player. One flat object each.
        let facingNow: [LoreEntry] = mid.whereabouts.filter { $0.here != false && $0.engaged == true }.compactMap { Cards.card(for: $0, in: mid) }.filter { inFocus($0.name) }
        var batch: [LoreEntry] = Array(inView.prefix(3))
        for c in facingNow.prefix(2) where !batch.contains(where: { $0.id == c.id }) { batch.append(c) }
        var feelings: [(LoreEntry, String)] = []
        if !batch.isEmpty {
            let showsList = batch.map { c in
                let was = mid.whereabouts.first { Cards.card(for: $0, in: mid)?.id == c.id }?.doing ?? ""
                return "- " + c.name + roleOf(c) + (was.isEmpty ? "" : " (was: " + clip(was, 80) + ")") + (inView.contains { $0.id == c.id } ? "" : " (the story doesn't show them this moment: stays put, same as before)")
            }
            let q = "THE PLACES: " + (["stays put"] + personZones + [Self.goneOut]).joined(separator: "; ") + "\nTHE FACES: " + faceList.joined(separator: "; ")
                + "\nTHE PEOPLE:\n" + showsList.joined(separator: "\n")
                + "\n\nAbout each of THE PEOPLE at the end of the moment, only as the story shows it, one object each, in that order. Output ONLY one JSON object:\n{\"people\":[{\"name\":\"one of THE PEOPLE\",\"doing\":\"what they are doing now, a few words: something that goes on (knitting, polishing glasses, watching the fog). A quick action, theirs before (was) or in the story (setting a glass down, nodding), is over once shown: say what they do next, or nothing in particular. Their eyes decide it: eyes on the book is reading; eyes on you means they have paused (the book can still be in their hands, under holding)\",\"expression\":\"their face, one to three words (smiling warmly, tired, attentive): never their voice, hair or hands\",\"holding\":\"same as before unless the story shows them pick something up or put it down; then the thing from the list, or nothing\",\"dressed\":\"yes only if the story shows them putting something on or taking something off; otherwise no\",\"wearing\":\"if dressed is yes, the clothes they wear now (a coat, a hat), never hair, skin or hands; otherwise same\",\"moved\":\"yes only if the story shows them walking somewhere, or someone asked them to come over; otherwise no\",\"where\":\"one of THE PLACES; stays put if they didn't move; " + Self.goneOut + " only if the story shows them leaving this place\",\"facing\":\"one of THE FACES\",\"feels\":\"how they feel about you, one or two words\"}]}\nThe form:"
            let realHolds: [String] = Array(Set((gridNow?.objects.filter { Rules.rule($0.icon).small }.map { Fovea.bare($0.name) } ?? []) + (gridNow?.people.flatMap(\.holding) ?? []))).sorted()
            let dm = await ask("Everyone now?", q, JSONGrammar.peopleNow(names: batch.map(\.name), zones: personZones + [Self.goneOut], faces: faceList, holds: realHolds), 60 + 75 * batch.count)
            guard let dm else { return }
            var seen: Set<UUID> = []
            for e in ((dm["people"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }) {
                let said = ((e["name"] as? String) ?? "")
                guard let c = batch.first(where: { $0.name.caseInsensitiveCompare(said) == .orderedSame }), !seen.contains(c.id) else { continue }
                seen.insert(c.id)
                func field(_ k: String) -> String {
                    // A note in brackets ("(implied from the bartender)") is the model thinking aloud, not an answer.
                    let raw = ((e[k] as? String) ?? "").replacingOccurrences(of: #"\s*\([^)]*\)?"#, with: "", options: .regularExpression)
                    let v = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
                    return v.count > 2 && !Self.echoesPrompt(v) && !["nothing", "none", "n/a", "same"].contains(v.lowercased()) ? v : ""
                }
                if facingNow.prefix(2).contains(where: { $0.id == c.id }) {
                    let feels = field("feels")
                    if feels.split(separator: " ").count <= 4, !feels.isEmpty { feelings.append((c, feels)) }
                }
                // Someone the story doesn't show this moment keeps what they were doing.
                guard inView.prefix(3).contains(where: { $0.id == c.id }) else { continue }
                // "Nothing in particular": the last thing they did is over, and they go back to just being there.
                let rawDoing = ((e["doing"] as? String) ?? "").lowercased()
                let doneNow = rawDoing.contains("nothing in particular")
                let doing = doneNow ? "" : field("doing")
                // A face, in a few words: a longer answer ("a deep rumble in his voice") is not one.
                let face0 = field("expression")
                let face = face0.split(separator: " ").count <= 4 ? face0 : ""
                var holds = field("holding")
                if holds.contains("(") || holds.lowercased().contains("hand") || holds.lowercased().contains("implied") { holds = "" }
                // Clothes change only when the model first says the story shows them dressing or
                // undressing: "over his glasses" in passing is not a new outfit.
                let dressedSaid = ((e["dressed"] as? String) ?? "").lowercased()
                let wears = dressedSaid.hasPrefix("y") ? field("wearing") : ""
                if !dressedSaid.hasPrefix("y"), !field("wearing").isEmpty { refused.append(c.name + " wearing " + field("wearing") + " (the story didn't show them dressing)") }
                // A move is made only when the model first says they moved, or were asked to: a place
                // picked from the list on its own ("at the bar") moved everyone in beside the player.
                let movedSaid = ((e["moved"] as? String) ?? "").lowercased()
                let whereSaid = movedSaid.hasPrefix("y") ? field("where") : ""
                if !movedSaid.hasPrefix("y"), !field("where").isEmpty, field("where") != "stays put" { refused.append(c.name + " → " + field("where") + " (they didn't move and weren't asked to)") }
                let facingSaid = field("facing")
                asked.append(c.name + " now? → " + [doing, face, whereSaid == "stays put" ? "" : whereSaid, facingSaid.isEmpty ? "" : "facing " + facingSaid, wears.isEmpty ? "" : "wearing " + wears]
                    .filter { !$0.isEmpty }.joined(separator: "; "))
                commit { now in
                    // Someone the story shows leaving goes off the map (they are no longer here).
                    if whereSaid == Self.goneOut, let i = now.whereabouts.firstIndex(where: { Cards.card(for: $0, in: now)?.id == c.id }) {
                        now.whereabouts[i].here = false
                        now.whereabouts[i].engaged = false
                        now.whereabouts[i].at = "gone out"
                        filed.append(c.name + " left")
                        return
                    }
                    if doneNow, let i = now.whereabouts.firstIndex(where: { Cards.card(for: $0, in: now)?.id == c.id }), !now.whereabouts[i].doing.isEmpty {
                        filed.append(c.name + " done: " + now.whereabouts[i].doing)
                        now.whereabouts[i].doing = ""
                        if var rr = now.room, let t = rr.named(c.name) { var q = t; q.doing = ""; Placer.put(&rr, q); now.room = rr }
                    }
                    if !doing.isEmpty, let i = now.whereabouts.firstIndex(where: { Cards.card(for: $0, in: now)?.id == c.id }), now.whereabouts[i].here != false {
                        if now.whereabouts[i].doing.caseInsensitiveCompare(doing) != .orderedSame { filed.append(c.name + " now: " + doing) }
                        now.whereabouts[i].doing = clip(doing, 100)
                    }
                    guard var r = now.room, let t = r.named(c.name), t.isPerson else { return }
                    var p = t
                    if !face.isEmpty, face != p.expression { p.expression = clip(face, 60); filed.append(c.name + " expression: " + face) }
                    // What someone holds is a real thing from the room (something small on the map,
                    // or already in someone's hands), found by name; anything else ("a calloused
                    // finger tapping a ledger") leaves their hands as they were.
                    if !stickyHands {
                        let rawHolds = ((e["holding"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
                        if ["nothing", "none", "empty", "empty hands"].contains(rawHolds) {
                            p.holding = []
                        } else if !holds.isEmpty, rawHolds != "same as before" {
                            let real: [String] = r.objects.filter { Rules.rule($0.icon).small }.map { Fovea.bare($0.name) } + r.people.flatMap(\.holding)
                            if let match = real.first(where: { Self.similar($0, holds) || Continuity.grounded(holds, in: Continuity.wordSet($0), share: 0.7) }), Self.holdable(match) {
                                p.holding = [match]
                            } else {
                                refused.append(c.name + " holding " + holds + " (no such thing in the room)")
                            }
                        }
                    }
                    if !wears.isEmpty, wears.caseInsensitiveCompare(p.wearing) != .orderedSame { p.wearing = clip(wears, 80); filed.append(c.name + " wears: " + wears) }
                    if !doing.isEmpty { p.doing = clip(doing, 100) }
                    Placer.put(&r, p)
                    if !whereSaid.isEmpty, whereSaid != "stays put", plannedNow[c.name] == nil, !justDrawn, var z = Zone.parse(whereSaid), t.pastMoves.first != z.text {
                        if case .at(let n) = z, let was = t.pastMoves.first, was.hasPrefix("behind"), was.contains(Zone.short(n)) { z = .behind(n) }
                        if z.text == t.pastMoves.first { now.room = r; return }
                        let note = Placer.placePerson(&r, p, zone: z)
                        r.log.append("move: " + c.name + " → " + z.text + (note.isEmpty ? "" : " (" + note + ")"))
                        if let moved = r.thing(p.id) { r.things[r.index(p.id)!].pastMoves = [z.text] + Array(moved.pastMoves.prefix(7)) }
                        filed.append(c.name + " moves " + z.text)
                    }
                    if !facingSaid.isEmpty {
                        let before = r.thing(p.id)?.facing
                        Placer.turn(&r, p.id, toward: facingSaid)
                        if r.thing(p.id)?.facing != before { r.log.append("turn: " + c.name + " to " + facingSaid) }
                    }
                    now.room = r
                }
            }
        }
        for (c, feels) in feelings {
            asked.append(c.name + " feels? → " + feels)
            commit { now in
                let key = c.name.lowercased()
                if let was = now.feelings[key], was.caseInsensitiveCompare(feels) != .orderedSame { filed.append(c.name + " now feels " + feels + " (was " + was + ")") }
                now.feelings[key] = feels.lowercased()
            }
        }

        // What the person facing the player said, kept with them, word for word (code, no question).
        let lines: [String] = Self.quotes(in: reply)
        if let speaker = mid.whereabouts.first(where: { $0.here != false && $0.engaged == true }).flatMap({ Cards.card(for: $0, in: mid) }), !lines.isEmpty {
            commit { now in
                guard var r = now.room, let t = r.named(speaker.name), let i = r.index(t.id) else { return }
                r.things[i].dialogue = Array((r.things[i].dialogue + lines.map { clip($0, 160) }).suffix(8))
                now.room = r
            }
        }

        // What each person the player is with wants right now, and what they just learned about
        // the player (only from the player's own words).
        let mineOnly = Continuity.wordSet(playerSaid + " you your player " + start.playerName)
        for c in facingNow.prefix(2) {
            let wm = await ask("What does " + c.name + " want, and what did they learn?", Prompts.rebuildWants(c.name + roleOf(c)),
                               JSONGrammar.triple("wants", 110, "learned", 100, "between", 100), 120)
            guard wm != nil else { return }
            let trim = CharacterSet(charactersIn: " .\n")
            let wants: String = ((wm?["wants"] as? String) ?? "").trimmingCharacters(in: trim)
            let learnedSaid: String = ((wm?["learned"] as? String) ?? "").trimmingCharacters(in: trim)
            var learned: String = ""
            // Before the player has said a word (the opening), nobody has learned anything about
            // them and nothing has passed between them yet.
            if !playerSaid.isEmpty, learnedSaid.count > 5, !Self.echoesPrompt(learnedSaid), Continuity.grounded(learnedSaid, in: mineOnly, share: 0.5) { learned = learnedSaid }
            let wantOK = wants.count > 3 && !Self.echoesPrompt(wants)
            // What happened between them and the player, kept on their card: only what the player's
            // own words or the reply show.
            let betweenSaid: String = ((wm?["between"] as? String) ?? "").trimmingCharacters(in: trim)
            var together: String = ""
            let togetherWords: Set<String> = Continuity.wordSet(playerSaid + " " + reply + " you your " + c.name + " " + c.role)
            if !playerSaid.isEmpty, betweenSaid.count > 5, !Self.echoesPrompt(betweenSaid), Continuity.grounded(betweenSaid, in: togetherWords, share: 0.6) {
                together = betweenSaid
            }
            let wantsLine: String = c.name + " wants? → " + (wantOK ? wants : "not shown") + (learned.isEmpty ? "" : "; learned: " + learned)
            asked.append(wantsLine + (together.isEmpty ? "" : "; between you: " + together))
            commit { now in
                let key = c.name.lowercased()
                if wantOK {
                    if (now.wants[key] ?? "").caseInsensitiveCompare(wants) != .orderedSame { filed.append(c.name + " wants: " + wants) }
                    now.wants[key] = clip(wants, 120)
                }
                var known: [String] = now.knows[key] ?? []
                // Only things about the player, not a note that they asked something.
                let junk = learned.range(of: #"(?i)^(you|the player) (asked|are curious|is curious|have forgotten|has forgotten|want to know|wants to know)"#, options: .regularExpression) != nil
                var tidy = learned.replacingOccurrences(of: "the player", with: "you")
                for (from, to) in [(#"\byou is\b"#, "you are"), (#"\byou was\b"#, "you were"), (#"\byou has\b"#, "you have"), (#"\bthemselves\b"#, "yourself"), (#"\byou introduced (himself|herself)\b"#, "you introduced yourself"), (#"\b(himself|herself)\b"#, "yourself"),
                                   (#"(?i)^you are (sitting|standing|listening|asking|waiting|looking)\b.*"#, "")] {
                    tidy = tidy.replacingOccurrences(of: from, with: to, options: .regularExpression)
                }
                var fresh: [String] = tidy.isEmpty || junk ? [] : [clip(tidy, 110)]
                if let said = Continuity.selfIntroduction(playerSaid) { fresh.append("your name is " + said) }
                for f in fresh where !known.contains(where: { Self.similar($0, f) }) {
                    known.append(f)
                    filed.append(c.name + " now knows: " + f)
                }
                now.knows[key] = Self.keepKnown(known)
                if !together.isEmpty {
                    var shared: [String] = now.between[key] ?? []
                    if !shared.contains(where: { Self.similar($0, together) }) {
                        shared.append(clip(together, 110))
                        now.between[key] = Array(shared.suffix(6))
                        filed.append("Between you and " + c.name + ": " + together)
                    }
                }
            }
        }

        // Where the player is in the room now, and which way they face: picked from the grid's places.
        if let g = adventure?.room, g.player != nil {
            let zs = Zone.menu(g, people: true)
            var fl: [String] = ["the door"]
            if !g.windows.isEmpty { fl.append("the window") }
            fl += g.people.filter { $0.kind == .person }.map(\.name)
            fl += Array(g.objects.filter { !Rules.rule($0.icon).small && $0.icon != "rug" }.map(\.name).prefix(6))
            let q = "THE PLACES: " + (["stays put"] + zs).joined(separator: "; ") + "\nTHE FACES: " + fl.joined(separator: "; ")
                + "\n\nWhere is the player at the end of the moment, and who or what are they facing? Only what the player did or the story shows: if the player walked over to someone, they are beside that person now. Output ONLY one JSON object:\n{\"where\":\"one of THE PLACES; stays put if they didn't move\",\"facing\":\"one of THE FACES\"}\nThe form:"
            let sm = await ask("Where are you in the room?", q, JSONGrammar.playerNow(zones: zs, faces: fl), 50)
            guard let sm else { return }
            let whereSaid = ((sm["where"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let facingSaid = ((sm["facing"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            asked.append("Where are you in the room? → " + whereSaid + (facingSaid.isEmpty ? "" : ", facing " + facingSaid))
            // Seated, and the answer would take you off the seat ("by the counter"): only an
            // outright getting up in the story or the player's words does that.
            var standsUp = true
            var isSeatMove = false
            if case .on = Zone.parse(whereSaid) { isSeatMove = true }
            if !whereSaid.isEmpty, whereSaid != "stays put", !isSeatMove, let seatID = (adventure ?? start).room?.player?.on,
               let seat = (adventure ?? start).room?.thing(seatID) {
                let uq = "You are sitting on the " + Fovea.bare(seat.name) + ". Do THE PLAYER's words or THE STORY say outright that you stand up, get off it or walk somewhere?"
                let um = await ask("Did you get up?", uq + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                standsUp = ((um?["answer"] as? String) ?? "").lowercased().hasPrefix("y")
                asked.append("Did you get up? → " + (standsUp ? "yes" : "no, still on the " + Fovea.bare(seat.name)))
            }
            commit { now in
                guard var r = now.room, let me = r.player else { return }
                if whereSaid != "stays put", standsUp, let z = Zone.parse(whereSaid) {
                    Placer.placePerson(&r, me, zone: z)
                    r.log.append("move: you → " + z.text)
                    let spot: String
                    switch z {
                    case .on(let n): spot = "on " + Fovea.bare(n)
                    default: spot = z.text
                    }
                    if now.spot.caseInsensitiveCompare(spot) != .orderedSame { filed.append("You are now: " + spot) }
                    now.spot = spot
                }
                if !facingSaid.isEmpty { Placer.turn(&r, me.id, toward: facingSaid) }
                now.room = r
            }
        }

        // 4. What does the player have? New things are added; a thing leaves only when the moment
        // shows it going. Only what this reply shows counts (ordering a drink is not having it).
        let had = start.carrying.isEmpty ? "(nothing listed)" : start.carrying.joined(separator: "; ")
        let cm = await ask("What do you have?", "YOU HAD: " + had + "\n" + Prompts.rebuildCarrying, JSONGrammar.strings("has", max: 6, chars: 60), 120)
        guard cm != nil else { return }
        let inReply = Continuity.wordSet(reply)
        // What someone else is wearing is theirs, and a smell or a light is nothing to carry.
        let theirs: [Set<String>] = start.cast.map { Continuity.wordSet($0.desc) }
        let mineSaid = Continuity.wordSet(playerSaid)
        var held = checked(strings(cm, "has", cap: 6).map { clip($0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), 70) }).filter { h in
            let w: Set<String> = Continuity.wordSet(h).filter { $0.count > 2 }
            let worn = w.count >= 2 && theirs.contains(where: { w.intersection($0).count >= 2 })
            if worn, w.intersection(mineSaid).count < 2, !start.carrying.contains(where: { Self.similar($0, h) }) {
                refused.append(h + " (someone else's)")
                return false
            }
            if start.carrying.contains(where: { Self.similar($0, h) }) { return true }
            // Something new in your hands has to come from your own words or be shown as yours:
            // someone else "holding up a spool of thread" doesn't put it in your hands, and what you
            // just set down doesn't come back because the reply names it.
            if putDownThisTurn.contains(where: { Self.similar($0, h) || Continuity.grounded($0, in: Continuity.wordSet(h), share: 0.5) }) {
                refused.append(h + " (you just put it down)")
                return false
            }
            guard Continuity.grounded(h, in: inReply) else {
                refused.append(h + " (not in this reply)")
                return false
            }
            // A thing on the map (the record on the gramophone, the mugs on the table) stays there
            // unless the player's own words pick it up.
            let onMap: [String] = (start.room?.objects ?? []).map { Zone.short($0.name) } + (start.room?.people ?? []).flatMap(\.holding)
            if onMap.contains(where: { Self.similar($0, h) || Continuity.grounded($0, in: Continuity.wordSet(h), share: 0.6) }),
               !Continuity.grounded(h, in: mineSaid, share: 0.5) {
                refused.append(h + " (it's in the room, not in your hands)")
                return false
            }
            if Self.shownAsYours(h, reply: reply, playerSaid: playerSaid) { return true }
            refused.append(h + " (not shown in your hands)")
            return false
        }
        // What the player said they picked up, and the story shows them with, is theirs even when
        // the answer above missed it ("I pick up all of the stools and hold them").
        if let taken = Self.pickedUp(playerSaid), Continuity.grounded(taken, in: inReply, share: 0.99),
           !held.contains(where: { Self.similar($0, taken) || Continuity.wordSet($0).isSuperset(of: Continuity.wordSet(taken)) }),
           !start.carrying.contains(where: { Self.similar($0, taken) }) {
            held.append(taken)
            notes.append("Picked up, from your own words: " + taken)
        }
        // The same thing under another name ("wet coat", "dripping coat") or something you wear
        // ("You wear an umbrella-laden coat") is not a second thing in your hands.
        do {
            func head(_ s: String) -> String { s.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? "" }
            let worn = start.facts.filter { $0.hasPrefix("You wear") }.map { Continuity.wordSet($0) }
            var heads = Set(start.carrying.filter { c in !held.contains(where: { Self.similar($0, c) }) }.map(head))
            held = held.filter { h in
                let k = head(h)
                if k.count > 2, worn.contains(where: { $0.contains(k) }) { refused.append(h + " (you wear it)"); return false }
                if k.count > 2, !heads.insert(k).inserted { refused.append(h + " (the same thing as one you have)"); return false }
                return true
            }
        }
        // Only real things go in your hands: "shivering" or "soaked to the bone" is not one.
        var heldThings: [String] = []
        for h in held {
            if start.carrying.contains(where: { Self.similar($0, h) }) { heldThings.append(h); continue }
            let what = await Self.whatIs(h, noun: { q in
                let m = await ask("What object is " + clip(h, 40) + "?", q + "\nOutput ONLY one JSON object:\n{\"object\":\"one noun, or none\"}\nThe form:", JSONGrammar.text("object", chars: 24), 16)
                return (m?["object"] as? String) ?? ""
            }, choose: { q, opts in
                let m = await ask(clip(q, 70), q + "\nCHOICES: " + opts.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"answer\":\"one of CHOICES\"}\nThe form:", JSONGrammar.one("answer", from: opts), 64)
                return (m?["answer"] as? String) ?? ""
            }, yesNo: { _ in nil })
            // Only what can be carried: furniture can't be in your hands, and neither can a
            // "shivering frame".
            if what.hasPrefix("small") || what.hasPrefix("worn") { heldThings.append(h) } else { refused.append(h + " (" + what + ")") }
        }
        held = heldThings
        asked.append("What do you have? → " + (held.isEmpty ? "nothing new" : held.joined(separator: "; ")))
        commit { now in
            guard !held.isEmpty else { return }
            let said = (playerSaid + " " + reply).lowercased()
            let gone = #"\b(give|gives|gave|given|hand|hands|handed|pay|pays|paid|sell|sold|eat|eats|ate|eaten|drink|drank|finish|finished|drop|dropped|leave|left|put|puts|set|sets|place|places|placed|slide|slides|slid|lose|lost|toss|tossed|swap|swapped|trade|traded)\b"#
            let parting = said.range(of: gone, options: .regularExpression) != nil
            var ledger = held
            for old in start.carrying where !held.contains(where: { Self.similar($0, old) }) {
                let noun = old.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
                // What the player just picked up isn't gone because the reply says "left" or "set".
                let before = start.transcript.dropLast(2).last(where: { $0.role == .gm })?.text ?? ""
                let justTaken = Self.pickedUp(playerSaid).map { $0.lowercased().contains(noun) }
                    ?? (Self.pickedUpIt(playerSaid, lastReply: before, props: [old]) != nil)
                if parting, !justTaken, noun.count >= 3, said.contains(noun) { filed.append("Gone from your hands: " + old); continue }
                ledger.append(old)
            }
            for h in held where !start.carrying.contains(where: { Self.similar($0, h) }) { filed.append("You have: " + h) }
            now.carrying = Array(ledger.prefix(8))
        }

        // 5. What is around? Only what this reply showed, kept with the place.
        let between = focus.isEmpty ? "" : "Only things between you and " + focus + ", or on your way to them; leave out the rest of the room.\n"
        let tm = await ask("What is around?", between + Prompts.rebuildThings, JSONGrammar.strings("things", max: 6, chars: 60), 120)
        guard tm != nil else { return }
        let candidates = checked(strings(tm, "things", cap: 6).map { clip($0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), 70) }).filter { e in
            let w: Set<String> = Continuity.wordSet(e).filter { $0.count > 2 }
            if w.count >= 2, theirs.contains(where: { w.intersection($0).count >= 2 }) {
                refused.append(e + " (someone's own)")
                return false
            }
            if Continuity.grounded(e, in: inReply) { return true }
            refused.append(e)
            return false
        }
        // Each one, the model says what it is: a thing in the room, something someone wears or
        // carries, a sound, smell, light or mood, or part of the building or the sky.
        var around: [String] = []
        var handSized: Set<String> = []
        for e in candidates {
            // Already on the map: nothing to ask.
            if adventure?.room?.named(e) != nil { around.append(e); continue }
            let what = await Self.whatIs(e, noun: { q in
                let m = await ask("What object is " + clip(e, 40) + "?", q + "\nOutput ONLY one JSON object:\n{\"object\":\"one noun, or none\"}\nThe form:", JSONGrammar.text("object", chars: 24), 16)
                return (m?["object"] as? String) ?? ""
            }, choose: { q, opts in
                let m = await ask(clip(q, 70), q + "\nCHOICES: " + opts.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"answer\":\"one of CHOICES\"}\nThe form:", JSONGrammar.one("answer", from: opts), 64)
                return (m?["answer"] as? String) ?? ""
            }, yesNo: { q in
                let m = await ask(clip(q, 70), q + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                guard let a = (m?["answer"] as? String)?.lowercased(), !a.isEmpty else { return nil }
                return a.hasPrefix("y")
            })
            if what.isEmpty || what.hasPrefix("a thing") { around.append(e); asked.append("What is " + e + "? → a thing in the room"); continue }
            // Something you could pick up with one hand is a prop of the moment: no square of its own.
            if what.hasPrefix("small") { around.append(e); handSized.insert(e); asked.append("What is " + e + "? → " + what); continue }
            refused.append(e + " (" + what + ")")
            asked.append("What is " + e + "? → " + what)
        }
        asked.append("What is around? → " + (around.isEmpty ? "nothing new" : around.joined(separator: "; ")))
        commit { now in
            guard !around.isEmpty else { return }
            let key = now.location.lowercased()
            let had = key.isEmpty ? now.things : (now.placeThings[key] ?? [])
            let merged = Array((around + had.filter { o in !around.contains { Self.similar($0, o) } }).prefix(8))
            now.things = merged
            if !key.isEmpty { now.placeThings[key] = merged }
            let added = around.filter { n in !had.contains { Self.similar($0, n) } }
            if !added.isEmpty { filed.append("Props here: " + added.joined(separator: "; ")) }
        }

        // A room is drawn once, when the place is new. After that the story's props are kept as
        // words with the place, and nothing new is added to the map: no lamps, glows or "rooms"
        // peppered in around the furniture that was laid out.
        _ = handSized

        // The background of the place: its sounds and light, kept with the place.
        let bm = await ask("What's the background like?", Prompts.rebuildSound, JSONGrammar.text("background", chars: 100), 50)
        guard bm != nil else { return }
        let soundSaid = ((bm?["background"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
        var sound: String = ""
        if soundSaid.count > 5, !Self.echoesPrompt(soundSaid) { sound = checked([soundSaid], share: 0.5).first ?? "" }
        asked.append("What's the background like? → " + (sound.isEmpty ? "nothing new" : sound))
        commit { now in
            guard !sound.isEmpty, !now.location.isEmpty else { return }
            if now.ambience[now.location.lowercased()] != sound { filed.append("Background: " + sound) }
            now.ambience[now.location.lowercased()] = clip(sound, 110)
        }

        // The room card: the weather outside and the air inside stay as they were drawn, unless
        // the story says outright that they changed ("it stops raining", "the smoke clears").
        if let g = (adventure ?? start).room, !(g.outside.isEmpty && g.inside.isEmpty) {
            let card = "THE ROOM CARD: outside: " + (g.outside.isEmpty ? "(not set)" : g.outside) + "; inside: " + (g.inside.isEmpty ? "(not set)" : g.inside) + ".\n"
            let cq = card + "Does THE STORY or THE PLAYER say outright that the weather outside has changed (the rain stops), or that something huge happened to the room itself (it burns, it floods)? People moving, talking or handing things over never count.\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:"
            let cm = await ask("Did the weather or the air change?", cq, JSONGrammar.one("answer", from: ["yes", "no"]), 24)
            guard cm != nil else { return }
            var changed = ((cm?["answer"] as? String) ?? "") == "yes"
            asked.append("Did the weather or the air change? → " + (changed ? "yes" : "no"))
            if changed {
                let nq = card + "Write the room card as it is now, after the change THE STORY tells. Keep whatever did not change exactly as it was.\nOutput ONLY one JSON object:\n{\"outside\":\"the weather and the world outside, a few words\",\"inside\":\"only the room's smells and ambience, a few words\"}\nThe form:"
                let nm = await ask("What is the room like now?", nq, JSONGrammar.pair("outside", 80, "inside", 80), 50)
                let words: Set<String> = Continuity.wordSet(playerSaid + " " + reply + " " + g.outside + " " + g.inside)
                func fresh(_ k: String, _ old: String) -> String {
                    let v = ((nm?[k] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
                    guard v.count > 3, !Self.echoesPrompt(v), Continuity.grounded(v, in: words, share: 0.5) else { return old }
                    return clip(v, 90)
                }
                let out = fresh("outside", g.outside), ins = fresh("inside", g.inside)
                changed = out != g.outside || ins != g.inside
                asked.append("What is the room like now? → " + (changed ? "outside: " + out + "; inside: " + ins : "no change kept"))
                commit { now in
                    guard changed, var r = now.room else { return }
                    if r.outside != out { filed.append("Outside now: " + out) }
                    if r.inside != ins { filed.append("Inside now: " + ins) }
                    r.outside = out
                    r.inside = ins
                    now.room = r
                }
            }
        }

        // What is still hanging: kept until the story settles it.
        var pq = Prompts.rebuildPending
        if !start.pending.isEmpty { pq = "STILL HANGING:\n" + start.pending.map { "- " + $0 }.joined(separator: "\n") + "\n" + pq }
        let om = await ask("What's still hanging?", pq, JSONGrammar.strings("open", max: 3, chars: 110), 120)
        guard om != nil else { return }
        // Something open is a short sentence about what hasn't happened yet: never a thing, a look
        // or a sound, and never cut off mid-way.
        let hanging = strings(om, "open", cap: 3).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { h in
            if start.pending.contains(where: { Self.similar($0, h) }) { return true }
            let words = h.split(separator: " ").count
            let quoted = h.range(of: #"(?i)\b(we|our|us|me|my|i|i'm|i'll)\b"#, options: .regularExpression) != nil
            if h.count >= 105 || words < 4 || h.hasSuffix("-") || quoted {
                refused.append(h + " (not an open thread)")
                return false
            }
            if start.pending.contains(where: { Self.similar($0, h) }) { return true }
            return !checked([h], share: 0.5).isEmpty
        }
        asked.append("What's still hanging? → " + (hanging.isEmpty ? "nothing" : hanging.joined(separator: "; ")))
        commit { now in
            for h in hanging where !now.pending.contains(where: { Self.similar($0, h) }) { filed.append("Still hanging: " + h) }
            for p in now.pending where !hanging.contains(where: { Self.similar($0, p) }) { filed.append("Settled: " + p) }
            now.pending = hanging
        }

        // How the player is, physically.
        let bodyQ: String = (start.body.isEmpty ? "" : "BEFORE: " + start.body + "\n") + Prompts.rebuildBody
        let bodyM = await ask("How are you, physically?", bodyQ, JSONGrammar.text("body", chars: 60), 30)
        guard bodyM != nil else { return }
        let bodySaid: String = ((bodyM?["body"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
        var body: String = ""
        if bodySaid.count > 3, !Self.echoesPrompt(bodySaid) { body = checked([bodySaid], share: 0.5).first ?? "" }
        asked.append("How are you, physically? → " + (body.isEmpty ? "no change" : body))
        commit { now in
            guard !body.isEmpty, now.body.caseInsensitiveCompare(body) != .orderedSame else { return }
            now.body = clip(body, 70)
            filed.append("You are: " + body)
        }

        // Is the goal closer? What was reached is kept, so the story knows how far along it is.
        let goal: String = start.setup.goal
        if !goal.isEmpty {
            var gq: String = "THE GOAL: " + clip(goal, 240) + "\n"
            if !start.progress.isEmpty { gq += "REACHED SO FAR:\n" + start.progress.map { "- " + $0 }.joined(separator: "\n") + "\n" }
            let gm = await ask("Is the goal closer?", gq + Prompts.rebuildGoal, JSONGrammar.yesNo("closer", then: "how", chars: 120), 60)
            guard gm != nil else { return }
            let closer = ((gm?["closer"] as? String) ?? "") == "yes"
            let howSaid: String = ((gm?["how"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
            var how: String = ""
            if closer, howSaid.count > 8, !Self.echoesPrompt(howSaid), !start.progress.contains(where: { Self.similar($0, howSaid) }) {
                how = checked([howSaid], share: 0.6).first ?? ""
            }
            asked.append("Is the goal closer? → " + (how.isEmpty ? "not this turn" : "yes: " + how))
            commit { now in
                guard !how.isEmpty else { return }
                now.progress.append(clip(how, 130))
                if now.progress.count > 8 { now.progress.removeFirst(now.progress.count - 8) }
                filed.append("Toward the goal: " + how)
            }
        }

        // Did the player get an answer? An unanswered question stays hanging, in code.
        if Self.asks(playerSaid) {
            let am = await ask("Did you get an answer?", Prompts.rebuildAnswered, JSONGrammar.one("answered", from: ["yes", "no"]), 24)
            guard am != nil else { return }
            let answered = ((am?["answered"] as? String) ?? "yes") != "no"
            asked.append("Did you get an answer? → " + (answered ? "yes" : "no"))
            commit { now in
                guard !answered else { return }
                let line: String = "You asked and got no answer yet: " + clip(playerSaid.replacingOccurrences(of: "\n", with: " "), 80)
                guard !now.pending.contains(where: { Self.similar($0, line) }) else { return }
                now.pending = Array((now.pending + [line]).suffix(3))
                filed.append("Still hanging: " + line)
            }
        }

        // Did anyone say their own name? A real one becomes known; a made-up one is put right.
        let saysName = reply.range(of: #"(?i)\b(name is|name's|call me|they call me)\b"#, options: .regularExpression) != nil
            || reply.range(of: #"\bI(?:'m|’m| am) [A-Z][a-z]{2,}"#, options: .regularExpression) != nil
        if saysName, !start.cast.isEmpty {
            let options: [String] = start.cast.map(\.name) + ["nobody"]
            let nm = await ask("Did anyone give their name?", Prompts.rebuildName + "\nTHE LIST: " + options.joined(separator: "; "),
                               JSONGrammar.pickOne("who", from: options, free: "name", chars: 30), 40)
            guard nm != nil else { return }
            let who: String = (nm?["who"] as? String) ?? "nobody"
            let given: String = ((nm?["name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n\""))
            let first: String = given.split(separator: " ").first.map(String.init) ?? ""
            asked.append("Did anyone give their name? → " + (who == "nobody" || first.isEmpty ? "nobody" : who + ", as " + first))
            commit { now in
                guard let i = now.lore.firstIndex(where: { $0.kind == .person && !$0.isPlayer && $0.name.caseInsensitiveCompare(who) == .orderedSame }),
                      first.count > 2, reply.contains(first) else { return }
                let real: String = now.lore[i].name
                let low = first.lowercased()
                if Continuity.wordSet(real).contains(low) {
                    if !now.lore[i].known { now.lore[i].known = true; filed.append(real + " gave their name") }
                    return
                }
                // A name that belongs to nobody in the story was made up: the story's text is put right.
                let taken = Continuity.wordSet(now.playerName).contains(low) || now.lore.contains { Continuity.wordSet($0.name).contains(low) }
                guard !taken, !now.lore[i].byPlayer else { return }
                if let t = now.transcript.firstIndex(where: { $0.id == lastID }) {
                    let swap: String = "\\b" + NSRegularExpression.escapedPattern(for: first) + "\\b"
                    now.transcript[t].text = now.transcript[t].text.replacingOccurrences(of: swap, with: Cards.first(real), options: .regularExpression)
                }
                now.lore[i].known = true
                filed.append("Name put right: " + real + " was called \"" + first + "\"")
            }
        }

        // The file is no longer checked for contradictions after each turn: it cost seconds a
        // turn and flagged compatible lines (rain at the door, rain on the skylight) as slips.
        let slipSaid = ""

        // 6. Anything lasting? Filed under the person it names (the role a nameless story uses
        // becomes the name).
        let late: Adventure = adventure ?? start
        var present: [LoreEntry] = []
        for w in late.whereabouts where w.here != false {
            if let c = Cards.card(for: w, in: late) { present.append(c) }
        }
        let knownFacts = present.flatMap { Cards.facts(about: $0, in: start).suffix(3) } + start.facts.suffix(3)
        var fq = Prompts.rebuildFacts
        // Gated by the check above: what contradicts the premise or the file is a slip, already
        // turned into a correction, and never filed as a lasting fact.
        fq = "THE PREMISE (anything against it is a slip, never a fact): " + clip(Cards.premise(start), 300) + "\n" + (slipSaid.isEmpty ? "" : "A SLIP JUST CAUGHT (never file it): \"" + clip(slipSaid, 120) + "\"\n") + fq
        if !knownFacts.isEmpty { fq = "ALREADY KNOWN:\n" + Array(Set(knownFacts)).prefix(8).map { "- " + clip($0, 140) }.joined(separator: "\n") + "\n" + fq }
        let fm = await ask("Anything lasting?", fq, JSONGrammar.strings("facts", max: 2, chars: 160), 140)
        guard fm != nil else { return }
        let roles = Continuity.hiddenNames(start)
        func named(_ f: String) -> String {
            var f = f
            for r in roles {
                f = f.replacingOccurrences(of: "\"" + r.role + "\"", with: r.name, options: .caseInsensitive)
                if f.lowercased().hasPrefix(r.role.lowercased() + " ") { f = r.name + f.dropFirst(r.role.count) }
            }
            return f.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }
        let people = start.cast.map(\.name) + [start.playerName]
        // A fact is something still true tomorrow. What the player just did is on the timeline
        // already, and what someone is doing this minute is on their card, so neither is a fact.
        let passing = #"^you\s+(\w+ed|left|went|took|sat|saw|shook|gave|told|said|got|made|came|ordered|asked|walked|stepped|entered)\b|\b(is|are)\s+(now\s+)?(watching|looking|smiling|standing|sitting|pouring|wiping|waiting|leaning|talking|staring|glancing|nodding)\b|\b(watches|smiles|stares|glances|nods|pours|wipes)\b"#
        let fresh = checked(strings(fm, "facts", cap: 2).map(named), share: 0.5).compactMap { Continuity.lastingFact($0, people: people) }.filter { f in
            if f.range(of: passing, options: [.regularExpression, .caseInsensitive]) == nil { return true }
            refused.append(f + " (a passing moment, not a lasting fact)")
            return false
        }
        // Nothing comes from a question: "Where in this city are you from tonight?" became
        // "You are from tonight." A fact whose words all sit in a question from the reply or the
        // player is dropped. (The old per-fact "Does it last?" call is gone: the facts question
        // itself now asks only for stated facts, and one call of it once hung for two minutes.)
        let questions: [String] = (reply + " " + playerSaid).components(separatedBy: CharacterSet(charactersIn: ".!\n\"“”"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasSuffix("?") || $0.contains("?") }
        var lasting: [String] = []
        for f in fresh {
            if questions.contains(where: { Continuity.grounded(f, in: Continuity.wordSet($0), share: 0.6) }) {
                refused.append(f + " (from a question, which states nothing)")
                continue
            }
            lasting.append(f)
        }
        let freshKept = lasting
        asked.append("Anything lasting? → " + (freshKept.isEmpty ? "nothing new" : freshKept.joined(separator: " ")))
        commit { now in
            var facts = now.facts
            for f in freshKept where !facts.contains(where: { Self.similar($0, f) }) {
                // Core lore is never overwritten by something said in talk.
                if let i = facts.firstIndex(where: { Self.sameOpening($0, f) }), !now.coreFacts.contains(facts[i]) { facts[i] = clip(f, 200) } else { facts.append(clip(f, 200)) }
                let under = start.cast.first { Cards.mentions($0, in: f) }?.name ?? (f.hasPrefix("You") ? "you" : "the world")
                filed.append("Fact, under \(under): " + f)
                notes.append("Learned: " + f)
            }
            // The store can hold many facts: only the ones a lookup asks for are ever sent.
            // Core lore always stays; what was learned in talk is a rolling window of the last 30.
            let core = Set(now.coreFacts)
            let learned = facts.filter { !core.contains($0) }
            if learned.count > 30 { facts = facts.filter { core.contains($0) } + learned.suffix(30) }
            now.facts = facts
        }
        guard var now = adventure, now.id == start.id else { return }
        if !now.location.isEmpty {
            now.placeSeen[now.location.lowercased()] = now.playerTurns
            if let c = now.clock { now.placeClock[now.location.lowercased()] = c }
        }
        now.checks = Self.worldChanges(from: start, to: now, refused: refused, named: namesThisTurn)
        adventure = now
        library.save(now)
    }

    /// Before the reply, on the map: you walk over when you said you did, and the person you face
    /// gets a plan of their own (stay or get up, where to, what is in reach), checked against the grid.
    /// Returns the lines the storyteller keeps to, and a line for the export.
    private func planMoment(_ a: inout Adventure, input: String, walk: String, to: String, body: String = "", pre: [String: String] = [:]) async -> (brief: [String], log: String) {
        guard var r = a.room, let me0 = r.player else { return ([], "") }
        var log: [String] = []
        // 1. You walk over: the look heard a move toward someone who is more than an arm's length away.
        let faced = Fovea.facing(a)
        let target = faced.first { $0.name.caseInsensitiveCompare(to) == .orderedSame } ?? faced.first
        // Already there ("at the bar" while on a stool at the bar): no walk, and you stay seated.
        func already(_ z: Zone) -> Bool {
            let c = Placer.centroid(Placer.cells(z, in: r, forPeople: true))
            return hypot(c.0 - me0.centre.x, c.1 - me0.centre.y) <= 1.6
        }
        if !walk.isEmpty, let z = Adventure.zone(from: walk, in: r), already(z) {
            log.append("you are already " + z.text)
        } else if !walk.isEmpty, let z = Adventure.zone(from: walk, in: r), !walk.lowercased().contains(Cards.first(target?.name ?? "\u{0}").lowercased()) {
            // "I sit on the warm stool": you go to the thing you named, and face whoever you turned to.
            let note = Placer.placePerson(&r, me0, zone: z)
            if let w = target { Placer.turn(&r, me0.id, toward: w.name) }
            r.log.append("move: you → " + z.text + (note.isEmpty ? "" : " (" + note + ")"))
            a.spot = z.text
            log.append("you go " + z.text)
        } else if !walk.isEmpty, let w = target, let t = r.named(w.name), t.isPerson, RoomGrid.distance(me0, t) > 1.6 {
            let note = Placer.placePerson(&r, me0, zone: .beside(w.name))
            Placer.turn(&r, me0.id, toward: w.name)
            r.log.append("move: you → beside " + w.name + (note.isEmpty ? "" : " (" + note + ")"))
            a.spot = "beside " + w.name
            log.append("you walk over beside " + w.name)
        }
        if !walk.isEmpty { placedByPlan = true }
        // 1b. Sitting down: the model says whether the player sits, then on which seat near the person
        // they turned to (or a stool brought over), so they end up seated, never left standing by it.
        if let meNow = r.player, meNow.on == nil, !(walk + " " + body).trimmingCharacters(in: .whitespaces).isEmpty {
            let sq = "THE PLAYER JUST SAID: \"" + clip(input, 200) + "\"" + (body.isEmpty ? "" : " (their body: " + clip(body, 60) + ")") + "\nQUESTION: Does the player sit down this moment?\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:"
            let sitAsked = Date()
            let sraw = (try? await llm.complete(system: nil, prompt: sq, options: .init(maxTokens: 24, temperature: 0.1, repetitionPenalty: 1.0, grammar: JSONGrammar.one("answer", from: ["yes", "no"])))) ?? ""
            noteQ("plan", "Do you sit down?", sraw, since: sitAsked)
            if ((JSONExtract.object(sraw)?["answer"] as? String) ?? "").lowercased().hasPrefix("y"), let me1 = r.player {
                let anchor: Thing? = target.flatMap { r.named($0.name) }
                let taken = Set(r.people.compactMap(\.on))
                let near = anchor ?? me1
                let seats = r.objects.filter { Rules.seats.contains($0.icon) && !taken.contains($0.id) }
                    .sorted { RoomGrid.distance($0, near) < RoomGrid.distance($1, near) }.prefix(4)
                var opts: [String] = seats.map { s in "the " + Fovea.bare(s.name) + String(format: ", %.0f m from ", RoomGrid.distance(s, near)) + (anchor.map { Cards.first($0.name) } ?? "you") }
                let bring = anchor.map { "bring a stool over beside " + Cards.first($0.name) }
                if let b = bring { opts.append(b) }
                if !opts.isEmpty {
                    let cq = "The player sits down" + (anchor.map { " next to " + $0.name } ?? "") + ". Which seat do they take? The closest free one beside the person is the usual choice.\nCHOICES: " + opts.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"answer\":\"one of CHOICES\"}\nThe form:"
                    let craw = (try? await llm.complete(system: nil, prompt: cq, options: .init(maxTokens: 40, temperature: 0.1, repetitionPenalty: 1.0, grammar: JSONGrammar.one("answer", from: opts)))) ?? ""
                    noteQ("plan", "Which seat do you take?", craw, since: Date())
                    let said = (JSONExtract.object(craw)?["answer"] as? String) ?? opts[0]
                    if let i = opts.firstIndex(of: said), i < seats.count {
                        let seat = Array(seats)[i]
                        // By the seat itself, not its name: several can be called "stool".
                        if let k = r.index(me1.id) { r.things[k].x = seat.x; r.things[k].y = seat.y; r.things[k].on = seat.id }
                        r.log.append("move: you → on " + Fovea.bare(seat.name))
                        a.spot = "on " + Fovea.bare(seat.name)
                    } else if let p = anchor {
                        let stool = Thing(kind: .object, name: "stool", icon: "stool")
                        if Placer.place(&r, stool, zone: .beside(p.name)).placed, let placed = r.objects.last(where: { $0.icon == "stool" }) {
                            if let i = r.index(me1.id) { r.things[i].x = placed.x; r.things[i].y = placed.y; r.things[i].on = placed.id }
                            r.log.append("move: you bring a stool over beside " + p.name + " and sit")
                            a.spot = "on a stool beside " + p.name
                        }
                    }
                    if let w = target { Placer.turn(&r, me1.id, toward: w.name) }
                    log.append("you sit: " + a.spot)
                    placedByPlan = true
                }
            }
        }
        a.room = r
        // 2. The person you face: what they do, given where everyone is.
        guard let w = target, let p = r.named(w.name), p.isPerson else { return ([], log.joined(separator: "; ")) }
        let who = w.name
        focusThisTurn = who
        let first = Cards.first(who)
        let near: [Thing] = r.objects.filter { $0.icon != "rug" && RoomGrid.distance($0, p) < 2.2 }
            .sorted { RoomGrid.distance($0, p) < RoomGrid.distance($1, p) }
        let reach: [String] = Array(Array(Set(p.holding + near.map { Fovea.bare($0.name) })).sorted().prefix(8))
        let places: [String] = Zone.menu(r, people: true)
        // A short chain of questions, the way a person thinks before acting: what am I doing, what
        // did they just do, do I want to engage, do I need to move, do I need something, is it here.
        var ctx = "You think through one moment of an interactive story as " + who + ", before it is written, so it fits the room.\n"
        ctx += Fovea.roomView(a).joined(separator: "\n") + "\n"
        ctx += who.uppercased() + " NOW: " + (Fovea.gridSpot(a, who) ?? "in the room") + (w.doing.isEmpty ? "" : ", " + clip(w.doing, 80)) + ".\n"
        ctx += "WITHIN " + first.uppercased() + "'S REACH: " + (reach.isEmpty ? "nothing" : reach.joined(separator: "; ")) + "\n"
        ctx += "THE PLAYER JUST SAID: " + clip(input, 300) + "\n\nQUESTION: "
        var chain: [String] = []
        func ask(_ label: String, _ q: String, _ grammar: String, _ tokens: Int) async -> [String: Any] {
            guard !Task.isCancelled else { return [:] }
            stage = label
            let q0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: ctx + q, options: .init(maxTokens: tokens, temperature: 0.2, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
            noteQ("plan", label, raw, since: q0)
            return JSONExtract.object(raw) ?? Self.salvageJSON(raw)
        }
        // 1-4 in one form (four short answers about one person and one moment, which this model
        // answers as well together as apart, in a third of the time): what did the player just
        // do, to them; would they rather avoid the player; do they truly need to get up; do they
        // need something in their hands.
        let pq = "Answer five short things about " + who + " in this moment.\n"
            + "did: in a few words, what did the player just do or ask, as " + who + " sees it?\n"
            + "avoids: would " + who + " rather avoid the player right now, ignoring them or turning away? Only someone upset with the player, busy with an emergency, or walking off from them says yes.\n"
            + "gets_up: does " + who + " truly need to get up and go somewhere else in the room? People answering someone who came up to them stay where they are and turn to them, so usually no.\n"
            + "needs: does " + who + " need to pick up or use something for this, like a pencil, a glass or a cloth? Name exactly what the player asked for (they order a whiskey: a bottle of whiskey and a glass), not something else already out. A few words, or empty.\n"
            + "answer_size: how much does what the player said deserve back from " + who + "? a few words (a greeting, a yes or no, a name); a sentence or two (a plain question); a short story (a question about their life, work, home, past or how something feels, like 'what is it like living in a lighthouse?': a few sentences with real, specific detail).\n"
            + "Output ONLY one JSON object:\n{\"did\":\"a few words\",\"avoids\":\"yes or no\",\"gets_up\":\"yes or no\",\"needs\":\"a few words, or empty\",\"answer_size\":\"a few words, a sentence or two, or a short story\"}\nThe form:"
        // The look form already answered these in the same call; the separate question is only
        // asked when it didn't (no usable reading).
        var pm: [String: Any] = [:]
        if pre["answer_size"] != nil {
            for (k, v) in pre { pm[k] = v }
        } else {
            pm = await ask("What did you do, and what does " + first + " do?", pq, JSONGrammar.planForm(), 110)
        }
        func pv(_ k: String) -> String {
            let v = ((pm[k] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
            if ["empty", "none", "nothing", "n/a", "no"].contains(v.lowercased()) && k == "needs" { return "" }
            return Self.echoesPrompt(v) ? "" : v
        }
        let theyDid = pv("did")
        if !theyDid.isEmpty { chain.append("you: " + theyDid); didThisTurn = theyDid }
        // A slip on a yes or no leaves them engaging and staying put, as most people would.
        let avoids = pv("avoids").lowercased().hasPrefix("y")
        let engage = !avoids
        chain.append(engage ? "engages" : "would rather not engage")
        var moved: Zone? = nil
        let getsUp = pv("gets_up").lowercased().hasPrefix("y")
        if getsUp {
            let m = await ask("Where does " + first + " go?", "Where does " + who + " go?\nPLACES: " + places.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"where\":\"one of PLACES\"}\nThe form:", JSONGrammar.one("where", from: places), 30)
            let said = (m["where"] as? String) ?? ""
            // The code checks the move against the map: a real place with room for them.
            if let z = Zone.parse(said), places.contains(said) {
                var test = r
                let note = Placer.placePerson(&test, p, zone: z)
                if note.isEmpty, let after = test.named(who), RoomGrid.distance(after, p) >= 1 {
                    r = test
                    if let i = r.index(p.id) { r.things[i].pastMoves = [z.text] + Array(p.pastMoves.prefix(7)) }
                    r.log.append("plan: " + who + " gets up → " + z.text)
                    moved = z
                } else {
                    r.log.append("plan: " + who + " stays (no room " + z.text + ")")
                }
            }
        }
        chain.append(moved.map { "gets up → " + $0.text } ?? "stays put")
        if engage { Placer.turn(&r, p.id, toward: "you") }
        // 4. Do they need something in their hands? Then, is it within reach on the map?
        var reached = ""
        var missing = ""
        let need = pv("needs")
        if !need.isEmpty, !["nothing", "none", "no"].contains(need.lowercased()) {
            // The model says whether something in reach is that very thing: a shared word isn't
            // enough ("amber liquid in a glass" is not the vodka the player asked for).
            if !reach.isEmpty {
                let opts = reach + ["none of these"]
                let m = await ask("Is a " + clip(need, 30) + " within reach?", first + " wants " + need + ". Which of WITHIN REACH is that very thing, if any? Something merely like it (another drink, another tool) is none of these.\nCHOICES: " + opts.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"use\":\"one of CHOICES\"}\nThe form:", JSONGrammar.one("use", from: opts), 30)
                let use = (m["use"] as? String) ?? ""
                if reach.contains(use) { reached = use } else { missing = need }
            } else {
                missing = need
            }
            chain.append(reached.isEmpty ? need + ": not within reach" : "uses " + reached)
        }
        a.room = r
        plannedThisTurn[who] = moved == nil
        var line = "PLAN FOR " + who + " (keep to it): " + (engage ? "they engage with the player" : "they would rather keep to themselves") + "."
        if let z = moved {
            line += " They get up and go " + z.text + ": show them getting up and crossing the room."
        } else {
            // Where they are is said once, in the scene; the plan doesn't say it again.
            line += " They stay where they are" + (engage ? " and turn to the player" : "") + "."
        }
        if !reached.isEmpty { line += " They use " + reached + ", which is within reach." }
        if !missing.isEmpty { line += " The " + missing + " isn't within reach: if their work keeps it close by (a bartender's bottles, a tailor's thread), they fetch it; otherwise they do without." }
        if physicalThisTurn || !reached.isEmpty || !missing.isEmpty {
            line += reach.isEmpty ? " Nothing else is within their reach." : " Within their reach: " + reach.joined(separator: ", ") + "; anything else is out of reach."
        } else if !p.holding.isEmpty {
            line += " In their hands: " + p.holding.joined(separator: ", ") + "."
        }
        // How much they give back, as the model judged the ask: a story when it deserves one.
        let size = pv("answer_size")
        answerSizeThisTurn = engage ? size : ""
        if engage, !size.isEmpty {
            chain.append("answers with " + size)
            switch size {
            case "a short story": line += " What the player said deserves a short story back: they answer in a few sentences, with real, specific detail from their own life, the way people do when asked something they know well."
            case "a few words": line += " They answer briefly, in one natural spoken sentence, never a single word."
            default: line += " They answer in a sentence or two."
            }
        }
        // A conversation goes both ways: now and then the person asks the player something of
        // their own. The look form says when it fits (after the player shares something of theirs).
        // Never on a turn where something is to be done (sitting down to eat, a drink poured): they
        // do it. After a direct question they answer it, and only ask back once three turns have
        // gone by; otherwise two. Counted in code: a question mark in their own story is not a
        // question to the player.
        let since = a.playerTurns - (askedBackAt[a.id] ?? 0)
        let playerAsked = Self.asks(input)
        let askBack = engage && !physicalThisTurn
            && ((pre["asks_back"] == "yes" && !playerAsked) || since >= (playerAsked ? 3 : 2))
        if askBack {
            let knows = (a.knows[who.lowercased()] ?? []).suffix(3)
            line += " After answering, they ask the player one question of their own, in their own way and in quotes, the last thing they say, about the player or about what the player just said."
                + (knows.isEmpty ? "" : " They already know: " + knows.joined(separator: "; ") + ", so they ask something else.")
            chain.append("asks something back")
            askedBackAt[a.id] = a.playerTurns
        }
        log.append(who + ": " + chain.joined(separator: " · "))
        return ([line], log.joined(separator: "; "))
    }

    /// Updates the turn guide's snapshot with what was looked up before the reply.
    /// After a foveated turn: the rebuild questions about the player and the room that the moment
    /// didn't touch. A move, something taken or put down, or a yes from the gate keeps a question.
    private func foveaSkip(_ label: String, wanted: Set<String>, start: Adventure, playerSaid: String) -> Bool {
        let moved = (adventure?.location ?? start.location).caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
        // A turn spent with one person, staying put: only the space between you and them is looked
        // at again. Which place you are in, its background and the file's contradictions stay as they were.
        if !focusThisTurn.isEmpty, stayingThisTurn, !moved,
           ["Where are you now?", "What's the background like?", "Does anything contradict the file?"].contains(label) {
            return true
        }
        // Only talking to one person: nothing about the room, the others or the objects in it is
        // asked again. Just what passed between the two of you.
        if talkThisTurn, !moved, !walkedThisTurn,
           ["Where are you now?", "Who is with you?", "Who does the moment show?", "What is around?", "What's the background like?",
            "Does anything contradict the file?", "Did the weather or the air change?", "What is the room like now?",
            "Where are you in the room?", "How are you, physically?", "Is the goal closer?"].contains(label) {
            return true
        }
        switch label {
        case "What do you have?":
            return !wanted.contains("have") && putDownThisTurn.isEmpty && Self.pickedUp(playerSaid) == nil
        case "What is around?":
            return !wanted.contains("around") && !moved && !walkedThisTurn
        case "What's the background like?":
            let known = !(start.ambience[start.location.lowercased()] ?? "").isEmpty
            return known && !moved && !wanted.contains("sound")
        case "Where are you in the room?":
            if placedByPlan { return true }
            return !wanted.contains("spot") && !moved && !walkedThisTurn
        case "How are you, physically?":
            return !wanted.contains("body")
        default:
            return false
        }
    }

    private func recordFrame(looked: [String]) {
        guard var a = adventure else { return }
        Self.updateFrame(&a, looked: looked, asked: [], notes: catchUpNotes, steps: [])
        adventure = a
    }

    /// "my hotel room" as a place name: "Your hotel room".
    /// A person the story brings in who has no card yet gets one, and is placed in the scene.
    /// Returns the card's name, or nil when the name is no good or already someone's.
    /// Someone known only by what they are: "The police inspector" from "police inspector
    /// looking for a thief". Nil when there is nothing to go on.
    static func roleName(_ role: String) -> String? {
        let stop: Set<String> = ["looking", "who", "with", "from", "for", "that", "in", "at", "to", "and", "of", "searching", "asking", "wearing", "holding"]
        let head = role.lowercased().replacingOccurrences(of: #"^(the|a|an)\s+"#, with: "", options: .regularExpression)
            .split(separator: " ").map(String.init).prefix { !stop.contains($0) }.prefix(3)
        return head.isEmpty ? nil : "The " + head.joined(separator: " ")
    }

    private func addNewcomer(_ a: inout Adventure, name raw: String, role rawRole: String, about text: String, engaged: Bool) -> String? {
        let trim = CharacterSet(charactersIn: " .,\n\"'")
        var name = raw.trimmingCharacters(in: trim)
        let role = rawRole.trimmingCharacters(in: trim)
        for art in ["the ", "a ", "an ", "her ", "his ", "their ", "your ", "my "] where name.lowercased().hasPrefix(art) && name.count > art.count + 2 {
            name = "The " + name.dropFirst(art.count)
            break
        }
        guard name.count > 2, name.count <= 40, !Self.echoesPrompt(name), a.cast.count < 10 else { return nil }
        let titles: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "the", "sir", "madam"]
        let words = Continuity.wordSet(name).filter { !titles.contains($0) && $0.count > 2 }
        // Every word of the name is in the text ("a girl selling newspapers" grounds "the newspaper
        // seller": a shared stem of four letters is enough).
        let textWords = Continuity.wordSet(text)
        func grounded(_ w: String) -> Bool {
            textWords.contains(w) || textWords.contains { t in t.count >= 4 && w.count >= 4 && t.prefix(4) == w.prefix(4) }
        }
        guard !words.isEmpty, words.allSatisfy(grounded) else { return nil }
        // Not the player, and not someone who already has a card (by name or by role). Sharing one
        // word is not the same person: "the old man" is not "the old barber", "the young man" is
        // not "the young apprentice". Only a name wholly inside theirs is.
        if !words.isDisjoint(with: Continuity.wordSet(a.playerName)) { return nil }
        for c in a.cast {
            let theirs = Continuity.wordSet(c.name + " " + c.role).filter { !titles.contains($0) && $0.count > 2 }
            if words.isSubset(of: theirs) { return nil }
        }
        let line: String = PresenceFilter.sentences(text).first(where: { s in words.contains { s.lowercased().contains($0) } }) ?? ""
        var e = LoreEntry(name: name, kind: .person, desc: clip(line.trimmingCharacters(in: .whitespacesAndNewlines), 200), role: clip(role, 60), known: true)
        e.updatedTurn = a.playerTurns
        _ = addLore(&a, e)
        if !a.whereabouts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            a.whereabouts.append(Whereabout(name: name, at: a.location.isEmpty ? (a.room?.name ?? "here") : a.location, here: true, engaged: engaged))
        }
        // On the map too: they have just come in, so they stand by the door, facing the player.
        // (Without this, someone new had a card but never a place in the room.)
        // Between places (the place not settled yet), the room the player still stands in counts.
        if var r = a.room, a.location.isEmpty || r.name.caseInsensitiveCompare(a.location) == .orderedSame, r.named(name) == nil {
            let p = Thing(kind: .person, name: name)
            let note = Placer.placePerson(&r, p, zone: r.doors.isEmpty ? .anywhere : .doorCorner)
            Placer.turn(&r, p.id, toward: "you")
            r.log.append("enter: " + name + " by the door" + (note.isEmpty ? "" : " (" + note + ")"))
            a.room = r
        }
        return name
    }

    /// The storyteller sometimes invents a name for the person the player is with ("Sarah," she
    /// replies) instead of the one on their card. When the reply has that person give a name that
    /// belongs to nobody in the story, it is swapped for their real one, and the name counts as said.
    /// A card's new name, carried everywhere the old one was used.
    static func renameCard(_ a: inout Adventure, id: UUID, to name: String) {
        guard let i = a.lore.firstIndex(where: { $0.id == id }) else { return }
        let old = a.lore[i].name
        let oldKey = old.lowercased(), newKey = name.lowercased()
        if a.lore[i].role.isEmpty { a.lore[i].role = old.replacingOccurrences(of: "The ", with: "the ") }
        a.lore[i].name = name
        a.lore[i].known = true
        for j in a.whereabouts.indices where a.whereabouts[j].name.caseInsensitiveCompare(old) == .orderedSame { a.whereabouts[j].name = name }
        if let v = a.wants.removeValue(forKey: oldKey) { a.wants[newKey] = v }
        if let v = a.knows.removeValue(forKey: oldKey) { a.knows[newKey] = v }
        if let v = a.feelings.removeValue(forKey: oldKey) { a.feelings[newKey] = v }
        a.facts = a.facts.map { $0.hasPrefix(old + " ") ? name + String($0.dropFirst(old.count)) : $0 }
    }

    /// Whether Apple's on-device language tagger reads this word in the reply as a person's name.
    static func isPersonalName(_ word: String, in text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, text[range].split(separator: " ").contains(where: { $0 == word }) { found = true; return false }
            return true
        }
        return found
    }

    static func fixMadeUpName(_ a: inout Adventure, reply: String, namey: Bool, playerSaid: String = "") -> (reply: String, note: String, name: String)? {
        let me = Cards.first(a.playerName).lowercased()
        let facing: [LoreEntry] = a.whereabouts.filter { $0.here != false && $0.engaged == true && Cards.first($0.name).lowercased() != me }
            .compactMap { Cards.card(for: $0, in: a) }.filter { !$0.isPlayer && !$0.byPlayer }
        guard facing.count == 1, let c = facing.first else { return nil }
        var known: Set<String> = Continuity.wordSet(a.playerName)
        for e in a.lore { known.formUnion(Continuity.wordSet(e.name)) }
        let notNames: Set<String> = ["yes", "no", "well", "sure", "hello", "fine", "okay", "good", "please", "thanks", "sorry", "maybe", "perhaps",
                                     "indeed", "always", "never", "soon", "here", "there", "tomorrow", "tonight", "listen", "look", "wait", "come",
                                     "stay", "nothing", "everything", "really", "right", "true", "exactly", "welcome", "cheers", "not", "just",
                                     "tired", "glad", "happy", "afraid", "certain", "new", "from", "going", "trying", "waiting", "working"]
        var patterns: [String] = [#"(?:[Mm]y name is|[Mm]y name's|[Nn]ame's|[Cc]all me|[Tt]hey call me)\s+([A-Z][a-z]{2,})"#]
        if namey {
            patterns.append(#"["“]([A-Z][a-z]{2,})[,.!]?["”],?\s+(?:she|he|they)\s+(?:replies|says|answers|offers|tells|murmurs|whispers)"#)
            patterns.append(#"\bI(?:'m|’m| am)\s+([A-Z][a-z]{2,})[,.!"”]"#)
        }
        let ns = reply as NSString
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: reply, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { continue }
            let said = ns.substring(with: m.range(at: 1))
            let low = said.lowercased()
            if known.contains(low) || notNames.contains(low) { continue }
            // The player's own name, as they just gave it ("I introduced myself as Simon"), is theirs.
            if Continuity.wordSet(playerSaid).contains(low) { continue }
            // Only a word the language tagger reads as a person's name ("Now," he says is not one).
            if !Self.isPersonalName(said, in: reply) { continue }
            // Someone known only by a description ("The young man") who gives a name has told
            // the player who they are: the card takes the name.
            if c.name.hasPrefix("The ") {
                renameCard(&a, id: c.id, to: said)
                return (reply, c.name + " gave a name: " + said, said)
            }
            let real = Cards.first(c.name)
            let swap = "\\b" + NSRegularExpression.escapedPattern(for: said) + "\\b"
            let fixed = reply.replacingOccurrences(of: swap, with: real, options: .regularExpression)
            if let i = a.lore.firstIndex(where: { $0.id == c.id }) { a.lore[i].known = true }
            return (fixed, "the storyteller called " + c.name + " \"" + said + "\"; put right in code", c.name)
        }
        return nil
    }

    /// Whether a reply shows someone actually there (arriving, speaking, doing something), not
    /// only waited for or talked about.
    static func showsArriving(_ c: LoreEntry, in reply: String) -> Bool {
        let acts = #"(?i)\b(arrives?|enters?|walks? (in|over|up)|comes? (in|through|over|up)|steps? (in|inside|through|up)|appears?|returns?|joins?|says|asks|replies|nods|looks|smiles|sets|stands|sits|pours|turns)\b"#
        let waits = #"(?i)\b(wait(s|ing|ed)? for|until|elsewhere|not here|talk(s|ing|ed)? about|think(s|ing)? of|mention(s|ed)?)\b"#
        for s in PresenceFilter.sentences(reply) where Cards.mentions(c, in: s) {
            if s.range(of: waits, options: .regularExpression) != nil { continue }
            if s.range(of: acts, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// The newcomer a message brings in by description ("a young man with a violin case comes
    /// in"): a name for their card ("The young man") and the rest as their role.
    static func describedArrival(_ input: String) -> (name: String, role: String)? {
        let pattern = #"(?i)\b(?:a|an|another)\s+((?:[a-z]+\s+){0,2}?(?:man|woman|stranger|boy|girl|waiter|waitress|guard|clerk|doorman|driver|officer|policeman|musician|singer|pianist|violinist|gentleman|lady|fellow|sailor|couple))\b([^.?!]{0,40}?)\s+(?:comes?|walks?|steps?|wanders?|stumbles?|bursts?|hurries?|enters?|arrives?|appears?|shows? up)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: input, range: NSRange(location: 0, length: (input as NSString).length)), m.numberOfRanges > 2 else { return nil }
        let who = (input as NSString).substring(with: m.range(at: 1)).lowercased()
        let rest = (input as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        let role = (who + (rest.isEmpty ? "" : " " + rest)).trimmingCharacters(in: .whitespaces)
        return ("The " + who, role)
    }

    /// What someone knows about the player: the name always stays, then the newest seven.
    /// What someone knows about the player, as keyed slots: one line per kind of detail (your
    /// name, where you are from, your work…), the newest of each kind replacing the older one,
    /// each kept short, and at most five in all.
    static func keepKnown(_ known: [String]) -> [String] {
        func slot(_ s: String) -> String {
            let t = s.lowercased().replacingOccurrences(of: #"^you (said|told \w+) (that )?"#, with: "", options: .regularExpression)
            return t.split(separator: " ").prefix(3).joined(separator: " ")
        }
        var out: [String] = []
        for k in known.reversed() {
            let short = k.split(separator: " ").prefix(12).joined(separator: " ")
            guard !out.contains(where: { slot($0) == slot(short) }) else { continue }
            out.insert(short, at: 0)
        }
        let names = out.filter { $0.hasPrefix("your name is ") }.suffix(1)
        let rest = out.filter { !$0.hasPrefix("your name is ") }.suffix(5 - names.count)
        return Array(names) + Array(rest)
    }

    /// "I tell them I am a salesman from Chicago" → "you said you are a salesman from Chicago".
    static func toldAboutSelf(_ input: String) -> (what: String, all: Bool)? {
        let pattern = #"(?i)\bI (?:tell|told|explain to|admit to|confess to) (them|her|him|everyone|everybody|the [a-z]+|[A-Z][a-z]+)(?: both| all)?,? (?:that |the truth[.:,]? )?((?:I|my)\b[^.?!]{6,160})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: input, range: NSRange(location: 0, length: (input as NSString).length)), m.numberOfRanges > 2 else { return nil }
        let who = (input as NSString).substring(with: m.range(at: 1)).lowercased()
        var what = " " + (input as NSString).substring(with: m.range(at: 2)) + " "
        let swaps: [(String, String)] = [(#"\bI am\b"#, "you are"), (#"\bI'm\b"#, "you are"), (#"\bI was\b"#, "you were"), (#"\bI have\b"#, "you have"),
                                         (#"\bI've\b"#, "you have"), (#"\bI\b"#, "you"), (#"(?i)\bmy\b"#, "your"), (#"\bme\b"#, "you"), (#"(?i)\bmine\b"#, "yours"), (#"(?i)\bmyself\b"#, "yourself")]
        for (from, to) in swaps { what = what.replacingOccurrences(of: from, with: to, options: .regularExpression) }
        what = what.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        guard what.count > 8 else { return nil }
        let all = ["them", "everyone", "everybody"].contains(who)
        return ("you said " + what, all)
    }

    /// The plain word for a new place the message goes to ("the street" in "I go out to the
    /// street to look at the rain"), when it is not a place on the map or something in this one.
    static func newPlaceWord(_ input: String, in a: Adventure) -> String? {
        let pattern = #"(?i)\b(?:go|goes|step|steps|walk|walks|head|heads|run|runs|hurry|hurries|wander|wanders|slip|slips)\s+(?:out\s+|outside\s+|back\s+|over\s+|down\s+|up\s+)?(?:to|into|onto|toward|towards)\s+the\s+([a-z]{4,}(?:\s+(?:shop|store|house|room|hall|street|station|park|market|garden|yard|office|cafe|hotel|lobby|stairs))?)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: input, range: NSRange(location: 0, length: (input as NSString).length)), m.numberOfRanges > 1 else { return nil }
        let phrase = (input as NSString).substring(with: m.range(at: 1)).lowercased()
        let noun = String(phrase.split(separator: " ").last ?? "")
        if Continuity.wordSet(a.setup.place + " " + a.setup.describe + " " + a.setup.world).contains(noun) { return nil }
        let dull: Set<String> = ["door", "doorway", "window", "bar", "counter", "table", "stool", "booth", "corner", "wall", "gramophone", "record", "fire", "fireplace",
                                 "piano", "stage", "bartender", "woman", "others", "front", "back", "side", "edge", "middle", "rain"]
        if dull.contains(noun) { return nil }
        let here = Continuity.wordSet(a.location + " " + (a.placeThings[a.location.lowercased()] ?? []).joined(separator: " "))
        if here.contains(noun) { return nil }
        for p in a.lore.filter({ $0.kind == .place }).map(\.name) + a.places where Continuity.wordSet(p).contains(noun) { return nil }
        return phrase
    }

    /// A place on the map the message goes to by a plain word for it ("back to the bar" for The
    /// Velvet Rose, "my old stool", "the speakeasy"), and where in the message that word is.
    static func placeMeant(_ input: String, in a: Adventure) -> (place: String, at: Int)? {
        let pattern = #"(?i)\b(?:go|goes|going|head|heads|walk|walks|return|returns|come|comes|step|steps|get|gets|climb|climbs|carry|carries|bring|brings|sit|sits|take|takes|run|runs|hurry|put|puts|set|sets|back)\b[^.?!;]{0,40}?\b(?:to|into|inside|in|at|on|behind)\s+(?:the|my|his|her|their)\s+(?:old\s+|first\s+|same\s+|own\s+)?([a-z]{3,})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = input as NSString
        let dull: Set<String> = ["way", "door", "moment", "while", "rain", "air", "back", "room", "place", "floor", "wall", "hand", "pocket", "coat", "table", "side", "end", "front", "rest", "others", "woman", "man", "bartender", "two"]
        let cue = input.range(of: #"(?i)\b(back|return|returns|again|old|same)\b"#, options: .regularExpression) != nil
        let here = a.location
        let home: String = a.frames.first?.place ?? ""
        let premise = Continuity.wordSet(a.setup.place + " " + a.setup.describe)
        func words(of place: String) -> (name: Set<String>, rest: Set<String>) {
            let card = a.lore.first { $0.kind == .place && $0.name.caseInsensitiveCompare(place) == .orderedSame }
            let things: [String] = a.placeThings[place.lowercased()] ?? []
            return (Continuity.wordSet(place), Continuity.wordSet((card?.desc ?? "") + " " + things.joined(separator: " ")))
        }
        let mine = words(of: here)
        var seen = Set<String>()
        var places: [String] = []
        for p in a.lore.filter({ $0.kind == .place }).map(\.name) + a.places where p.caseInsensitiveCompare(here) != .orderedSame && seen.insert(p.lowercased()).inserted {
            places.append(p)
        }
        var best: (place: String, at: Int)? = nil
        for m in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            let noun = ns.substring(with: m.range(at: 1)).lowercased()
            if dull.contains(noun) || mine.name.contains(noun) { continue }
            // "My stool", "my old seat": the seat the player had where the story began, never a
            // place that only happens to have a stool too. Already there, it is a move to nowhere.
            let seats: Set<String> = ["stool", "seat", "chair", "booth", "barstool", "spot"]
            if seats.contains(noun) {
                guard cue, !home.isEmpty, home.caseInsensitiveCompare(here) != .orderedSame,
                      let h = places.first(where: { $0.caseInsensitiveCompare(home) == .orderedSame }) else { continue }
                if best == nil || m.range(at: 1).location > best!.at { best = (h, m.range(at: 1).location) }
                continue
            }
            var found: String? = places.first { words(of: $0).name.contains(noun) }
            if found == nil, !mine.rest.contains(noun) {
                let isHome: (String) -> Bool = { $0.caseInsensitiveCompare(home) == .orderedSame }
                if let h = places.first(where: isHome), premise.contains(noun) {
                    found = h
                } else if cue {
                    let fits = places.filter { words(of: $0).rest.contains(noun) }
                    if fits.count == 1 { found = fits[0] }
                }
            }
            if let f = found, best == nil || m.range(at: 1).location > best!.at { best = (f, m.range(at: 1).location) }
        }
        return best
    }

    static func goesTo(_ place: String, in input: String) -> Bool {
        let skip: Set<String> = ["the", "a", "an", "of", "and", "at", "in", "on"]
        guard let last = place.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter({ !skip.contains($0) }).last,
              last.count >= 3, Continuity.names(place: place, in: input) else { return false }
        let going = #"(go|goes|going|went|head|heads|headed|heading|walk|walks|walked|return|returns|returned|step|steps|stepped|enter|enters|entered|come|comes|came|duck|ducks|ducked|run|ran|hurry|hurried|back)"#
        let pattern = "(?i)\\b" + going + "\\b(\\W+\\w+){0,5}?\\W+" + NSRegularExpression.escapedPattern(for: last) + "s?\\b"
        return input.range(of: pattern, options: .regularExpression) != nil
    }

    static func ownPlace(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'"))
        for p in ["my ", "My "] where s.hasPrefix(p) { s = "your " + s.dropFirst(p.count) }
        return s.prefix(1).uppercased() + String(s.dropFirst())
    }

    /// Builds a place the player arrives in: one short call writes its description and a few
    /// things in it, true to the premise. Returns a short summary for the turn guide.
    private func buildPlace(_ a: inout Adventure, hint: String = "") async -> String {
        guard let i = a.lore.firstIndex(where: { $0.kind == .place && $0.name.caseInsensitiveCompare(a.location) == .orderedSame }) else { return "" }
        var prompt = "You build places for an audio story."
        let premise = Cards.premise(a)
        if !premise.isEmpty { prompt += "\n\nTHE STORY: " + clip(premise, 500) }
        if !a.storyTime.isEmpty { prompt += "\nTIME: " + a.storyTime }
        let ground = a.facts.prefix(8).filter { f in !a.cast.contains { Cards.mentions($0, in: f) } && !f.hasPrefix("You") }.prefix(2)
        if !ground.isEmpty { prompt += "\nTHE WORLD: " + ground.joined(separator: " ") }
        prompt += "\nTHE PLACE: " + a.location
        if !placeBeforeTurn.isEmpty, placeBeforeTurn.caseInsensitiveCompare(a.location) != .orderedSame {
            // The place just left is somewhere else: none of it is here.
            let left = (a.placeThings[placeBeforeTurn.lowercased()] ?? []).prefix(5).joined(separator: "; ")
            prompt += "\nNOT HERE: " + placeBeforeTurn + (left.isEmpty ? "" : " and its things (" + left + ")") + ". The player has left it; describe only " + a.location + "."
        }
        if !hint.isEmpty { prompt += "\nKNOWN ABOUT IT (keep to this): " + clip(hint, 400) }
        prompt += "\n\n" + Prompts.buildPlace
        let q0 = Date()
        let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                           options: .init(maxTokens: 200, temperature: 0.6, repetitionPenalty: 1.1, grammar: JSONGrammar.place))) ?? ""
        noteQ("place", "Describe the place", raw, since: q0)
        let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
        let desc = ((m["desc"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let offered: [String] = ((m["things"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 3 && !Self.echoesPrompt($0) && !Self.brokenEntry($0) }
        guard desc.count > 20, !Self.echoesPrompt(desc) else { return "" }
        // A description of the place just left is not this place.
        if !placeBeforeTurn.isEmpty, placeBeforeTurn.caseInsensitiveCompare(a.location) != .orderedSame,
           Continuity.names(place: placeBeforeTurn, in: desc) { return "" }
        let leftThings = a.placeThings[placeBeforeTurn.lowercased()] ?? []
        let things = offered.filter { t in !leftThings.contains { Self.similar($0, t) } }
        a.lore[i].desc = clip(desc, 300)
        if !things.isEmpty {
            // Things the story already put here stay; the built ones join them.
            let had = a.placeThings[a.location.lowercased()] ?? []
            let merged = Array((had + things.filter { t in !had.contains { Self.similar($0, t) } }).prefix(8))
            a.placeThings[a.location.lowercased()] = merged
            a.things = merged
        }
        return a.location + (things.isEmpty ? "" : " (" + things.prefix(5).joined(separator: "; ") + ")")
    }

    /// The time a moment can take, as the rebuild's time question offers it, in story minutes.
    static let timeSteps: [(String, Int)] = [
        ("a moment", 1), ("a few minutes", 5), ("a quarter of an hour", 15), ("half an hour", 30),
        ("an hour", 60), ("a few hours", 180), ("overnight", 480),
    ]

    /// "15 min", "3 h".
    static func span(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }

    /// How many turns away from a place before coming back to it asks what changed meanwhile.
    static let catchUpTurns = 5

    /// Coming back to a place after a good while away: one short question catches it up (who of
    /// the people left there is still there, and what ordinary things changed). Returns the changes,
    /// for the briefing and the turn guide.
    private func catchUp(_ a: inout Adventure, turns gap: Int, minutes: Int = 0, then: Int? = nil) async -> [String] {
        let key = a.location.lowercased()
        // The time of day then and now: when it has changed, the place's old light and sounds go.
        var timeLine = ""
        var turned = ""
        if let c = a.clock, let then, minutes > 0 {
            let was: String = Continuity.parts[Continuity.part(of: then)]
            let now: String = Continuity.parts[Continuity.part(of: c)]
            timeLine = "; about " + Self.span(minutes) + " of the story's time. It was " + was + " then; it is " + now + " now (" + Continuity.clockText(c) + ")"
            if was != now || minutes >= 720 {
                a.ambience[key] = nil
                turned = "It was " + was + " when you were last here; it is " + now + " now, and the light and the crowd have changed with it."
            }
        }
        let left = a.whereabouts.filter { $0.here != false && Cards.first($0.name).lowercased() != Cards.first(a.playerName).lowercased() }.map(\.name)
        var prompt = "You keep an audio story's world consistent."
        let desc: String = Cards.placeCard(a)?.desc ?? ""
        prompt += "\n\nPLACE: " + a.location
        if !desc.isEmpty { prompt += ": " + clip(desc, 240) }
        let things = a.placeThings[key] ?? []
        if !things.isEmpty { prompt += "\nTHINGS HERE: " + things.prefix(6).joined(separator: "; ") }
        prompt += "\nPEOPLE LEFT HERE: " + (left.isEmpty ? "(nobody)" : left.joined(separator: "; "))
        prompt += "\nTIME AWAY: the player has been elsewhere for \(gap) turns of the story" + timeLine
        prompt += "\n\n" + Prompts.awayQuestion
        let q0 = Date()
        let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                           options: .init(maxTokens: 120, temperature: 0.4, repetitionPenalty: 1.1, grammar: JSONGrammar.away(people: left)))) ?? ""
        noteQ("place", "While you were away", raw, since: q0)
        let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
        guard !m.isEmpty else { return turned.isEmpty ? [] : [turned] }
        let still = ((m["still_here"] as? [Any]) ?? []).compactMap { $0 as? String }
        var out: [String] = turned.isEmpty ? [] : [turned]
        for i in a.whereabouts.indices where left.contains(a.whereabouts[i].name) {
            if !still.contains(where: { $0.caseInsensitiveCompare(a.whereabouts[i].name) == .orderedSame }) {
                a.whereabouts[i].here = false
                a.whereabouts[i].engaged = false
                a.whereabouts[i].leftAt = nil
                a.whereabouts[i].at = "away from " + a.location
                a.whereabouts[i].doing = ""
                out.append(a.whereabouts[i].name + " has gone while you were away.")
            }
        }
        for c in ((m["changes"] as? [Any]) ?? []).compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }).prefix(2)
        where c.count > 6 && !Self.echoesPrompt(c) && !Self.brokenEntry(c) {
            out.append(clip(c, 140))
        }
        return out
    }

    /// Updates the turn guide's snapshot for the current turn (or starts it): the world as it
    /// stands, and what changed since the turn before.
    static func updateFrame(_ a: inout Adventure, looked: [String]? = nil, asked: [String]? = nil, notes: [String]? = nil, steps: [[String]]? = nil, pre: [String]? = nil) {
        let turn = a.playerTurns
        var f: WorldFrame
        if let last = a.frames.last, last.turn == turn { f = a.frames.removeLast() } else { f = WorldFrame(turn: turn) }
        let me = Cards.first(a.playerName).lowercased()
        let others = a.whereabouts.filter { let n = Cards.first($0.name).lowercased(); return !n.isEmpty && n != me && n != "you" }
        func line(_ w: Whereabout) -> String { w.doing.isEmpty ? w.name : w.name + ": " + Cards.clip(w.doing, 80) }
        f.time = a.storyTime
        f.place = a.location
        f.placeDesc = Cards.placeCard(a)?.desc ?? ""
        f.with = others.filter { $0.here != false && $0.engaged == true }.map(line)
        f.room = others.filter { $0.here != false && $0.engaged != true }.map(line)
        func gone(_ w: Whereabout) -> String {
            if let at = w.leftAt { return w.name + " (at " + at + ")" }
            return w.at.isEmpty ? w.name : w.name + " (" + Cards.clip(w.at, 40) + ")"
        }
        f.away = others.filter { $0.here == false }.map(gone)
        f.have = a.carrying
        f.around = Cards.props(a)
        f.spot = a.spot.isEmpty ? nil : a.spot
        f.sound = a.location.isEmpty ? nil : a.ambience[a.location.lowercased()]
        f.pending = a.pending.isEmpty ? nil : a.pending
        let feel: [String] = others.filter { $0.here != false }.compactMap { w in
            guard let c = Cards.card(for: w, in: a), let x = a.feelings[c.name.lowercased()] else { return nil }
            return c.name + ": " + x
        }
        f.feelings = feel.isEmpty ? nil : feel
        let inViewCards: [LoreEntry] = others.filter { $0.here != false }.compactMap { Cards.card(for: $0, in: a) }
        let want: [String] = inViewCards.compactMap { c in a.wants[c.name.lowercased()].map { c.name + ": " + $0 } }
        f.wants = want.isEmpty ? nil : want
        let know: [String] = inViewCards.compactMap { c in
            guard let k = a.knows[c.name.lowercased()], !k.isEmpty else { return nil }
            return c.name + ": " + k.joined(separator: "; ")
        }
        f.knows = know.isEmpty ? nil : know
        f.body = a.body.isEmpty ? nil : a.body
        f.goal = a.progress.isEmpty ? nil : a.progress
        if let looked { f.looked = looked }
        if let asked { f.asked = asked }
        if let steps { f.steps = steps }
        if let pre { f.pre = pre }
        if let notes { f.notes = notes }
        f.changed = frameDiff(a.frames.last, f) + f.notes
        a.frames.append(f)
        if a.frames.count > 300 { a.frames.removeFirst(a.frames.count - 300) }
    }

    /// What changed from one snapshot to the next, in plain lines.
    static func frameDiff(_ p: WorldFrame?, _ n: WorldFrame) -> [String] {
        guard let p else { return n.place.isEmpty ? ["The story begins."] : ["The story begins at " + n.place + "."] }
        var out: [String] = []
        if p.place.caseInsensitiveCompare(n.place) != .orderedSame {
            if n.place.isEmpty { out.append("Left " + p.place) }
            else if p.place.isEmpty { out.append("Arrived at " + n.place) }
            else { out.append("Moved: " + p.place + " → " + n.place) }
        }
        func names(_ l: [String]) -> [String] { l.map { $0.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? $0 } }
        let before = names(p.with + p.room), after = names(n.with + n.room)
        for x in after where !before.contains(x) { out.append("Came into view: " + x) }
        for x in before where !after.contains(x) { out.append("Out of view: " + x) }
        let facing = names(n.with)
        if facing != names(p.with), !facing.isEmpty { out.append("Facing: " + facing.joined(separator: ", ")) }
        for x in n.have where !p.have.contains(x) { out.append("You have: " + x) }
        for x in p.have where !n.have.contains(x) { out.append("No longer have: " + x) }
        if p.place.caseInsensitiveCompare(n.place) == .orderedSame {
            let seen = n.around.filter { !p.around.contains($0) }
            if !seen.isEmpty { out.append("Noticed: " + seen.joined(separator: "; ")) }
        } else if !n.around.isEmpty {
            out.append("Here: " + n.around.prefix(5).joined(separator: "; "))
        }
        return out
    }

    /// What the world check after a reply changed, in plain lines for the World panel.
    static func worldChanges(from s: Adventure, to n: Adventure, refused: [String], named: [String]) -> [String] {
        var out: [String] = named.map { "Name learned: " + $0 }
        if !n.location.isEmpty, n.location != s.location { out.append("Place: " + n.location) }
        if !n.storyTime.isEmpty, n.storyTime != s.storyTime { out.append("Time: " + n.storyTime) }
        func state(_ w: Whereabout) -> String { w.here == false ? "elsewhere" : w.engaged == true ? "with you" : w.here == true ? "in the room" : "" }
        for w in n.whereabouts {
            let old = s.whereabouts.first { $0.name == w.name }
            if old == nil || old!.at != w.at || old!.doing != w.doing || state(old!) != state(w) {
                out.append(w.name + ": " + [state(w), Continuity.placed(w.at), w.doing].filter { !$0.isEmpty }.joined(separator: ", "))
            }
        }
        for f in n.facts where !s.facts.contains(f) { out.append("New fact: " + f) }
        let gained = n.carrying.filter { !s.carrying.contains($0) }, lost = s.carrying.filter { !n.carrying.contains($0) }
        if !gained.isEmpty { out.append("You now have: " + gained.joined(separator: "; ")) }
        if !lost.isEmpty { out.append("No longer with you: " + lost.joined(separator: "; ")) }
        for e in n.timeline where !s.timeline.contains(e) { out.append("Timeline: " + e) }
        let key = n.location.lowercased()
        let seen = (n.placeThings[key] ?? []).filter { !(s.placeThings[key] ?? []).contains($0) }
        if !seen.isEmpty { out.append("Seen here: " + seen.joined(separator: "; ")) }
        for r in refused.prefix(6) { out.append("Kept off, not in the story: " + r) }
        return out.isEmpty ? ["Nothing changed."] : out
    }

    /// The player says their own name in the story ("I'm Ada"): from now on it is theirs in this
    /// story, and the people they meet may use it.
    private func learnPlayerName(_ a: inout Adventure, input: String) -> Bool {
        guard a.nameless, let name = Continuity.selfIntroduction(input) else { return false }
        if a.playerName.caseInsensitiveCompare(name) != .orderedSame {
            a.playerName = name
            if let i = a.lore.firstIndex(where: \.isPlayer) { a.lore[i].name = name }
            namesThisTurn.append(name + " (you)")
        }
        return true
    }

    /// A name said in the story becomes known: when the player asks someone their name, or asks
    /// about someone else's, or introduces themselves (and is told a name back). Returns what the
    /// storyteller must say, or "".
    private func revealName(_ a: inout Adventure, input: String, to: String, introduced: Bool) -> String {
        guard a.nameless, var ask = Continuity.asksName(input) ?? (introduced ? "you" : nil) else { return "" }
        let hidden = a.lore.indices.filter { a.lore[$0].kind == .person && !a.lore[$0].isPlayer && !a.lore[$0].known && !a.lore[$0].byPlayer }
        let heard = introduced && !a.playerName.isEmpty && Continuity.asksName(input) == nil
        guard !hidden.isEmpty else { return heard ? "They heard your name and use it: \"" + a.playerName + ".\"" : "" }
        func lead(_ n: String) -> String { n.lowercased().split(separator: " ").first.map(String.init) ?? "" }
        var addressee = to
        if addressee.isEmpty { addressee = a.whereabouts.first { $0.engaged == true && $0.here != false }?.name ?? "" }
        let text = input.lowercased()
        var target: Int?
        if ask == "you" {
            target = hidden.first { lead(a.lore[$0].name) == lead(addressee) }
            if target == nil, addressee.isEmpty {
                let near = hidden.filter { i in a.whereabouts.contains { lead($0.name) == lead(a.lore[i].name) && $0.here != false } }
                if near.count == 1 { target = near[0] }
            }
        } else {
            let others = hidden.filter { lead(a.lore[$0].name) != lead(addressee) }
            let he = text.range(of: #"\b(he|his|him)\b"#, options: .regularExpression) != nil
            let she = text.range(of: #"\b(she|her)\b"#, options: .regularExpression) != nil
            func uses(_ i: Int, _ p: String) -> Bool { a.facts.contains { $0.hasPrefix(a.lore[i].name + " uses " + p) } }
            let byRole = others.first { i in
                let core = Continuity.roleLabel(a.lore[i].role).replacingOccurrences(of: "the ", with: "")
                return core.count >= 3 && text.contains(core)
            }
            // "I go to the woman and ask her what her name is": "her" is the person they're with
            // when she is the one asked, or the only one here it fits.
            let own = hidden.first(where: { lead(a.lore[$0].name) == lead(addressee) })
            let askedDirect = text.range(of: #"\b(ask|asks|asking|asked)\s+(her|him|them)\b|\b(to|at)\s+(her|him)\b"#, options: .regularExpression) != nil
            let fitsOwn = own.map { (he && !she && uses($0, "he")) || (she && !he && uses($0, "she")) } ?? false
            let fitsOther = others.contains { (he && !she && uses($0, "he")) || (she && !he && uses($0, "she")) }
            if byRole == nil, let own, fitsOwn, askedDirect || !fitsOther {
                target = own; ask = "you"
            } else {
                target = byRole ?? others.first { (he && !she && uses($0, "he")) || (she && !he && uses($0, "she")) } ?? (others.count == 1 && !fitsOwn ? others[0] : nil)
            }
            // "I approach the lady and ask for her name": the person asked is the one they're with.
            if target == nil, let own = hidden.first(where: { lead(a.lore[$0].name) == lead(addressee) }) { target = own; ask = "you" }
        }
        guard let i = target else { return "" }
        a.lore[i].known = true
        let name = a.lore[i].name
        namesThisTurn.append(name)
        if heard { return name + " hears your name, " + a.playerName + ", says it back and gives theirs: \"" + name + ".\"" }
        if ask == "you" { return name + " tells you their name, plainly: \"" + name + ".\"" }
        return (addressee.isEmpty ? "You learn that" : addressee + " tells you that") + " the person you asked about is " + name + "."
    }

    /// Whether the plan's ANSWER line says a name the story hasn't said yet.
    static func answerNamesHidden(_ plan: String, _ a: Adventure) -> Bool {
        guard let line = plan.components(separatedBy: "\n").first(where: { $0.hasPrefix("ANSWER:") }) else { return false }
        for h in Continuity.hiddenNames(a) {
            let first = h.name.split(separator: " ").first.map(String.init) ?? h.name
            if line.contains(first) { return true }
        }
        return false
    }

    /// The plan with `answer` as its ANSWER line (kept ahead of any answer already there).
    static func withAnswer(_ plan: String, _ answer: String) -> String {
        var lines = plan.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("ANSWER:") }) {
            let old = lines[i].dropFirst(7).trimmingCharacters(in: .whitespaces)
            lines[i] = "ANSWER: " + answer + (old.isEmpty || old == "none" ? "" : " " + old)
        } else {
            lines.insert("ANSWER: " + answer, at: min(1, lines.count))
        }
        return lines.joined(separator: "\n")
    }

    /// A cautious token count (about 3.5 bytes a token), for planning a prompt before it is tokenised.
    /// LLMService checks the real count and trims if this ever guesses low.
    /// The quoted lines in a reply, in order ("..." and “...”).
    static func quotes(in s: String) -> [String] {
        var out: [String] = []
        let pattern = #"[\"“]([^\"“”]{3,240})[\"”]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let r = Range(m.range(at: 1), in: s) { out.append(String(s[r]).trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }

    static func tokens(_ s: String) -> Int { Int(Double(s.utf8.count) / LLMService.bytesPerToken) + 1 }

    /// Strips things small models sometimes add: headings, "GM:" prefixes, trailing option lists.
    /// A reply that ran out of room mid-sentence ("And you certainly aren't supposed") ends at its
    /// last full sentence instead, when that keeps most of it.
    static func endAtSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last, !".!?…\"”’)*".contains(last) else { return t }
        guard let r = t.range(of: #"[.!?…]["”’]?(?=\s)"#, options: [.regularExpression, .backwards]) else { return t }
        let kept = String(t[..<r.upperBound])
        return kept.count >= t.count / 2 ? kept : t
    }

    static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"(?m)^\s*(#+ .*|\*\*?(Game Master|GM|Narrator)\*?\*?:?\s*)$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^(Game Master|GM|Narrator):\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[GAME MASTER BRIEFING[\s\S]*?END OF BRIEFING\]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The player asks something ("I ask how I got here", "what happened to my ship?").
    /// Small models tend to answer a question with atmosphere or a riddle, so a question gets a
    /// direct instruction to answer it, placed right before the player's words where it is hardest to miss.
    static func asks(_ input: String) -> Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("?") { return true }
        // Also a question in the middle of a message without a question mark (dictation drops them):
        // "I'm freaked out. What happened to my crew".
        let pattern = #"(?i)^(i\s+|we\s+)?(ask|asks|asking|question|wonder|inquire)\b|^(how|what|why|who|whom|whose|where|when|which)\b|\b(tell me|explain)\b|\b(how|what|why|who|where|when|which)\s+(happened|happens|is|are|was|were|did|do|does|can|could|should|will|would|has|have)\b|\b(wanna|want to|would like to|like to|dying to) know\b|\b(do|did|are|were|can|could|would|will|have) (you|she|he|they)\b"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    /// "What are you stitching?" with no name: the one person here the last reply showed doing
    /// that is who is meant, even when the player was facing someone else.
    /// The people as the player wrote them in the set-up and the premise ("the old keeper and his
    /// grown daughter"), for the questions that build their cards: the cards keep to it.
    static func castAsWritten(_ a: Adventure) -> String {
        let who = [a.setup.describe, a.setup.allies].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        return who.isEmpty ? "" : "\nWHO THEY ARE (as the player wrote it): " + String(who.prefix(500))
    }

    static func addressedByDeed(_ a: Adventure, input: String) -> String? {
        let said = Continuity.wordSet(input)
        let namesSomeone = a.cast.contains { c in
            said.contains(Cards.first(c.name).lowercased()) || Continuity.wordSet(c.role).contains(where: { $0.count > 3 && said.contains($0) })
        }
        guard !namesSomeone, let lastGM = a.transcript.last(where: { $0.role == .gm })?.text else { return nil }
        let common: Set<String> = ["about", "there", "their", "would", "could", "should", "where", "which", "while", "these", "those",
                                   "thing", "things", "something", "doing", "think", "right", "today", "tonight", "again", "other"]
        func stems(_ t: String) -> Set<String> {
            Set(t.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                .filter { $0.count >= 5 && !common.contains($0) }.map { String($0.prefix(5)) })
        }
        let asked = stems(input)
        guard !asked.isEmpty else { return nil }
        var fits: [String] = []
        for c in a.cast where a.whereabouts.contains(where: { $0.name == c.name && $0.here != false }) {
            let tags: [String] = [Cards.first(c.name).lowercased()] + Continuity.wordSet(c.role).filter { $0.count > 3 }
            let about = PresenceFilter.sentences(lastGM).filter { sen in
                let w = Continuity.wordSet(sen)
                return tags.contains(where: { w.contains($0) })
            }.joined(separator: " ")
            if !asked.isDisjoint(with: stems(about)) { fits.append(c.name) }
        }
        return fits.count == 1 ? fits[0] : nil
    }

    /// An answer that names a year after the story's own (a watch that stopped "in 1954" in a 1925
    /// story) doesn't belong to it.
    static func outOfTime(_ s: String, _ a: Adventure) -> Bool {
        func years(_ t: String) -> [Int] {
            guard let re = try? NSRegularExpression(pattern: #"\b(1[0-9]{3}|20[0-9]{2})\b"#) else { return [] }
            return re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range, in: t).flatMap { Int(t[$0]) } }
        }
        guard let now = years(a.bible).first else { return false }
        return years(s).contains { $0 > now }
    }

    /// The thing the player says they pick up or take ("I pick up all of the stools" → "the stools",
    /// "I pick up every single barstool in my hands" → "the barstools"). Nil when they say they won't
    /// ("I can't take this"), when it's a person, or when it isn't a thing ("take a seat").
    static func pickedUp(_ input: String) -> String? {
        let text = input.replacingOccurrences(of: "’", with: "'")
        let det = #"(?:(?:all|both|one|each|some|most|any|a few|a couple|two|three|four|five|several|every one|every single one) of\s+)?(?:a few|a couple of|a pair of|a handful of|the|an|a|my|your|his|her|their|some|that|this|those|these|every(?:\s+single)?|each|all(?:\s+the)?|both(?:\s+the)?|two|three|four|five|six|several|one)\s+"#
        let thing = #"([a-z]+(?:\s+[a-z]+){0,2})"#
        let pattern = #"(?i)\b(?:pick|picks|picked|picking) up\s+(?:"# + det + #")?"# + thing
            + #"|\b(?:pick|picks|picked) "# + det + #"([a-z]+(?:\s+[a-z]+){0,2}?)\s+up\b"#
            + #"|\b(?:grab|grabs|grabbed|take|takes|took|lift|lifts|lifted|carry|carries|carried|collect|collects|pocket|pockets|gather up|gathers up|scoop up|scoops up)\s+"# + det + thing
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text) else { continue }
            // "I can't take this", "I don't pick up the glass": not taken.
            let before = String(text[..<whole.lowerBound].suffix(40))
            if before.range(of: #"(?i)\b(can'?t|cannot|can not|don'?t|do not|won'?t|will not|wouldn'?t|shouldn'?t|not|never|refuse to|rather not)\s+(?:[a-z']+\s+){0,2}$"#, options: .regularExpression) != nil { continue }
            for g in [1, 2, 3] {
                guard let r = Range(m.range(at: g), in: text) else { continue }
                var words = text[r].lowercased().split(separator: " ").map(String.init)
                // "the stools and hold them", "every single barstool in my hands": stop at a joining word.
                if let cut = words.firstIndex(where: { joinWords.contains($0) }) { words = Array(words[..<cut]) }
                guard let first = words.first, let last = words.last, last.count > 2,
                      !notStarts.contains(first), !notThings.contains(last), !personWords.contains(last) else { continue }
                // "every single barstool" is all of them.
                if text[whole].range(of: #"(?i)\b(every|each|all|both|several|two|three|four|five|six|few|couple|pair|handful)\b"#, options: .regularExpression) != nil,
                   !last.hasSuffix("s") { words[words.count - 1] = last + "s" }
                return "the " + words.joined(separator: " ")
            }
        }
        return nil
    }

    private static let joinWords: Set<String> = ["and", "then", "to", "from", "off", "out", "up", "with", "in", "on", "by", "near", "at", "for", "into", "behind", "under", "i", "so", "over", "across", "around", "while", "as", "of"]
    private static let notStarts: Set<String> = ["where", "what", "when", "how", "after", "again", "speed", "pace", "right"]
    /// "Take a seat", "take a sip", "take her hand": not things to carry.
    private static let notThings: Set<String> = ["seat", "spot", "place", "turn", "time", "look", "step", "breath", "moment", "chance", "sip", "swig", "gulp", "walk", "stroll", "rest", "break", "bow", "guess", "hint", "note", "notes", "care", "hold", "liking", "stand", "hand", "hands", "arm", "word", "advice", "where", "what", "speed", "pace", "him", "her", "them", "you", "one", "ones", "lot", "bit"]

    /// Whether a thing is the player's: their own words name it, or a sentence of the reply that
    /// names it shows it as theirs ("your soaked coat", "she hands you the glass", "you lift the
    /// stools", "in your hand"). "She holds up a spool of thread" is hers.
    static func shownAsYours(_ thing: String, reply: String, playerSaid: String) -> Bool {
        if Continuity.grounded(thing, in: Continuity.wordSet(playerSaid), share: 0.5) { return true }
        guard var noun = thing.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init), noun.count >= 3 else { return false }
        if noun.hasSuffix("s"), noun.count > 4 { noun = String(noun.dropLast()) }
        let n = NSRegularExpression.escapedPattern(for: noun)
        let mine = #"(?i)\byour\s+(?:[a-z'-]+\s+){0,3}"# + n
            + #"|\b(?:hands?|handed|gives?|gave|passes|passed|slides?|slid|tosses|tossed|offers?|offered|presses|pressed)\s+you\b"#
            + #"|\b(?:hands?|handed|gives?|gave|passes|passed|slides?|slid|tosses|tossed|offers?|offered|presses|pressed|puts?|places?|placed|sets?)\b[^.!?]{0,60}\b(?:to you|into your|in your)\b"#
            + #"|\byou\s+(?:[a-z]+ly\s+)?(?:take|took|grab|grabbed|pick|picked|accept|accepted|pocket|pocketed|hold|holding|carry|carrying|lift|lifted|clutch|clutching|cradle|cradling|raise|raised)\b"#
            + #"|\bin your (?:hand|hands|pocket|lap|grip|palm|fingers|arms)\b"#
        for sentence in PresenceFilter.sentences(reply) where sentence.lowercased().contains(noun) {
            if sentence.range(of: mine, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// Words for people, who are walked with or brought along, never carried ("take the bartender").
    static let personWords: Set<String> = ["bartender", "barkeep", "man", "woman", "men", "women", "lady", "gentleman", "girl", "boy", "guy", "kid", "child", "regular", "stranger", "friend", "waiter", "waitress", "owner", "guard", "officer", "doctor", "captain", "driver", "people", "person", "everyone", "everybody"]

    /// "I take it", "I pick them up", "I pocket it": the player takes what was just put in front of
    /// them. Returns the prop the last reply named last ("places a small, silver pocket watch on the
    /// bar" → "silver pocket watch").
    static func pickedUpIt(_ input: String, lastReply: String, props: [String]) -> String? {
        let text = input.replacingOccurrences(of: "’", with: "'")
        guard let r = text.range(of: #"(?i)\b(?:(?:pick|picks|picked) (?:it|them) up|(?:pick|picks|picked) up (?:it|them)|(?:take|takes|took|grab|grabs|grabbed|pocket|pockets|accept|accepts|accepted|keep|keeps) (?:it|them))\b"#, options: .regularExpression) else { return nil }
        let before = String(text[..<r.lowerBound].suffix(40))
        if before.range(of: #"(?i)\b(can'?t|cannot|can not|don'?t|do not|won'?t|will not|wouldn'?t|shouldn'?t|not|never|refuse to|rather not)\s+(?:[a-z']+\s+){0,2}$"#, options: .regularExpression) != nil { return nil }
        let reply = lastReply.lowercased()
        var best: (String, String.Index)? = nil
        for p in props {
            let noun = p.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
            guard noun.count >= 3, let at = reply.range(of: noun, options: .backwards)?.lowerBound else { continue }
            if best == nil || at > best!.1 { best = (p, at) }
        }
        return best?.0
    }

    /// An answer that dodges ("it's complicated", "you'll see", "that's a story for another time").
    static func vagueAnswer(_ s: String) -> Bool {
        s.range(of: #"(?i)\b(it'?s complicated|you'?ll see|for another (time|night|day)|never you mind|who knows|that depends|nothing (you|for you)|some things|in time|wouldn'?t you like)\b"#, options: .regularExpression) != nil
    }

    /// The player writes prose rather than commands.
    static func narrates(_ input: String) -> Bool {
        // Long, story-like prose; ordinary speech ("My name is Simon. Can I get you a drink?") is not narration.
        input.split(separator: " ").count > 60 && input.filter({ $0 == "." }).count >= 3 && !input.contains("?")
    }

    // MARK: The clock (play by the clock, not by turns)

    func secsLeft(_ a: Adventure, live: Bool = true) -> Double {
        let played = a.elapsed + (live ? a.lastSendAt.map { min(Self.maxGap, Date().timeIntervalSince($0)) } ?? 0 : 0)
        return max(0, Double(a.minutes) * 60 - played)
    }

    private func turnSecs(_ a: Adventure) -> Double {
        let t = a.turnTimes.suffix(6)
        guard t.count >= 2 else { return Self.secPerTurn }
        let med = t.sorted()[t.count / 2]
        let pad = Double(max(0, 3 - t.count))
        return max(30, min(Self.maxGap, (med + Self.secPerTurn * pad) / (1 + pad)))
    }

    /// Moves the play clock on and works out how many replies are left. Returns the seconds of play
    /// this turn added.
    @discardableResult
    private func clockTick(_ a: inout Adventure, hidden: Bool, paused: Double = 0) -> Double {
        let now = Date()
        var played = 0.0
        if !hidden, let last = a.lastSendAt {
            let dt = min(Self.maxGap, max(0, now.timeIntervalSince(last) - max(0, paused)))
            a.elapsed += dt
            a.turnTimes = Array((a.turnTimes + [dt.rounded()]).suffix(12))
            played = dt
        }
        a.lastSendAt = now
        var left = Int((secsLeft(a, live: false) / turnSecs(a) + 0.35).rounded(.down))
        if hidden && left == 0 { left = 1 }
        a.left = max(0, left)
        return played
    }

    // MARK: Prompts

    /// The rules and the story bible. `tight` (0 to `tightest`) squeezes the parts that grow over a
    /// long story, so the whole prompt fits the context: first the showrunner's notes and the story so
    /// far, then the bible itself (its start, which holds the premise and the people, is kept).
    private func systemPrompt(_ a: Adventure, tight: Int = 0) -> String {
        let bibleChars = [1600, 1300, 1000, 800][min(tight, 3)]
        let notesChars = [1200, 600, 350, 200][min(tight, 3)]
        let chapterCount = [6, 4, 3, 2][min(tight, 3)]
        let chapterChars = [600, 300, 220, 180][min(tight, 3)]
        var s = Prompts.gmRules
        if a.isShort { s += "\n\n" + Prompts.shortRules }
        s += "\n\n" + Prompts.castRules(minutes: a.minutes, names: a.cast.filter { !a.nameless || $0.known || $0.byPlayer }.map(\.name))
        if a.nameless { s += "\n" + Prompts.namelessRule }
        if !a.playerName.isEmpty, !a.nameless || nameTold(a) {
            s += "\n\nTHE PLAYER CHARACTER is \(a.playerName), and that is \"you\". The name appears only in other characters' dialogue."
        }
        s += "\n\n" + Prompts.feelingRules(a.setup.feeling)
        s += "\n\n" + Prompts.modeRules(simulator: a.setup.simulator)
        let age = PlayerDetails.saved.age
        if age > 0 { s += "\n\n" + Prompts.ageRules(age) }
        let limits = limitsText(a)
        if !limits.isEmpty { s += "\n\n## SET-UP LIMITS (the player chose these; never break them)\n" + limits }
        s += "\n\n" + Prompts.hardLimits
        s += "\n\n## STORY BIBLE\n" + clip(a.bible, bibleChars)
        let pinned = a.lore.filter(\.byPlayer)
        if !pinned.isEmpty {
            s += "\n\n## FACTS THE PLAYER SET (always true; they win over anything said before)\n"
                + pinned.map { "- \($0.name) (\($0.label.lowercased())): " + clip($0.desc, tight >= 3 ? 160 : 600) }.joined(separator: "\n")
        }
        if !a.chapters.isEmpty { s += "\n\n## STORY SO FAR\n" + a.chapters.suffix(chapterCount).map { "- " + clip($0, chapterChars) }.joined(separator: "\n") }
        if a.setup.simulator, !a.secrets.isEmpty {
            s += "\n\n## BACKSTORIES (private: a person shares theirs only when the player asks about their life, a little at a time, in their own words; never volunteered)\n" + clip(a.secrets.map { "- " + $0 }.joined(separator: "\n"), notesChars)
        } else if let notes = a.notes, !notes.text.isEmpty {
            s += "\n\n## PRIVATE GM NOTES (do not blurt these out; seed clues. If the player asks directly, characters still answer what they honestly know)\n" + clip(notes.text, notesChars)
        } else if !a.secrets.isEmpty {
            s += "\n\n## PRIVATE NOTES (do not blurt these out; seed clues. If the player asks directly, characters still answer what they honestly know)\n" + clip(a.secrets.map { "- " + $0 }.joined(separator: "\n"), notesChars)
        }
        s += "\n\n## HOW EACH TURN ARRIVES\nThe latest message starts with a private briefing (notes, then the SCENE CARD), then the player's action. Follow it, never mention it, and reply to the action."
        return s
    }

    private func hiddenPeople(_ a: Adventure) -> [LoreEntry] {
        let told = a.transcript.filter { $0.role == .gm }.map(\.text).joined(separator: " ")
        return a.cast.filter { c in
            guard !c.known else { return false }
            let first = c.name.split(separator: " ").first.map(String.init) ?? c.name
            return !(told.contains(c.name) || (first.count > 2 && told.contains(first)))
        }
    }

    /// Which pronouns a text uses for a person: the he/she words right after each mention of their
    /// first name, up to the next person's name. Nil when the text is unclear.
    static func pronouns(in text: String, for name: String, others: [String]) -> String? {
        let (he, she) = Continuity.pronounCounts(in: text, for: name, others: others)
        if he >= 2 && he >= she * 3 { return "he/him" }
        if she >= 2 && she >= he * 3 { return "she/her" }
        return nil
    }

    /// Makes each person's pronouns match how the story itself refers to them: the architect sometimes
    /// writes one gender in the character list and another in the bible. The first text with a clear
    /// answer wins, and the fact and the character card are corrected to match.
    private func checkPronouns(_ a: inout Adventure, texts: [String]) {
        let firsts = a.cast.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
        for person in a.cast where !person.byPlayer {
            guard let found = texts.lazy.compactMap({ Self.pronouns(in: $0, for: person.name, others: firsts) }).first else { continue }
            let prefix = person.name + " uses "
            if let i = a.facts.firstIndex(where: { $0.hasPrefix(prefix) }) {
                if a.facts[i].hasPrefix(prefix + found) { continue }
                a.facts[i] = prefix + found + "."
            } else {
                a.facts.insert(prefix + found + ".", at: 0)
            }
            if let k = a.lore.firstIndex(where: { $0.id == person.id }) { a.lore[k].desc = Self.swapPronouns(a.lore[k].desc, to: found) }
        }
    }

    /// Rewrites he/she words in a short description to the given pronouns.
    static func swapPronouns(_ s: String, to p: String) -> String {
        let male = p.hasPrefix("he")
        let map: [String: String] = male
            ? ["she": "he", "herself": "himself", "hers": "his", "her": "her"]
            : ["he": "she", "him": "her", "his": "her", "himself": "herself"]
        var out = s
        for (from, to) in map where from != to {
            for (f, t) in [(from, to), (from.prefix(1).uppercased() + from.dropFirst(), to.prefix(1).uppercased() + to.dropFirst())] {
                out = out.replacingOccurrences(of: "\\b" + f + "\\b", with: t, options: .regularExpression)
            }
        }
        // "her" is either "his" or "him": before a word it is possessive.
        if male {
            out = out.replacingOccurrences(of: "\\b([Hh])er(\\s+[a-z])", with: "$1is$2", options: .regularExpression)
            out = out.replacingOccurrences(of: "\\b([Hh])er\\b", with: "$1im", options: .regularExpression)
        }
        return out
    }

    /// True when a model copied the review instructions' own description text back as content.
    static func echoesPrompt(_ s: String) -> Bool {
        let probe = s.lowercased().trimmingCharacters(in: .whitespaces).prefix(32)
        guard probe.count >= 14 else { return false }
        return Prompts.review.lowercased().contains(probe) || Prompts.groundedInstructions.contains { $0.lowercased().contains(probe) } || Prompts.reviewKeyHelp.values.contains { $0.lowercased().contains(probe) }
    }

    /// Two lines that say nearly the same thing (most of their words shared).
    /// An entry the model wrote with the JSON around it spilled in ("things':['a long mahogany
    /// bar', 'cr") or that ran into stray characters from another script.
    static func brokenEntry(_ v: String) -> Bool {
        v.contains { "[]{}\"".contains($0) } || v.contains("':") || v.contains("',")
            || v.unicodeScalars.contains { $0.value >= 0x2E80 && $0.value < 0xFE00 }
    }

    /// Two facts that open the same way ("Dolores Vega is twenty-eight ...") say the same thing;
    /// the newer one replaces the older.
    static func sameOpening(_ a: String, _ b: String) -> Bool {
        func lead(_ s: String) -> [Substring] { Array(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).prefix(4)) }
        let x = lead(a)
        return x.count == 4 && x == lead(b)
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> Set<Substring> { Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })) }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.85
    }

    static func sentences(_ s: String) -> [String] {
        s.replacingOccurrences(of: #"([.!?])\s+(?=[A-Z])"#, with: "$1\n", options: .regularExpression)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }
    }

    /// Pulls the finished fields out of a JSON object that was cut off (a review that looped or ran
    /// out of room): complete strings, and the complete items of an unfinished list.
    static func salvageJSON(_ s: String) -> [String: Any] {
        let c = Array(s)
        var out: [String: Any] = [:]
        func readString(_ i: inout Int) -> String? {   // c[i] is the opening quote
            var j = i + 1, buf = ""
            while j < c.count {
                if c[j] == "\\", j + 1 < c.count {
                    let n = c[j + 1]
                    buf.append(n == "n" ? "\n" : n == "t" ? " " : n)
                    j += 2
                    continue
                }
                if c[j] == "\"" { i = j + 1; return buf }
                buf.append(c[j]); j += 1
            }
            return nil
        }
        func skipSpace(_ i: inout Int) { while i < c.count, c[i].isWhitespace { i += 1 } }
        func readObject(_ i: inout Int) -> [String: Any]? {   // c[i] is "{"
            var depth = 0, j = i, inStr = false
            while j < c.count {
                let ch = c[j]
                if inStr { if ch == "\\" { j += 2; continue }; if ch == "\"" { inStr = false } }
                else if ch == "\"" { inStr = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j < c.count, let data = String(c[i...j]).data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            i = j + 1
            return o
        }
        for key in ["fixes", "facts", "unanswered", "scene", "time", "timeline", "people", "next"] {
            guard let r = s.range(of: "\"" + key + "\"\\s*:\\s*", options: .regularExpression) else { continue }
            var i = s.distance(from: s.startIndex, to: r.upperBound)
            guard i < c.count else { continue }
            if c[i] == "\"" {
                if let v = readString(&i) { out[key] = v }
            } else if c[i] == "[" {
                i += 1
                var items: [Any] = []
                while i < c.count {
                    skipSpace(&i)
                    guard i < c.count else { break }
                    if c[i] == "]" { break }
                    if c[i] == "," { i += 1; continue }
                    if c[i] == "\"", let v = readString(&i) { items.append(v); continue }
                    if c[i] == "{", let o = readObject(&i) { items.append(o); continue }
                    break
                }
                out[key] = items
            }
        }
        return out
    }

    /// A place's short name. Models sometimes write a whole description where a name belongs ("A white
    /// coral beach at sunrise. The sand is powdery..."): a known place it mentions wins ("The Beach"),
    /// otherwise the first few words of its first phrase ("White coral beach").
    static func placeName(_ raw: String, known: [String]) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= 60, !s.contains(". ") { return s.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let lower = s.lowercased()
        func core(_ n: String) -> String {
            let l = n.lowercased()
            for art in ["the ", "a ", "an "] where l.hasPrefix(art) { return String(l.dropFirst(art.count)) }
            return l
        }
        let hit = known.filter { k in
            let c = core(k)
            return c.count > 2 && lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: c) + "\\b", options: .regularExpression) != nil
        }.max { core($0).count < core($1).count }
        if let hit { return hit }
        var phrase = s.components(separatedBy: CharacterSet(charactersIn: ".,;:!?")).first ?? s
        for cut in [" at ", " with ", " where ", " that ", " which ", " under ", " near "] {
            if let r = phrase.range(of: cut, options: .caseInsensitive) { phrase = String(phrase[..<r.lowerBound]) }
        }
        var words = phrase.split(separator: " ").map(String.init)
        if let f = words.first, ["a", "an"].contains(f.lowercased()) { words.removeFirst() }
        let name = words.prefix(5).joined(separator: " ")
        guard !name.isEmpty else { return String(s.prefix(40)) }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A description the model wrote where a place's name belonged is added to that place's details
    /// (once), so nothing it painted is lost when the name snaps to the known place.
    static func enrichPlace(_ a: inout Adventure, _ name: String, with raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 40 || text.contains(". "), text.caseInsensitiveCompare(name) != .orderedSame,
              let i = a.lore.firstIndex(where: { $0.kind == .place && $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              !a.lore[i].byPlayer else { return }
        let desc = a.lore[i].desc
        guard !desc.lowercased().contains(String(text.lowercased().prefix(30))) else { return }
        let joined = desc.isEmpty ? text : desc.trimmingCharacters(in: .whitespaces) + (desc.hasSuffix(".") ? " " : ". ") + text
        a.lore[i].desc = joined.count <= 600 ? joined : String(joined.prefix(600)) + "…"
    }

    /// Keeps the story clock in step with what the reply painted. The opening scene is what the player
    /// heard first, so a clear time of day in it wins over the architect's note. After that, a reply
    /// that clearly moved the day on (dusk falling, the first stars) moves the clock forward to
    /// match; one that paints an earlier hour is a slip (`continuitySlips`) and moves nothing.
    /// The time of day the premise gives ("a stormy night"), from the player's own set-up first.
    static func premiseDayParts(_ a: Adventure) -> Set<Int> {
        let own = Continuity.dayParts(in: a.setup.describe + " " + a.setup.place)
        if !own.isEmpty { return own }
        return Continuity.dayParts(in: a.storyTime + " " + a.facts.prefix(8).joined(separator: " ") + " " + String(a.bible.prefix(600)))
    }

    private func settleClock(_ a: inout Adventure, reply: String, opening: Bool) {
        if a.clock == nil, let m = Continuity.minutes(in: a.storyTime) { a.clock = m }
        // A time of day the premise gives ("a stormy night") stands over what the opening painted.
        var seededClock = false
        if opening, clockFromPremise, a.clock != nil {
            // The model already read the opening hour off the player's own words: it stands.
            clockFromPremise = false
            seededClock = true
        } else if opening {
            let told = Self.premiseDayParts(a)
            if let lo = told.min(), let hi = told.max(), hi - lo <= 1 {
                if a.clock == nil || !told.contains(Continuity.part(of: a.clock!)) { a.clock = Continuity.partStarts[hi] }
                seededClock = true
            }
        }
        let cues = Continuity.dayParts(in: reply)
        if let lo = cues.min(), let hi = cues.max(), hi - lo <= 1 {
            if let c = a.clock {
                let now = Continuity.part(of: c)
                if opening, !cues.contains(now), !seededClock {
                    a.clock = Continuity.partStarts[lo]
                }
                // After the opening the clock moves only by time passed or a skip the player
                // narrates: a reply that tells of "a stormy night" long ago is not nightfall.
            } else {
                a.clock = Continuity.partStarts[lo]
            }
        }
        if let c = a.clock { a.storyTime = Continuity.storyTime(clock: c, old: a.storyTime) }
    }

    /// Marks corrections found by checks in code (kept through the review, replaced after the next reply).
    static let checked = "(checked) "

    /// Slips a reply makes that code can see: a person's pronouns that contradict their fact, a time
    /// of day earlier than the story clock (or two far-apart times at once), narration that left
    /// second person, and things handed to the player that the story never gave them.
    /// The people the tracker places somewhere other than with the player, for the presence check.
    /// Anyone who may fairly turn up in this reply is left off: someone on their way, someone the
    /// player names, someone the plan has acting or answering, and, when the player is going
    /// somewhere, anyone at a place the player mentions.
    private func absentPeople(_ a: Adventure, input: String, plan: String) -> [PresenceFilter.Absent] {
        let said = input.lowercased()
        let planned = plan.split(separator: "\n").filter { l in ["ANSWER"].contains { l.uppercased().hasPrefix($0) } }
            .joined(separator: " ").lowercased()
        let moving = Continuity.moves(input)
        let dull: Set<String> = ["with", "from", "near", "there", "their", "into", "onto", "that", "this", "where", "while", "inside", "outside", "sitting", "standing", "seated", "walking"]
        let going = Set(said.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 4 && !dull.contains($0) })
        let me = a.playerName.lowercased().split(separator: " ").first.map(String.init) ?? ""
        // Someone in the room the player is not dealing with stays in the background too, as long as
        // the player is dealing with somebody.
        let someone = a.whereabouts.contains { w in
            let first = w.name.lowercased().split(separator: " ").first.map(String.init) ?? ""
            return first != me && first != "you" && w.here != false && w.engaged == true
        }
        return a.whereabouts.compactMap { w -> PresenceFilter.Absent? in
            let background = someone && w.here != false && w.engaged == false
            guard w.here == false || background, w.heading.isEmpty || background else { return nil }
            let first = w.name.lowercased().split(separator: " ").first.map(String.init) ?? w.name.lowercased()
            if first == me || first == "you" || first.count < 3 { return nil }
            if said.contains(first) || planned.contains(first) { return nil }
            // Nameless: the player and the plan call them by their role.
            var role = ""
            if a.nameless, let entry = a.lore.first(where: { $0.name == w.name && $0.kind == .person }), !entry.known, !entry.byPlayer {
                role = Continuity.roleLabel(entry.role)
            }
            let core = role.replacingOccurrences(of: "the ", with: "")
            if core.count >= 3, said.contains(core) || planned.contains(core) { return nil }
            if moving {
                let place = Set(w.at.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
                if !going.isDisjoint(with: place) { return nil }
            }
            return .init(name: w.name, at: w.at, also: role.isEmpty ? [] : [role])
        }
    }

    private func continuitySlips(_ a: Adventure, reply: String) -> [String] {
        var out: [String] = []
        let firsts = a.cast.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
        for person in a.cast {
            let prefix = person.name + " uses "
            guard let fact = a.facts.first(where: { $0.hasPrefix(prefix) }),
                  let used = Self.pronouns(in: reply, for: person.name, others: firsts) else { continue }
            let right = fact.dropFirst(prefix.count).hasPrefix("he") ? "he/him" : fact.dropFirst(prefix.count).hasPrefix("she") ? "she/her" : ""
            if !right.isEmpty, right != used {
                out.append("\(person.name) is \(right), never \(used). The last reply got this wrong; use \(right) for \(person.name) from now on.")
            }
        }
        if let c = a.clock {
            let cues = Continuity.dayParts(in: reply)
            if let lo = cues.min(), let hi = cues.max() {
                let names = cues.sorted().map { Continuity.parts[$0] }.joined(separator: " and ")
                if hi - lo >= 2 {
                    out.append("The last reply mixed times of day (\(names)). It is \(a.storyTime) now. " + Continuity.skyHint(c))
                } else if Continuity.part(of: c) - lo >= 2 {
                    out.append("It is \(a.storyTime) now, not \(Continuity.parts[lo]). Time only moves forward. " + Continuity.skyHint(c))
                }
            }
        }
        if let pov = Continuity.povSlip(reply, playerName: a.playerName) { out.append(pov) }
        if Continuity.speaksForPlayer(reply) {
            out.append("The last reply put words in the player's mouth (\"...\", you say). Never write what the player says; only they decide that.")
        }
        // The old word-pattern guess at "things the player never had" is gone: it read "your
        // sightline" and "your own name" as possessions. What you hold comes from the map.
        return out
    }

    /// People positions from a model's JSON: [{name, where, doing, heading}].
    static func whereabouts(_ raw: Any?) -> [Whereabout] {
        ((raw as? [[String: Any]]) ?? []).compactMap { d in
            func f(_ k: String) -> String { (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            let name = f("name")
            var at = f("where")
            if at.lowercased().hasPrefix("at ") { at = String(at.dropFirst(3)) }
            guard !name.isEmpty, !at.isEmpty else { return nil }
            let heading = f("heading")
            let none = ["", "none", "nowhere", "staying", "n/a", "-"].contains(heading.lowercased())
            var here = d["with_player"] as? Bool
            if here == nil, let t = (d["with_player"] as? String)?.lowercased() {
                here = ["true", "yes"].contains(t) ? true : ["false", "no"].contains(t) ? false : nil
            }
            return Whereabout(name: String(name.prefix(60)), at: String(at.prefix(160)), doing: String(f("doing").prefix(120)),
                              heading: none ? "" : String(heading.prefix(120)), here: here)
        }
    }

    /// Takes a name used to address someone out of a reply: "You are safe now, Simon." becomes
    /// "You are safe now." and "Simon, come here" becomes "Come here".
    static func dropName(_ name: String, from s: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        guard first.count > 1 else { return s }
        let n = NSRegularExpression.escapedPattern(for: first)
        var out = s.replacingOccurrences(of: ",\\s*" + n + "\\b", with: "", options: .regularExpression)
        // "Simon, come here" becomes "Come here" (capitalised only where a sentence or a quote begins).
        if let re = try? NSRegularExpression(pattern: "\\b" + n + ",\\s*([a-z])") {
            for m in re.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)).reversed() {
                let ns = out as NSString
                let letter = ns.substring(with: m.range(at: 1))
                let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
                let starts = before.isEmpty || ".!?\"“\n".contains(before.last!)
                out = ns.replacingCharacters(in: m.range, with: starts ? letter.uppercased() : letter)
            }
        }
        return out
    }

    /// The same, but only outside quotation marks: characters may say the name, the narration may not.
    static func dropNameFromNarration(_ name: String, from s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\"[^\"]*\"|“[^”]*”") else { return s }
        let ns = s as NSString
        var out = ""
        var at = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += dropName(name, from: ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            out += ns.substring(with: m.range)
            at = m.range.location + m.range.length
        }
        return out + dropName(name, from: ns.substring(from: at))
    }

    /// Whether the player has told the story their name (or someone already knew them).
    private func nameTold(_ a: Adventure) -> Bool {
        let name = a.playerName.trimmingCharacters(in: .whitespaces)
        let first = name.split(separator: " ").first.map(String.init) ?? name
        guard first.count > 1 else { return true }
        return a.transcript.contains { $0.role == .player && $0.text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: first))\\b", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// The briefing's body. `tight` (0 to `tightest`) drops the least needed parts first (recent events,
    /// the map, places and things), then shortens the facts, the scene and the people.
    private func briefingText(_ a: Adventure, memories: [String], director: [String], withFacts: Bool = true, tight: Int = 0) -> String {
        var lines: [String] = []
        if withFacts {
            let f = factsText(a)
            if !f.isEmpty { lines.append(clip(f, [900, 800, 650, 500][min(tight, 3)])); lines.append("") }
        }
        if tight == 0, !a.mapText.isEmpty, a.places.count > 2 { lines.append("Mission map: " + a.mapText) }
        if a.setup.simulator {
            lines.append("Player's goal" + (movedOn(a) ? " when they set out (they have since moved on; follow them, do not steer back): " : ": ")
                         + (a.setup.goal.isEmpty ? "(open: follow their lead)" : a.setup.goal))
            if !a.goalProgress.isEmpty { lines.append("Progress: " + a.goalProgress) }
        } else if !a.beats.isEmpty {
            let next = a.beats.first { !$0.done }
            lines.append("Story steps: " + a.beats.map { ($0.done ? "[done] " : $0 == next ? "[now] " : "[later] ") + $0.text }.joined(separator: "; "))
        }
        let descChars = [200, 160, 120, 90][min(tight, 3)]
        let people = a.cast.map { "\($0.name)" + ($0.role.isEmpty ? "" : " (\($0.role))") + ": " + clip($0.desc.components(separatedBy: " Lately: ").first ?? $0.desc, descChars)
            + ($0.wants.isEmpty ? "" : " Wants: " + clip($0.wants, tight > 0 ? 60 : 100)) }
        if !people.isEmpty { lines.append("People: " + people.joined(separator: " | ")) }
        let recent = (a.transcript.suffix(2).map(\.text) + [a.location]).joined(separator: " ").lowercased()
        let things = a.lore.filter { $0.kind != .person && !$0.desc.isEmpty && recent.contains($0.name.lowercased()) }.prefix(tight == 0 ? 5 : 2)
        if tight == 0, a.things.isEmpty, !things.isEmpty { lines.append("Places and things here: " + things.map { "\($0.name): " + clip($0.desc, tight == 0 ? 160 : 100) }.joined(separator: " | ")) }
        let hidden = hiddenPeople(a)
        if !hidden.isEmpty {
            lines.append("Not yet introduced by name (call them by role until the story reveals it): " + hidden.map { "\"\($0.role)\" is \($0.name)" }.joined(separator: "; "))
        }
        if !memories.isEmpty {
            lines.append("")
            lines.append("RELEVANT MEMORIES (older moments and lore that bear on this reply; facts the player set win over them)")
            lines.append(contentsOf: memories.map { "- " + $0 })
        }
        lines.append("")
        lines.append("DIRECTOR NOTES FOR THIS REPLY")
        lines.append(contentsOf: director.map { "- " + $0 })
        return lines.joined(separator: "\n")
    }

    /// The player has left the place the story opened in.
    private func movedOn(_ a: Adventure) -> Bool {
        guard a.places.count > 1, let first = a.places.first, !a.location.isEmpty else { return false }
        return a.location.caseInsensitiveCompare(first) != .orderedSame
    }

    /// Three-word phrases that keep coming back in the last few replies (small models fall into tics).
    private func repeatedPhrases(_ a: Adventure) -> [String] {
        let gm = a.transcript.filter { $0.role == .gm }.suffix(5).map(\.text)
        guard gm.count >= 2 else { return [] }
        var counts: [String: Int] = [:]
        for t in gm {
            let w = t.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
            var seen = Set<String>()
            if w.count >= 3 { for i in 0..<(w.count - 2) { seen.insert(w[i..<(i + 3)].joined(separator: " ")) } }
            for g in seen { counts[g, default: 0] += 1 }
        }
        let common: Set<String> = ["you can see", "one of the", "the end of", "out of the", "as if to", "you feel a", "in front of", "the rest of"]
        return counts.filter { $0.value >= 3 && !common.contains($0.key) }.map { "\"\($0.key)\"" }.prefix(4).map { $0 }
    }

    // MARK: Memory

    private func remember(_ exchange: String) async {
        // Each reply is filed by `rebuild`. What is left here: names the story has revealed, and
        // folding old turns into chapters.
        guard let start = adventure, var a = adventure else { return }
        // A person's name counts as revealed once the story has said it.
        let told = exchange.components(separatedBy: "THE STORY:").last ?? ""
        for i in a.lore.indices where a.lore[i].kind == .person && !a.lore[i].known {
            let first = a.lore[i].name.split(separator: " ").first.map(String.init) ?? a.lore[i].name
            if told.contains(a.lore[i].name) || (first.count > 2 && told.contains(first)) { a.lore[i].known = true }
        }

        // Fold old turns into a chapter summary so the prompt stays short.
        let unsummarised = a.transcript.count - a.summarisedTurns
        if unsummarised > 12 {
            let chunk = a.transcript[a.summarisedTurns..<(a.summarisedTurns + 6)]
            let text = chunk.map { ($0.role == .player ? "PLAYER: " : "STORY: ") + $0.text }.joined(separator: "\n\n")
            if let summary = try? await llm.complete(system: nil, prompt: Prompts.chapter + "\n\n" + text, options: .init(maxTokens: 160, temperature: 0.3)),
               !summary.isEmpty {
                a.chapters.append(summary)
                a.summarisedTurns += 6
            }
        }
        guard adventure?.id == a.id else { return }
        // Keep anything the turn changed meanwhile (transcript, clock).
        if let now = adventure {
            a.transcript = now.transcript
            a.elapsed = now.elapsed
            a.lastSendAt = now.lastSendAt
            a.turnTimes = now.turnTimes
            a.left = now.left
            a.ended = now.ended
            a.lastDirector = now.lastDirector
            a.bible = now.bible
            a.notes = now.notes
            a.notesTurn = now.notesTurn
            a.notesStale = now.notesStale
            a.bibleTurn = now.bibleTurn
            a.facts = now.facts
            a.fixes = now.fixes
            a.nextMove = now.nextMove
            a.scene = now.scene
            a.storyTime = now.storyTime
            a.clock = now.clock
            a.timeline = now.timeline
            a.whereabouts = now.whereabouts
            a.carrying = now.carrying
            a.things = now.things
            a.placeThings = now.placeThings
            // Entries the player edited or added in the World panel meanwhile win.
            for e in now.lore where e.byPlayer {
                if let i = a.lore.firstIndex(where: { $0.id == e.id }) { a.lore[i] = e } else { a.lore.append(e) }
            }
            a.lore.removeAll { e in !e.isPlayer && !now.lore.contains { $0.id == e.id } && start.lore.contains { $0.id == e.id } }
        }
        adventure = a
        library.save(a)
        refreshVocabulary()
    }

    // MARK: Housekeeping (the web app's slow job: bible refresh and the showrunner's notes)

    private func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }

    private func refreshVocabulary() {
        guard let a = adventure else { return }
        dictation.vocabulary = a.cast.flatMap { $0.name.split(separator: " ").map(String.init) } + [a.location, a.playerName].filter { !$0.isEmpty }
    }
}

// MARK: - The room builder

extension StoryEngine {
    /// Lays out the room the player is in with the storyteller's help, if it has only been drawn
    /// from its template so far: three short questions (the shell, the things, the people), each
    /// held to a grammar so the model only picks from lists, then one push-back question for any
    /// object whose spot broke a rule. Code places everything; every decision goes on the room's
    /// log and shows on the map as it happens. Whatever the model can't answer comes from the template.
    /// What a named thing really is, in plain yes/no questions the small model answers well, one at
    /// a time: a smell or sound, a material, something worn, part of the building, or a real object.
    /// Returns "a thing in the room", or what it is instead.
    /// What each name turned out to be, so the same thing is never asked about twice.
    static var whatIsKnown: [String: String] = [:]
    /// The one word that names each thing ("record" for "crackling jazz record"), so two names for
    /// one thing can be noticed before both are drawn.
    static var headKnown: [String: String] = [:]

    /// The question that names the object: one noun from the name itself, or none. Small models
    /// answer this far better than "is it a material?" ("polished oak" kept passing that one).
    static func nounQuestion(_ name: String) -> String {
        "Is there a thing in \"" + name + "\" you could hold or bump into? Name the thing itself, one word taken from those words, or none. The other words only describe it. For example: \"long mahogany bar\" → bar; \"crackling jazz record\" → record; \"paper lanterns\" → lantern; \"silver chain\" → chain; \"a cloth\" → cloth; \"a needle\" → needle; \"brass lamp\" → lamp; \"polished oak\" → none (just wood); \"soft jazz\" → none (a sound); \"warm cinnamon\" → none (a smell); \"golden glow\" → none (a light); \"vanilla dust\" → none (just dust)."
    }

    /// Whether a long thing runs lengthwise along a wall.
    static func alongQuestion(_ name: String) -> String {
        "Which side of the \"" + name + "\" goes against a wall, if any?"
    }

    /// The answers to the wall question, and what each means on the grid.
    static let wallSides: [(String, String?)] = [
        ("a long side, right up against the wall (like a dresser, a sofa or a bookcase)", "flush"),
        ("a long side, with a walkway between it and the wall for whoever works behind it (like a bar, a shop counter or a sales desk)", "staff"),
        ("one end, with its head against the wall (like a bed)", "end"),
        ("none, it stands free in the room (like a dining table)", nil),
    ]
    static func wallSide(_ answer: String) -> String? {
        wallSides.first { $0.0 == answer }?.1 ?? nil
    }
    static func wallSideLabel(_ along: String?) -> String {
        switch along { case "flush": "long side against the wall"; case "staff": "long side to the wall, walkway behind"; case "end": "end against the wall"; default: "stands free" }
    }

    /// Whether something can be in someone's hands, as the model sorted it: only small or worn
    /// things. Furniture, a smell or smoke, a part of someone's body never is. Not sorted yet: yes.
    static func holdable(_ name: String) -> Bool {
        let known = whatIsKnown[name.lowercased()] ?? whatIsKnown[Fovea.bare(name).lowercased()]
        guard let w = known else { return true }
        return w.hasPrefix("small") || w.hasPrefix("worn")
    }

    static func whatIs(_ name: String, noun: (String) async -> String, choose: (String, [String]) async -> String, yesNo: (String) async -> Bool?) async -> String {
        let key = name.lowercased()
        if let known = whatIsKnown[key] { return known }
        // "a glass" is asked about as "glass", so no question reads "the a glass".
        let bare = name.replacingOccurrences(of: #"^(?i)(a|an|the|some)\s+"#, with: "", options: .regularExpression)
        // First: which word names the object? It has to be one of the name's own words, and not
        // "none": a material, a smell or a glow names no object and stops here.
        var what = "a thing in the room"
        // A one-word name is its own naming word: nothing to ask ("key" came back as "bar").
        let oneWord = !bare.contains(" ")
        let said = oneWord ? bare.lowercased() : (await noun(nounQuestion(name))).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .\"'"))
        let words = Continuity.wordSet(name)
        let saidWords = Continuity.wordSet(said)
        let fromName = saidWords.contains { w in words.contains { $0.hasPrefix(w) || w.hasPrefix($0) } }
        // The model's own word is a kind of furniture the map already draws (a lamp, a counter, a
        // bar): that settles it, with nothing more to ask.
        let knownKind = fromName && !said.hasPrefix("none") && !["other", "small"].contains(Rules.icon(for: said))
        if knownKind {
            headKnown[key] = said
            whatIsKnown[key] = what
            return what
        }
        // Then one choice about that one word alone, so the other words can't pull the answer
        // ("silver" chain read as a material, "crackling" record as a sound). With no word from the
        // name, its last word is asked about ("coins", "tray"). This one choice is the whole funnel:
        // not on the map at all (stop here), part of the building (stop), on a person, small on a
        // surface, or standing on the floor.
        let head: String = (fromName && !said.hasPrefix("none") && !said.isEmpty) ? said : (bare.split(separator: " ").last.map(String.init) ?? bare)
        headKnown[key] = head.lowercased()
        // Short answers (the long ones came back cut off or garbled, "a lamp" for tobacco leaves),
        // with what each means spelled out in the question.
        // The model leaned on the last choice ("furniture" for a whiskey, a napkin, someone's
        // hands), so the harmless one comes last: a small thing never takes a square of floor.
        let sorts: [(String, String)] = [
            ("not solid", "not an object (a material, smell, sound, light or feeling)"),
            ("body", "part of a person's body"),
            ("building", "part of the building or the sky"),
            ("furniture", "a thing in the room"),
            ("worn", "worn or carried by someone"),
            ("small", "small, set on a surface"),
        ]
        // The whole name goes with it, so "paper" in "the scent of paper" is read as a smell.
        let asIn = head.caseInsensitiveCompare(bare) == .orderedSame ? "" : " (as in \"" + name + "\")"
        let q = "A " + head + asIn + ": which is it?\nnot solid = a smell, smoke or steam, a sound, a light, a feeling, or stuff like wood, water, dust or mahogany\nbody = part of a person or how they look: hands, eyes, a smile, a frame, a shiver, hair\nbuilding = part of the building or the sky: a wall, a window, a door, a beam, a skylight\nfurniture = big and heavy, standing on the floor, too big to lift with one hand: a table, a stool, a piano, a bar, a gramophone\nworn = worn on someone's body: a dress, a smock, glasses, a hat, a ring, a coat\nsmall = picked up with one hand and set on a table, bar or shelf: a glass, a drink, a napkin, a key, a cloth, a book, a record, fabric, a needle"
        let sorted = Self.sortKey(await choose(q, Self.sortLabels.map(\.1)))
        // Anything else said counts as small: it can't take a square of floor by mistake.
        what = sorts.first(where: { sorted.hasPrefix($0.0) })?.1 ?? "small, set on a surface"
        whatIsKnown[key] = what
        return what
    }

    /// Each sort as the model picks it: the word, then a short reminder in the answer itself, so
    /// a small model reads what it is choosing ("soft jazz music" is not solid, not small).
    static let sortLabels: [(String, String)] = [
        ("not solid", "not solid - a sound, music, smell, smoke, light or feeling"),
        ("body", "body - part of a person, hands, eyes, hair, a smile"),
        ("building", "building - a wall, window, door or the sky"),
        ("furniture", "furniture - big, on the floor, a table, stool or gramophone"),
        ("worn", "worn - clothes, a coat, a hat, a ring"),
        ("small", "small - lifted in one hand, a glass, a book, a record"),
    ]
    /// The sort word from a picked label ("worn - clothes…" → "worn").
    static func sortKey(_ s: String) -> String {
        let l = s.lowercased().trimmingCharacters(in: .whitespaces)
        return sortLabels.first { l.hasPrefix($0.0) }?.0 ?? l
    }

    /// How a piece of furniture meets a wall, as the entity batch offers it: the answer, what it
    /// means on the grid, and the space it keeps clear.
    static let wallLabels: [(String, String?, String?)] = [
        ("free", nil, nil),
        ("free, space all round", nil, "all round"),
        ("against a wall", "flush", nil),
        ("against a wall, space in front", "flush", "in front"),
        ("against a wall, walkway behind", "staff", "behind"),
        ("head to a wall", "end", nil),
    ]

    /// After the opening only: the map was drawn from the story the player picked, before the
    /// opening was told. What the opening itself names that isn't on the map yet (a gramophone, a
    /// jar of coins) is added now, in two batches: what each new thing is, then where it goes.
    /// After this the room is locked: later replies add nothing to it.
    private func topUpRoom(story: String) async {
        guard let a0 = adventure, var r = a0.room, r.name.caseInsensitiveCompare(a0.location) == .orderedSame else { return }
        defer { rebuildStep = "" }
        func ask(_ label: String, _ prompt: String, _ grammar: String, _ tokens: Int) async -> [String: Any] {
            rebuildStep = label
            let q0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                               options: .init(maxTokens: tokens, temperature: 0.3, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
            noteQ("room", label, raw, since: q0)
            let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value < 0x2E80 }))
            return JSONExtract.object(plain) ?? Self.salvageJSON(plain)
        }
        func str(_ d: [String: Any], _ k: String) -> String { ((d[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func num(_ d: [String: Any], _ k: String) -> Int {
            if let n = d[k] as? Int { return n }
            if let n = d[k] as? Double { return Int(n.rounded()) }
            return Int(str(d, k).filter(\.isNumber)) ?? 0
        }
        let onMap: [String] = r.things.filter { $0.kind == .object }.map(\.name) + r.things.flatMap { $0.holding } + r.things.map(\.wearing).filter { !$0.isEmpty }
        let who: [String] = ["nobody", "you"] + a0.cast.filter { !$0.isPlayer }.map(\.name)
        var base = "You keep the top-down plan of a room in an audio story true to what the story says."
        base += "\n\nTHE ROOM: " + r.name + ", \(r.width) by \(r.depth) metres"
        base += "\nALREADY ON THE MAP: " + (onMap.isEmpty ? "nothing" : onMap.joined(separator: ", "))
        base += "\n\n" + story + "\n\n"
        let qParts: [String] = [
            base,
            "QUESTION: List only the things this story names in the room that are NOT already on the map, at most 4, in the story's own words. Nothing already on the map under another name (a counter that is the bar), and nothing that is not a thing (a sound, a smell, a light). If a sound comes from a thing that is not on the map yet (music from a gramophone), list that thing. An empty list if there are none.\n",
            "name: the thing itself, a few plain words (a gramophone, not \"jazz playing on the gramophone\").\n",
            "sort: not solid = a smell, smoke, steam, sound, light, feeling, or stuff like wood or dust; body = part of a person; building = a wall, window, door, beam or the sky; furniture = big and heavy, on the floor (a table, a piano, a gramophone); worn = on someone's body (a hat, a coat, a ring); small = picked up with one hand and set on a table, bar or shelf (a glass, a jar, a record)\n",
            "kind: furniture only, one of KINDS; small for everything else\n",
            "wall: furniture only, how it meets a wall (free; free, space all round; against a wall; against a wall, space in front; against a wall, walkway behind; head to a wall); free for everything else\n",
            "len: its long side in whole metres. stools: 0. who: for worn things, who wears it, from WHO; nobody for everything else\n",
            "KINDS: " + Rules.kinds.joined(separator: "; ") + "\nWHO: " + who.joined(separator: "; "),
            "\nOutput ONLY one JSON object:\n{\"things\":[{\"name\":\"a short name\",\"sort\":\"one sort\",\"kind\":\"one of KINDS\",\"wall\":\"one wall answer\",\"len\":1,\"stools\":0,\"who\":\"one of WHO\"}]}\nThe form:",
        ]
        let m = await ask("Anything the opening added?", qParts.joined(),
                          JSONGrammar.roomEntities(sorts: Self.sortLabels.map(\.1), kinds: Rules.kinds,
                                                   walls: Self.wallLabels.map(\.0), who: who, max: 4), 260)
        guard !Task.isCancelled else { return }
        let listed: [[String: Any]] = ((m["things"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        let castNames = Set(a0.cast.map { $0.name.lowercased() })
        var furniture: [Thing] = []
        var smalls: [String] = []
        var seen: [String] = onMap
        for d in listed.prefix(4) {
            let name = str(d, "name")
            guard name.count >= 3, !Self.echoesPrompt(name), !castNames.contains(name.lowercased()),
                  !seen.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame || Self.similar($0, name) }) else { continue }
            let sort = Self.sortKey(str(d, "sort"))
            guard ["furniture", "worn", "small"].contains(sort) else { r.log.append("refuse: " + name + " (" + sort + ")"); continue }
            seen.append(name)
            if sort == "worn" {
                let owner = str(d, "who")
                let t: Thing? = owner == "you" ? r.player : r.named(owner)
                if let t, let i = r.index(t.id) {
                    r.things[i].wearing = r.things[i].wearing.isEmpty ? name : r.things[i].wearing + ", " + name
                    r.log.append("edit: " + name + " → on " + owner + " (from the opening)")
                }
                continue
            }
            var kind = str(d, "kind").lowercased()
            if !Rules.kinds.contains(kind) || kind == "other" { kind = Rules.icon(for: name) }
            // The model's sort decides: furniture (a gramophone) never goes to hands or a shelf
            // because its name happens to match a small kind.
            if sort == "small" { smalls.append(name); continue }
            if Rules.rule(kind).small { kind = "other" }
            var t = Thing(kind: .object, name: name, icon: kind)
            let rr = Rules.rule(kind)
            let l = max(1, min(num(d, "len"), max(r.width, r.depth) - 2, 6)), w = max(1, min(min(rr.w, rr.d), 3))
            t.w = max(l, w); t.d = min(l, w)
            if let side = Self.wallLabels.first(where: { $0.0 == str(d, "wall") }) {
                if t.w != t.d || rr.w != rr.d { t.along = side.1 }
                t.space = side.1 == "staff" ? "behind" : side.2
                if t.along == "staff" || t.along == "flush" { t.d = 1; t.w = max(t.w, 2) }
            }
            furniture.append(t)
        }
        if !furniture.isEmpty {
            let menu = Zone.menu(r)
            let lines = furniture.enumerated().map { "\($0.offset + 1) = the " + Zone.short($0.element.name) }
            let q = base + "QUESTION: Where does each of these new things go, as the story has it?\n" + lines.joined(separator: "\n") + "\nPLACES: " + menu.joined(separator: "; ")
                + "\nOutput ONLY one JSON object, one of PLACES for each number:\n{" + furniture.indices.map { "\"\($0 + 1)\":\"one of PLACES\"" }.joined(separator: ",") + "}\nThe form:"
            let pm = await ask("Where do the new things go?", q, JSONGrammar.roomRetry(allowed: furniture.map { _ in menu }), 24 + 16 * furniture.count)
            for (i, t) in furniture.enumerated() {
                let z = Zone.parse(str(pm, String(i + 1))) ?? RoomBuilder.defaultZone(t.icon, in: r)
                if Placer.place(&r, t, zone: z).placed {
                    r.log.append("place: " + t.name + " → " + z.text + " (from the opening)")
                } else {
                    Placer.fallback(&r, t, near: z)
                    r.log.append("move: " + t.name + " → nearest allowed spot (from the opening)")
                }
            }
        }
        let tops = Array(Set(r.objects.filter { Rules.surfaces.contains($0.icon) && $0.on == nil }.map { Zone.short($0.name) })).sorted()
        let hands = r.people.filter { $0.kind == .person }.map { Cards.first($0.name) + "'s hands" }
        if !smalls.isEmpty, !(tops + hands).isEmpty {
            let opts = tops + hands
            let lines = smalls.enumerated().map { "\($0.offset + 1) = the " + Zone.short($0.element) }
            let q = base + "QUESTION: Where is each of these, as the story has it?\n" + lines.joined(separator: "\n") + "\nCHOICES: " + opts.joined(separator: "; ")
                + "\nOutput ONLY one JSON object, one of CHOICES for each number:\n{" + smalls.indices.map { "\"\($0 + 1)\":\"one of CHOICES\"" }.joined(separator: ",") + "}\nThe form:"
            let om = await ask("Where are the new small things?", q, JSONGrammar.roomRetry(allowed: smalls.map { _ in opts }), 24 + 14 * smalls.count)
            for (n, item) in smalls.enumerated() {
                let said = str(om, String(n + 1))
                if said.hasSuffix("'s hands"), Self.holdable(item), let p = r.people.first(where: { Cards.first($0.name) + "'s hands" == said }), let i = r.index(p.id), r.things[i].holding.count < 3 {
                    r.things[i].holding.append(item)
                    r.log.append("edit: " + item + " → in " + p.name + "'s hands (from the opening)")
                } else if let top = tops.first(where: { $0 == said }) ?? tops.first,
                          Placer.place(&r, Thing(kind: .object, name: item, icon: "small"), zone: .on(top)).placed {
                    r.log.append("place: " + item + " → on the " + top + " (from the opening)")
                }
            }
        }
        guard !Task.isCancelled, var a = adventure, let i = a.rooms.firstIndex(where: { $0.id == r.id }) else { return }
        r.log = Array(r.log.suffix(80))
        a.rooms[i] = r
        adventure = a
        library.save(a)
    }

    fileprivate func furnishRoom(story: String) async {
        // A room is drawn once: only a place with no room yet is laid out, and never again after.
        guard let a0 = adventure, !a0.location.isEmpty,
              !a0.rooms.contains(where: { $0.name.caseInsensitiveCompare(a0.location) == .orderedSame }) else { return }
        let placeName = a0.location
        let roomID = UUID()
        let previous: Room? = a0.room
        let from: String = previous?.name ?? ""
        let fromName = from
        defer { rebuildStep = "" }

        /// Shows the room as it stands, so the map follows each decision. The first show makes it
        /// the player's room (and takes the player out of the one they left).
        func show(_ r: Room, pause: Double = 0.4) async {
            guard var a = adventure else { return }
            if let i = a.rooms.firstIndex(where: { $0.id == roomID }) { a.rooms[i] = r } else {
                for k in a.rooms.indices { a.rooms[k].things.removeAll { $0.kind == .player } }
                a.rooms.append(r)
            }
            a.roomID = roomID
            adventure = a
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
        }
        func ask(_ label: String, _ prompt: String, _ grammar: String, _ tokens: Int) async -> [String: Any] {
            rebuildStep = label
            let q0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                               options: .init(maxTokens: tokens, temperature: 0.3, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
            noteQ("room", label, raw, since: q0)
            let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value < 0x2E80 }))
            return JSONExtract.object(plain) ?? Self.salvageJSON(plain)
        }
        func str(_ d: [String: Any], _ k: String) -> String { ((d[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        let about: String = Cards.placeCard(a0)?.desc ?? ""
        var base = "You lay out a room for an audio story, as a top-down plan. Answer only from the lists given; be true to the story, its time and place."
        base += "\n\nTHE ROOM: " + placeName
        if !about.isEmpty { base += "\nWHAT IT IS LIKE: " + clip(about, 240) }
        // The door the player came through, as the last room had it: the new room keeps to that.
        let wayIn = previous?.doors.first(where: { d in
            let to = Zone.short(d.leadsTo).lowercased(), here = Zone.short(placeName).lowercased()
            return !to.isEmpty && (to == here || to.contains(here) || here.contains(to))
        })
        // No door of the last room leads here, so this is another building: the player went out
        // by the last room's way outside (the coast road) and comes in from there. This room's
        // entrance opens onto that road, never straight back into the last room.
        let roomNames = Set(a0.rooms.map { Zone.short($0.name).lowercased() })
        let wayOut = wayIn == nil ? previous?.doors.first(where: { d in
            let to = Zone.short(d.leadsTo).lowercased()
            // (A door reached by stairs leads up or down inside the building, not out.)
            let byStairs = previous?.objects.contains { $0.icon == "stairs" && $0.name.lowercased().contains(to) } ?? false
            return !to.isEmpty && !roomNames.contains(to) && !byStairs
        }) : nil
        if let door = wayIn {
            if !fromName.isEmpty { base += "\nTHE PLAYER CAME FROM: " + fromName }
            base += "\nTHE WAY IN (keep to it): from " + fromName + ", " + door.leadsTo + (door.view.isEmpty ? "" : " (" + door.view + ")")
        } else if let out = wayOut {
            base += "\nTHE PLAYER CAME FROM: " + out.leadsTo + " (outside; they left " + fromName + " some way back)"
            base += "\nTHE WAY IN (keep to it): the entrance of this room opens onto " + out.leadsTo + ". " + fromName + " is another building, not behind any door here."
        } else if !fromName.isEmpty {
            base += "\nTHE PLAYER CAME FROM: " + fromName
        }
        // The set-up's place is the opening room only: a room further on is not another copy of it.
        let world = [a0.setup.world, previous == nil ? a0.setup.place : ""].filter { !$0.isEmpty }.joined(separator: ". ")
        if !world.isEmpty { base += "\nTHE WORLD: " + clip(world, 200) }
        // What is already true (the premise, the time, the facts): the room, its weather, doors and
        // seats keep to it ("July, late afternoon, a moving train heading north, a window seat").
        base += "\nTHE PREMISE (keep to it): " + clip(Cards.premise(a0), 400)
        base += "\nWHEN: " + Fovea.whenWhere(a0)
        let known = a0.facts.filter { !$0.contains(" uses ") }.suffix(8)
        if !known.isEmpty { base += "\nFACTS (keep to them):\n" + known.map { "- " + clip($0, 140) }.joined(separator: "\n") }
        base += "\n\n" + story + "\n\n"

        // 1. The shell.
        let q1 = base + "QUESTION: What is this room's type, and how big would a real one like it be, in metres (true to its time and place: a 1920s speakeasy, a ship's cabin, a cathedral)? Width is west to east, depth is north to south. List its doors (which wall, where each leads, whether you reach it by a door or by stairs up or down, and what lies beyond it: what kind of room or place, and two or three things there, true to the story; one leads back the way the player came) and its windows (windows in the walls only, never skylights; which wall, and what is seen through them; none outdoors). Then one line on the room's air inside: only its smells and ambience (smoky, damp, warm; no people, no action), and one on the weather and world outside.\nTYPES: " + RoomBuilder.types.joined(separator: "; ") + "\nIndoors, or in the open air (a street, a riverbank, a park, a field, a beach)? In the open air there are no walls and no windows: its doors are just the ways you can go from there.\nOutput ONLY one JSON object:\n{\"where\":\"indoors or in the open air\",\"type\":\"one of TYPES\",\"width\":9,\"depth\":7,\"doors\":[{\"wall\":\"north, south, east or west\",\"leads_to\":\"where it goes\",\"by\":\"a door or stairs\",\"beyond\":\"what kind of place it is and two or three things there\"}],\"windows\":[{\"wall\":\"north, south, east or west\",\"view\":\"what is seen\"}],\"inside\":\"its smells and ambience, one line\",\"outside\":\"the weather and world outside, one line\"}\nThe form:"
        let m1 = await ask("How big is this room, in metres?", q1, JSONGrammar.roomShell(types: RoomBuilder.types), 260)
        guard !Task.isCancelled else { return }
        var type = str(m1, "type").lowercased()
        if !RoomBuilder.types.contains(type) { type = RoomBuilder.type(for: placeName + " " + about) }
        // The model says it is in the open air: then it is an outdoor place, whatever type it picked
        // (a riverbank drawn as a shop got walls, a door and windows).
        if str(m1, "where") == "in the open air", !RoomBuilder.outdoor.contains(type) {
            let guess = RoomBuilder.type(for: placeName + " " + about)
            type = RoomBuilder.outdoor.contains(guess) ? guess : "open air"
        }
        let tp = RoomBuilder.template(type)
        func metres(_ k: String) -> Int? {
            if let n = m1[k] as? Int { return n }
            if let n = m1[k] as? Double { return Int(n.rounded()) }
            return Int(str(m1, k).filter(\.isNumber))
        }
        let said: (Int, Int)? = metres("width").flatMap { w in metres("depth").map { (w, $0) } }
        let crowd = 1 + a0.whereabouts.filter { $0.here != false }.count + 6
        var r = RoomBuilder.shell(name: placeName, type: type, size: tp.size, from: from, crowd: crowd, metres: said)
        if let said { r.log.append("size: the model said \(said.0) × \(said.1) m; drawn \(r.width) × \(r.depth) m") }
        r.id = roomID
        r.built = true
        r.inside = Self.echoesPrompt(str(m1, "inside")) ? "" : str(m1, "inside")
        r.outside = Self.echoesPrompt(str(m1, "outside")) ? "" : str(m1, "outside")
        // Doors and windows, spread along their walls so none overlap.
        var used: [Wall: [Int]] = [:]
        func slot(_ wall: Wall, width: Int) -> Int? {
            let len = r.length(of: wall)
            guard len >= width + 2 else { return nil }
            let taken = used[wall] ?? []
            let order = (1...(len - width - 1)).sorted { abs($0 - len / 2) < abs($1 - len / 2) }
            for at in order where !(at..<(at + width)).contains(where: { i in taken.contains { abs($0 - i) <= 1 } }) {
                used[wall, default: []] += Array(at..<(at + width))
                return at
            }
            return nil
        }
        var doors: [Opening] = []
        // A way up or down the model said is reached by stairs: the stairs go in the room by it.
        var stairWays: [(Wall, String)] = []
        for d in ((m1["doors"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }).prefix(3) {
            guard let wall = Wall(rawValue: str(d, "wall").lowercased()), let at = slot(wall, width: 1) else { continue }
            let to = Self.echoesPrompt(str(d, "leads_to")) ? "" : str(d, "leads_to")
            // A door keeps what lies beyond it (in `view`), so the room through it is built from that.
            let beyond = Self.echoesPrompt(str(d, "beyond")) ? "" : str(d, "beyond")
            doors.append(Opening(wall: wall, at: at, leadsTo: to, view: (str(d, "by") == "stairs" ? "up or down stairs: " : "") + beyond))
            if str(d, "by") == "stairs" { stairWays.append((wall, to)) }
        }
        if doors.isEmpty, let at = slot(.south, width: 1) { doors = [Opening(wall: .south, at: at, leadsTo: from.isEmpty ? "outside" : from)] }
        if !from.isEmpty, !doors.isEmpty, !doors.contains(where: { $0.leadsTo.caseInsensitiveCompare(from) == .orderedSame }) { doors[0].leadsTo = from }
        r.doors = doors
        var windows: [Opening] = []
        if !RoomBuilder.outdoor.contains(type) {
            for w in ((m1["windows"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }).prefix(2) {
                // Windows are in the walls; a skylight or anything overhead is not on a floor plan.
                guard Set(str(w, "view").lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)).isDisjoint(with: Rules.overhead),
                      let wall = Wall(rawValue: str(w, "wall").lowercased()), let at = slot(wall, width: 2) else { continue }
                windows.append(Opening(wall: wall, at: at, width: 2, view: Self.echoesPrompt(str(w, "view")) ? "" : str(w, "view")))
            }
        }
        r.windows = windows
        r.log.append("shell: " + r.name + " (" + type + ", \(r.width) × \(r.depth) m, \(doors.count) door" + (doors.count == 1 ? "" : "s")
                     + ", \(windows.count) window" + (windows.count == 1 ? "" : "s") + ")")
        await show(r, pause: 0.6)

        // 2. The things, in one batch: every thing the story names here, each with its sort, kind,
        // how it meets the wall, its length, its stools and who wears it, as one flat array. The
        // grammar holds every value to its list, so the model spends its tokens on the answers.
        let who: [String] = ["nobody", "you"] + a0.cast.filter { !$0.isPlayer }.map(\.name)
        let wallLabels = Self.wallLabels
        let q2Parts: [String] = [
            base + "THE ROOM SO FAR: a " + type + ", \(r.width) by \(r.depth) metres.\n",
            "QUESTION: List every thing the story names in this room, at most 7, each once, in the story's own words (two only if the story says there are two): furniture (a staircase or ladder inside the room too), small things on it, and things people wear or carry; plus the one or two pieces of furniture the scene can't do without (a bar to sit at, a bed to sleep in). Leave out lamps, plants, rugs and decoration unless the story names them.\n",
            "name: the thing itself, a few plain words (a gramophone, not \"jazz playing on the gramophone\"). Where it is, or what it hangs on or sits in, is never part of its name: \"a brass hat on a hook\" is a brass hat; \"a plant near the aisle\" is a small potted plant. A plant or a small object is never part of the building. A sound, music or a smell is not solid; if the story has a thing making it (music from a gramophone or a radio), list that thing on its own too.\n",
            "For each thing:\n",
            "sort: not solid = a smell, smoke, steam, sound, light, feeling, or stuff like wood, water or dust; body = part of a person (hands, eyes, a smile); building = a wall, window, door, beam or the sky; furniture = big and heavy, on the floor, too big to lift with one hand (a table, a stool, a piano, a bar, a gramophone, a staircase or ladder inside the room); worn = on someone's body (a dress, glasses, a hat, a ring, a coat); small = picked up with one hand and set on a table, bar or shelf (a glass, a drink, a key, a cloth, a book, a record)\n",
            "kind: furniture only, one of KINDS; small for everything else\n",
            "wall: furniture only, how it meets a wall: free (a dining table); free, space all round (a pool table); against a wall (a dresser, a sofa); against a wall, space in front (a fireplace, a bookcase); against a wall, walkway behind (a bar or shop counter someone works behind); head to a wall (a bed). free for everything else\n",
            "len: its long side in whole metres (1 for small things)\n",
            "stools: for a bar or counter, how many stools customers sit on along it (most have three to six); for a table, how many chairs around it (a kitchen or dining table usually two to six); 0 for everything else\n",
            "who: for worn things, who wears or carries it, from WHO; nobody for everything else\n",
            "KINDS: " + Rules.kinds.joined(separator: "; ") + "\nWHO: " + who.joined(separator: "; "),
            "\nOutput ONLY one JSON object:\n{\"things\":[{\"name\":\"a short name\",\"sort\":\"one sort\",\"kind\":\"one of KINDS\",\"wall\":\"one wall answer\",\"len\":2,\"stools\":0,\"who\":\"one of WHO\"}]}\nThe form:",
        ]
        let q2 = q2Parts.joined()
        let m2 = await ask("What does the story name in this room?", q2,
                           JSONGrammar.roomEntities(sorts: Self.sortLabels.map(\.1), kinds: Rules.kinds,
                                                    walls: wallLabels.map(\.0), who: who, max: 7), 420)
        guard !Task.isCancelled else { return }
        let castNames = Set(a0.cast.map { $0.name.lowercased() })
        let listed: [[String: Any]] = ((m2["things"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        r.log.append("ask: what does the story name here? → " + (listed.isEmpty ? "nothing" : listed.map { str($0, "name") + " (" + str($0, "sort") + ")" }.joined(separator: ", ")))
        var wanted: [Thing] = []
        var worn: [(String, String)] = []
        // Small things (a glass, a tray of coins) go on a surface once the furniture is down.
        var smalls: [String] = []
        var kept: [String] = []
        // How many stools the model gave each bar or counter, by its id.
        var stoolsFor: [UUID: Int] = [:]
        func num(_ d: [String: Any], _ k: String) -> Int {
            if let n = d[k] as? Int { return n }
            if let n = d[k] as? Double { return Int(n.rounded()) }
            return Int(str(d, k).filter(\.isNumber)) ?? 0
        }
        for d in listed.prefix(7) {
            let name = str(d, "name")
            // The same name twice is dropped by code.
            guard name.count >= 3, !Self.echoesPrompt(name), !castNames.contains(name.lowercased()),
                  !kept.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame || Self.similar($0, name) }) else { continue }
            let sort = Self.sortKey(str(d, "sort"))
            let sortLine: [String: String] = ["not solid": "not an object", "body": "part of a person's body", "building": "part of the building or the sky",
                                              "furniture": "a thing in the room", "worn": "worn or carried by someone", "small": "small, set on a surface"]
            // Anything unreadable counts as small: it can't take a square of floor by mistake.
            let what = sortLine[sort] ?? "small, set on a surface"
            Self.whatIsKnown[name.lowercased()] = what
            r.log.append("ask: what is " + name + "? → " + what)
            guard ["furniture", "worn", "small", ""].contains(sort) else { r.log.append("refuse: " + name + " (" + what + ")"); continue }
            kept.append(name)
            if sort == "worn" {
                let owner = str(d, "who")
                if !owner.isEmpty, owner != "nobody" { worn.append((owner, name)); r.log.append("edit: " + name + " → on " + owner) }
                continue
            }
            var kind = str(d, "kind").lowercased()
            if !Rules.kinds.contains(kind) || kind == "other" { kind = Rules.icon(for: name) }
            // The model's sort decides: furniture (a gramophone) never goes to hands or a shelf
            // because its name happens to match a small kind.
            if sort != "furniture" { smalls.append(name); continue }
            if Rules.rule(kind).small { kind = "other" }
            var t = Thing(kind: .object, name: name, icon: kind)
            let rr = Rules.rule(kind)
            let l = max(1, min(num(d, "len"), max(r.width, r.depth) - 2, 6)), w = max(1, min(min(rr.w, rr.d), 3))
            t.w = max(l, w); t.d = min(l, w)
            if let side = wallLabels.first(where: { $0.0 == str(d, "wall") }) {
                if t.w != t.d || rr.w != rr.d { t.along = side.1 }
                t.space = side.2
                if t.along == "staff" { t.space = "behind" }
                // Against a wall, a long piece is one metre deep (a bar, a dresser).
                if t.along == "staff" || t.along == "flush" { t.d = 1; t.w = max(t.w, 2) }
                r.log.append("ask: how does the " + Zone.short(name) + " meet the wall? → " + Self.wallSideLabel(t.along))
            }
            if Rules.staffed.contains(kind) || kind == "table" { stoolsFor[t.id] = min(max(0, num(d, "stools")), kind == "table" ? 8 : 6) }
            wanted.append(t)
        }
        // A room of this type usually has its centrepiece (a bar's bar, a bedroom's bed): the model
        // says whether this one needs it.
        // Something already listed may be it under another name (a "long mahogany counter" is the
        // bar): the model is asked before a second one is added.
        var leadFound = false
        if let lead = tp.pieces.first, !wanted.contains(where: { $0.icon == lead.icon }) {
            for t in wanted where !Rules.rule(t.icon).small && !Rules.seats.contains(t.icon) {
                let sq = "Is the \"" + t.name + "\" the " + Zone.short(lead.name) + " of this room?"
                let sm = await ask(clip(sq, 70), base + "QUESTION: " + sq + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                if str(sm, "answer").lowercased().hasPrefix("y") {
                    leadFound = true
                    if let i = wanted.firstIndex(where: { $0.id == t.id }) { wanted[i].icon = lead.icon }
                    r.log.append("ask: is the " + Zone.short(t.name) + " the " + Zone.short(lead.name) + "? → yes")
                    break
                }
            }
        }
        if !leadFound, let lead = tp.pieces.first, !wanted.contains(where: { $0.icon == lead.icon }) {
            // Asked two ways: one "no" alone doesn't leave a bar without its bar.
            let q1 = "Does this story need " + lead.name + " in this room?"
            let nm = await ask("Does it need " + lead.name + "?", base + "QUESTION: " + q1 + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
            var need = str(nm, "answer").lowercased().hasPrefix("y")
            if !need {
                let q2 = "Would anyone in this story sit at, stand at or work behind " + lead.name + " here?"
                let nm2 = await ask("Would anyone use " + lead.name + "?", base + "QUESTION: " + q2 + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                need = str(nm2, "answer").lowercased().hasPrefix("y")
            }
            r.log.append("ask: does it need " + lead.name + "? → " + (need ? "yes" : "no"))
            if need { wanted.insert(Thing(kind: .object, name: lead.name, icon: lead.icon), at: 0) }
        }
        // Big furniture first, small things last, so "on the bar" has a bar to go on.
        func rank(_ icon: String) -> Int {
            let rule = Rules.rule(icon)
            return rule.small ? 3 : (Rules.seats.contains(icon) || icon == "lamp" || icon == "plant") ? 2 : icon == "rug" ? 0 : 1
        }
        wanted.sort { rank($0.icon) < rank($1.icon) }

        // 3. Where everything goes, in one batch: a place for each piece from its own list (the
        // room's fixed areas, and beside or on the pieces listed before it). Code checks the rules;
        // whatever can't go where it was put is asked about again, all together, with only the
        // places that keep the rules.
        let storyLine = clip(about.isEmpty ? story : about, 260)
        var brief = "You lay out a room for an audio story, as a top-down plan.\nTHE ROOM: " + placeName + ", a " + type + ", \(r.width) by \(r.depth) metres"
        if !r.doors.isEmpty { brief += "; doors on the " + r.doors.map(\.wall.rawValue).joined(separator: " and ") + " wall" }
        if !r.windows.isEmpty { brief += "; windows on the " + r.windows.map(\.wall.rawValue).joined(separator: " and ") + " wall" }
        brief += ".\nTHE STORY: " + storyLine
        let fixed = Zone.menu(r)
        var menus: [[String]] = []
        for (i, t) in wanted.enumerated() {
            var m = fixed
            for o in wanted.prefix(i) where !Rules.rule(o.icon).small {
                m.append(Zone.beside(Zone.short(o.name)).text)
                if Rules.surfaces.contains(o.icon), !Rules.surfaces.contains(t.icon) { m.append(Zone.on(Zone.short(o.name)).text) }
            }
            menus.append(m)
        }
        var refused: [(Thing, Zone, String)] = []
        if !wanted.isEmpty {
            let lines = wanted.enumerated().map { "\($0.offset + 1) = the " + Zone.short($0.element.name) + ": " + menus[$0.offset].joined(separator: "; ") }
            let q = brief + "\nQUESTION: Where does each thing go, as it would in a real room like this? Each number has its own PLACES.\nPLACES:\n" + lines.joined(separator: "\n")
                + "\nOutput ONLY one JSON object, a place for each number:\n{" + wanted.indices.map { "\"\($0 + 1)\":\"one of its PLACES\"" }.joined(separator: ",") + "}\nThe form:"
            let m = await ask("Where does everything go?", q, JSONGrammar.roomRetry(allowed: menus), 24 + 16 * wanted.count)
            for (i, t) in wanted.enumerated() {
                guard !Task.isCancelled else { return }
                let z = Zone.parse(str(m, String(i + 1))) ?? RoomBuilder.defaultZone(t.icon, in: r)
                let out = Placer.place(&r, t, zone: z)
                if out.placed {
                    r.log.append("place: " + t.name + " → " + z.text)
                    await show(r)
                } else {
                    r.log.append("refuse: " + t.name + " " + z.text + " (" + out.reason + ")")
                    refused.append((t, z, out.reason))
                }
            }
        }
        // The push-back, all together.
        var retry: [(Thing, Zone, [String])] = []
        for (t, z, _) in refused {
            let ok = Placer.allowed(t, in: r)
            if ok.isEmpty {
                Placer.fallback(&r, t, near: z)
                r.log.append("move: " + t.name + " → nearest allowed spot")
            } else {
                retry.append((t, z, ok))
            }
        }
        if !retry.isEmpty {
            r.log.append("ask: where else for " + retry.map { $0.0.name }.joined(separator: ", ") + "?")
            await show(r, pause: 0.3)
            let why = refused.filter { f in retry.contains { $0.0.id == f.0.id } }.map { "The " + Zone.short($0.0.name) + " can't go " + $0.1.text + ", because " + $0.2 + "." }
            let lines = retry.enumerated().map { "\($0.offset + 1) = the " + Zone.short($0.element.0.name) + ": " + $0.element.2.joined(separator: "; ") }
            let q3 = brief + "\nALREADY IN IT: " + r.objects.map(\.name).joined(separator: ", ") + "\n" + why.joined(separator: "\n")
                + "\nQUESTION: Where else does each go?\nPLACES:\n" + lines.joined(separator: "\n")
                + "\nOutput ONLY one JSON object, a place for each number:\n{" + retry.indices.map { "\"\($0 + 1)\":\"one of its PLACES\"" }.joined(separator: ",") + "}\nThe form:"
            let m3 = await ask("Where else do they go?", q3, JSONGrammar.roomRetry(allowed: retry.map(\.2)), 24 + 16 * retry.count)
            for (i, (t, z, ok)) in retry.enumerated() {
                let said = str(m3, String(i + 1))
                if let z2 = Zone.parse(said), ok.contains(said), Placer.place(&r, t, zone: z2).placed {
                    r.log.append("place: " + t.name + " → " + z2.text)
                } else {
                    Placer.fallback(&r, t, near: z)
                    r.log.append("move: " + t.name + " → nearest allowed spot")
                }
                await show(r)
            }
        }

        // Stairs by the way up or down, unless the story's own things already put a staircase here.
        if !r.objects.contains(where: { $0.icon == "stairs" }) {
            for (wall, to) in stairWays.prefix(1) {
                var st = Thing(kind: .object, name: "stairs" + (to.isEmpty ? "" : " to " + Zone.short(to)), icon: "stairs")
                st.owner = nil
                if Placer.place(&r, st, zone: .wall(wall)).placed { r.log.append("place: " + st.name + " → by the " + wall.rawValue + " wall") }
                else { r.log.append("refuse: " + st.name + " (no room by the " + wall.rawValue + " wall)") }
            }
        }
        // Seats along a bar or counter, or round a table: as many as the batch said (the centrepiece
        // added by the template gets its template's own count); the map fits what it can on the open side.
        for table in r.objects where table.icon == "table" && table.on == nil && (table.owner ?? "").isEmpty {
            let said = stoolsFor[table.id] ?? 0
            guard said > 0 else { continue }
            let around = Set(Placer.cells(.at(Zone.short(table.name)), in: r, forPeople: true))
            let already = r.objects.filter { Rules.seats.contains($0.icon) && around.contains(Cell(x: $0.x, y: $0.y)) }.count
            let want = min(max(0, said - already), 2 * max(table.w, table.d) + 2)
            var got = 0
            for _ in 0..<want {
                if Placer.place(&r, Thing(kind: .object, name: "chair", icon: "chair"), zone: .at(Zone.short(table.name))).placed { got += 1 } else { break }
            }
            r.log.append("chairs at the " + Zone.short(table.name) + ": \(said) said" + (already > 0 ? ", \(already) there already" : "") + (got < want ? " (room for \(got))" : ""))
            if got > 0 { await show(r, pause: 0.2) }
        }
        for bar in r.objects where Rules.staffed.contains(bar.icon) && bar.on == nil {
            let atBar = Set(Placer.cells(.at(Zone.short(bar.name)), in: r, forPeople: true))
            let already = r.objects.filter { Rules.seats.contains($0.icon) && atBar.contains(Cell(x: $0.x, y: $0.y)) }.count
            let said = stoolsFor[bar.id] ?? 4
            let want = min(max(0, said - already), max(bar.w, bar.d) + 1)
            var got = 0
            for _ in 0..<want {
                let stool = Thing(kind: .object, name: "stool", icon: "stool")
                if Placer.place(&r, stool, zone: .at(Zone.short(bar.name))).placed { got += 1 } else { break }
            }
            r.log.append("stools at the " + Zone.short(bar.name) + ": \(said) said" + (already > 0 ? ", \(already) there already" : "") + (got < want ? " (room for \(got))" : ""))
            if got > 0 { await show(r, pause: 0.2) }
        }
        // 4. The people: where each one is, and who or what they face.
        let myFirst = Cards.first(a0.playerName).lowercased()
        let hereListed: [String] = (adventure ?? a0).whereabouts.filter { w in
            let f = Cards.first(w.name).lowercased()
            return w.here != false && !f.isEmpty && f != myFirst && f != "you"
        }.map { w in Cards.card(for: w, in: a0)?.name ?? w.name }
        // And anyone the story itself shows in the room who isn't placed anywhere yet.
        var here = hereListed
        for c in a0.cast where !here.contains(c.name) && Cards.mentions(c, in: story) {
            here.append(c.name)
        }
        // Everyone here is in the room as far as the story is concerned, before they are placed (so nobody "leaves" while it is drawn).
        if var a = adventure {
            for name in here {
                if let i = a.whereabouts.firstIndex(where: { Cards.card(for: $0, in: a)?.name == name || $0.name == name }) {
                    if a.whereabouts[i].here == false { a.whereabouts[i].here = true; a.whereabouts[i].leftAt = nil; a.whereabouts[i].at = placeName }
                } else {
                    a.whereabouts.append(Whereabout(name: name, at: placeName, here: true, engaged: false))
                }
            }
            adventure = a
        }
        let entry = RoomBuilder.entrance(r, from: from)
        var me = Thing(kind: .player, name: a0.playerName.isEmpty ? "You" : a0.playerName)
        me.x = entry.x; me.y = entry.y; me.on = nil
        me.facing = Facing.toward(dx: r.width / 2 - entry.x, dy: r.depth / 2 - entry.y) ?? .n
        Placer.put(&r, me)
        if !here.isEmpty {
            // One person at a time: with the others or off on their own, sitting or standing (and on
            // what), then where from the places that fit, and who or what they face.
            var faces: [String] = ["you", "the door"]
            if !windows.isEmpty { faces.append("the window") }
            faces += here
            faces += Array(r.objects.filter { !Rules.rule($0.icon).small }.map(\.name).prefix(6))
            var facing: [(UUID, String)] = []
            // Whose things are whose: the model is shown what is already someone else's, so the
            // regular doesn't get the bartender's ledger too (she started acting like a second bartender).
            var claimed: [String: String] = [:]
            for name in here {
                guard !Task.isCancelled else { return }
                let card = a0.cast.first { $0.name == name }
                let workSpots = ["nothing"] + r.objects.filter { $0.on == nil && !Rules.rule($0.icon).small && $0.icon != "rug" }.map { Zone.short($0.name) }
                var who = name + ((card?.role ?? "").isEmpty ? "" : " (" + Continuity.roleLabel(card!.role) + ")")
                // Where the story itself puts them ("at a corner table with her sketchbook") goes with
                // every question about them.
                if let told = (adventure ?? a0).whereabouts.first(where: { $0.name == name })?.at, told.count > 3 {
                    who += ", whom the story puts " + clip(told, 80)
                }
                // And their card ("She sits in a corner, humming"), so posture and things fit it.
                if let d = card?.desc, d.count > 8 { who += " (their card: " + clip(d, 110) + ")" }
                let q = base + "THE ROOM NOW: " + r.objects.map(\.name).joined(separator: ", ") + (r.people.count > 1 ? "; already placed: " + r.people.filter { $0.kind == .person }.map(\.name).joined(separator: ", ") : "") + ".\n"
                    + "QUESTION: About " + who + " as the story opens: are they with the others, or apart on their own (a separate conversation the player can go to)? Are they sitting or standing, and on what (a stool, a chair, a booth, a bench; none if standing)? Do they work behind something here (WORK SPOTS), or nothing? Someone working behind a bar or counter usually stands.\nWORK SPOTS: " + workSpots.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"company\":\"with the others or apart\",\"posture\":\"sitting or standing\",\"seat\":\"what they sit on, or none\",\"works_behind\":\"one of WORK SPOTS\"}\nThe form:"
                let m = await ask("Is " + Cards.first(name) + " with the others, or apart?", q, JSONGrammar.personSetup(work: workSpots), 60)
                var worksBehind = str(m, "works_behind")
                let apart = str(m, "company").lowercased().hasPrefix("apart")
                // A work spot is checked on its own: is this person really staff here, working behind it?
                if !worksBehind.isEmpty, worksBehind != "nothing" {
                    let wq = "As the story opens, is " + who + " standing behind the " + worksBehind + ", working at it, rather than a guest, or somewhere else the story puts them (by a window, at a table)?"
                    let yn = await ask(clip(wq, 70), base + "QUESTION: " + wq + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                    let staff = str(yn, "answer").lowercased().hasPrefix("y")
                    r.log.append("ask: does " + name + " work behind the " + worksBehind + "? → " + (staff ? "yes" : "no"))
                    if !staff { worksBehind = "nothing" }
                }
                var sitting = str(m, "posture").lowercased().hasPrefix("sit")
                // Standing, and not staff: asked again plainly, since a guest who has settled in for
                // the evening is usually sitting, with a seat under them.
                if !sitting, worksBehind == "nothing" {
                    let sq = "Has " + who + " settled in here for a while, so that they would be sitting down rather than standing?"
                    let sm = await ask(clip(sq, 70), base + "QUESTION: " + sq + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                    sitting = str(sm, "answer").lowercased().hasPrefix("y")
                    r.log.append("ask: has " + name + " settled in, sitting? → " + (sitting ? "yes" : "no"))
                }
                var seatName = str(m, "seat")
                if ["none", "nothing", ""].contains(seatName.lowercased()) || Self.echoesPrompt(seatName) { seatName = sitting ? "chair" : "" }
                // A seat has to be something to sit on ("a separate conversation…" is not): a chair then.
                let seatKind = Rules.icon(for: seatName)
                if sitting, !Rules.seats.contains(seatKind), !Rules.surfaces.contains(seatKind) { seatName = "chair" }
                // "Sitting on a table" means at one: a chair goes under them and the table beside them.
                var seatTable = ""
                if sitting, Rules.surfaces.contains(Rules.icon(for: seatName)) { seatTable = seatName; seatName = "chair" }
                r.log.append("ask: " + name + " → " + (apart ? "apart" : "with the others") + ", " + (sitting ? "sitting on " + seatName : "standing"))
                await show(r, pause: 0.2)
                // The places that fit: far from everyone already placed when they keep to themselves.
                var menu = Zone.menu(r, people: true)
                if apart {
                    let others = r.people
                    let far = menu.filter { z in
                        guard let zone = Zone.parse(z) else { return false }
                        let c = Placer.centroid(Placer.cells(zone, in: r, forPeople: true))
                        return others.allSatisfy { o in hypot(c.0 - o.centre.x, c.1 - o.centre.y) >= 3 }
                    }
                    if !far.isEmpty { menu = far }
                }
                var z: Zone
                var faceSaid = "you"
                if worksBehind != "nothing", let post = r.named(worksBehind) {
                    z = .behind(post.name)
                    r.log.append("ask: " + name + " works behind the " + Zone.short(post.name))
                } else {
                    let wq = base + "THE ROOM NOW: " + r.objects.map(\.name).joined(separator: ", ") + ".\nQUESTION: Where is " + who + (apart ? ", off on their own" : "") + ", and who or what do they face?\nPLACES: " + menu.joined(separator: "; ") + "\nFACES: " + faces.filter { $0 != name }.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"where\":\"one of PLACES\",\"facing\":\"one of FACES\"}\nThe form:"
                    let wm = await ask("Where is " + Cards.first(name) + "?", wq, JSONGrammar.personPlace(zones: menu, faces: faces.filter { $0 != name }), 50)
                    z = Zone.parse(str(wm, "where")) ?? (apart ? .farCorner : .centre)
                    if !str(wm, "facing").isEmpty { faceSaid = str(wm, "facing") }
                }
                var p = Thing(kind: .person, name: name)
                let note = Placer.placePerson(&r, p, zone: z)
                p = r.thing(p.id) ?? p
                r.log.append("enter: " + name + " " + z.text + (note.isEmpty ? "" : " (" + note + ")"))
                // Sitting with nothing under them: the seat they named goes there with them.
                if sitting, p.on == nil {
                    var seat = Thing(kind: .object, name: seatName, icon: Rules.icon(for: seatName))
                    seat.owner = name
                    if !Rules.seats.contains(seat.icon) { seat.icon = "chair" }
                    seat.x = p.x; seat.y = p.y
                    r.things.append(seat)
                    if let i = r.index(p.id) { r.things[i].on = seat.id }
                    r.log.append("place: " + seatName + " → under " + name)
                }
                if !seatTable.isEmpty {
                    var tb = Thing(kind: .object, name: Cards.first(name) + "'s " + Zone.short(seatTable), icon: Rules.icon(for: seatTable))
                    tb.owner = name
                    let out = Placer.place(&r, tb, zone: .beside(name))
                    if !out.placed { Placer.fallback(&r, tb, near: .beside(name)) }
                    r.log.append(out.placed ? "place: " + tb.name + " → beside " + name : "move: " + tb.name + " → nearest spot to " + name + " (" + out.reason + " beside)")
                }
                // Then, as a person would: what do they have with them, and what would they need
                // close by for it? The things may be ones the story never names; they only need to
                // be near the person who has them.
                // 1. What they have.
                let others = claimed.filter { $0.value != name }.map { $0.key + " (" + Cards.first($0.value) + "'s)" }
                let hq = base + "QUESTION: What is " + who + " doing as the story opens, " + (sitting ? "sitting" : "standing") + ", and what do they have with them for it, in hand or close by? Only their own things, true to who they are and their work, never the tools of someone else's job" + (others.isEmpty ? "" : " (already someone else's: " + others.joined(separator: ", ") + ")") + ". Up to 3 short names of real objects; they may be things the story doesn't name. For each, its sort: small = picked up with one hand (a ledger, tongs, a coin, a sewing kit, a glass); worn = on their body (glasses, a ring, a coat); furniture = big and heavy, on the floor; not solid = a smell, sound, light or feeling.\nOutput ONLY one JSON object:\n{\"things\":[{\"name\":\"a short name\",\"sort\":\"small, worn, furniture or not solid\"}]}\nThe form:"
                // One question: the things and what sort each is, together.
                let hm = await ask("What does " + Cards.first(name) + " have?", hq, JSONGrammar.sortedThings(sorts: ["small", "worn", "furniture", "not solid"], max: 3), 110)
                var has: [String] = []
                for d in ((hm["things"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }).prefix(3) {
                    let item = str(d, "name")
                    guard item.count >= 3, !Self.echoesPrompt(item) else { continue }
                    let sort = str(d, "sort").lowercased()
                    let kind: String?
                    switch sort {
                    case "worn": kind = "worn"
                    case "small", "": kind = "thing"
                    default: kind = nil; r.log.append("refuse: " + item + " (" + sort + ", not something they carry)")
                    }
                    if kind != nil { Self.whatIsKnown[item.lowercased()] = kind == "worn" ? "worn or carried by someone" : "small, set on a surface" }
                    if kind != nil { claimed[item.lowercased()] = name }
                    if kind == "worn", let i = r.index(p.id) {
                        let on = r.things[i].wearing
                        if !on.lowercased().contains(item.lowercased()) { r.things[i].wearing = on.isEmpty ? item : on + ", " + item }
                        r.log.append("edit: " + item + " → worn by " + name)
                    } else if kind != nil { has.append(item) }
                }
                r.log.append("ask: what does " + name + " have? → " + (has.isEmpty ? "nothing" : has.joined(separator: ", ")))
                // 2. What they would need close by for it.
                func surfaceNear() -> Thing? {
                    guard let me = r.thing(p.id) else { return nil }
                    // Their own table first; someone else's only when nothing else is in reach
                    // (Hannah's knitting went onto Elias's table beside her own).
                    let near = r.objects.filter { Rules.surfaces.contains($0.icon) && $0.on == nil }
                        .filter { RoomGrid.distance($0, me) < 2.2 }
                    let mine = near.filter { $0.owner == name }, free = near.filter { ($0.owner ?? "").isEmpty }
                    let pool = !mine.isEmpty ? mine : (!free.isEmpty ? free : near)
                    return pool.min { RoomGrid.distance($0, me) < RoomGrid.distance($1, me) }
                }
                let needOptions = ["nothing", "a table", "a desk", "a shelf", "a crate", "a chair", "a stool", "a sofa", "a lamp"]
                let within = surfaceNear().map { "Already within reach: the " + Zone.short($0.name) + ". " } ?? ""
                let nq = base + "THE ROOM NOW: " + r.objects.map(\.name).joined(separator: ", ") + ".\n"
                    + "QUESTION: " + who + " is " + (sitting ? "sitting" : "standing") + (has.isEmpty ? "" : " and has " + has.joined(separator: ", ")) + ". " + within + "What would they need right beside them for it (somewhere to set things down or work, a chair for company), from NEEDS? Someone settled in a place for a while usually has one or two things by them.\nNEEDS: " + needOptions.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"doing\":\"a few words\",\"first\":\"one of NEEDS\",\"second\":\"one of NEEDS\"}\nThe form:"
                // Someone working behind the bar has the bar: no chair or stool for them back there.
                let nm: [String: Any] = worksBehind != "nothing" ? [:] : await ask("What would " + Cards.first(name) + " need?", nq, JSONGrammar.personNeeds(options: needOptions), 50)
                var needs: [String] = []
                for k in ["first", "second"] {
                    // "stool" for "a stool": the answer counts without its article.
                    let said = str(nm, k).lowercased()
                    guard let v = needOptions.first(where: { $0 == said || $0.hasSuffix(" " + said) }) else { continue }
                    if v != "nothing", !needs.contains(v) { needs.append(v) }
                }
                r.log.append("ask: what would " + name + " need? → " + (needs.isEmpty ? "nothing" : needs.joined(separator: ", ")))
                for need in needs {
                    let kind = String(need.dropFirst(2))
                    var t = Thing(kind: .object, name: Cards.first(name) + "'s " + kind, icon: Rules.icon(for: kind))
                    t.owner = name
                    if t.icon == "other" { t.icon = kind }
                    let out = Placer.place(&r, t, zone: .beside(name))
                    r.log.append(out.placed ? "place: " + t.name + " → beside " + name : "refuse: " + t.name + " beside " + name + " (" + out.reason + ")")
                    // A seat beside someone not yet sitting: the model says whether they sit on it.
                    if out.placed, Rules.seats.contains(t.icon), let seat = r.named(t.name), let me = r.thing(p.id), me.on == nil {
                        let sq = "There is now a " + kind + " beside " + who + ". As the story opens, does " + who + " sit on it?"
                        let sm = await ask("Does " + Cards.first(name) + " sit on the " + kind + "?", base + "QUESTION: " + sq + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                        let sits = str(sm, "answer").lowercased().hasPrefix("y")
                        r.log.append("ask: does " + name + " sit on the " + kind + "? → " + (sits ? "yes" : "no"))
                        if sits, let i = r.index(p.id) {
                            r.things[i].x = seat.x; r.things[i].y = seat.y; r.things[i].on = seat.id
                        }
                    }
                }
                // 3. What they have goes close to them: on the surface in reach, or in their hands.
                // With nothing to set things on, the model says whether they'd hold it all or put
                // it down; down means a table beside them.
                if surfaceNear() == nil, !has.isEmpty {
                    let dq = who + " has " + has.joined(separator: ", ") + ". Would they set some of these down on a table beside them, rather than hold them all in their hands?"
                    let dm = await ask("Would " + Cards.first(name) + " set things down?", base + "QUESTION: " + dq + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                    let down = str(dm, "answer").lowercased().hasPrefix("y")
                    r.log.append("ask: would " + name + " set things down? → " + (down ? "yes" : "no"))
                    if down {
                        var tb = Thing(kind: .object, name: Cards.first(name) + "'s table", icon: "table")
                        tb.owner = name
                        let out = Placer.place(&r, tb, zone: .beside(name))
                        if !out.placed { Placer.fallback(&r, tb, near: .beside(name)) }
                        r.log.append("place: " + tb.name + " → beside " + name)
                    }
                }
                let rest = surfaceNear()
                for item in has {
                    var mine = Thing(kind: .object, name: item, icon: "small")
                    mine.owner = name
                    if let s = rest, Placer.place(&r, mine, zone: .on(Zone.short(s.name))).placed {
                        r.log.append("place: " + item + " → on the " + Zone.short(s.name))
                    } else if Self.holdable(item), let i = r.index(p.id), r.things[i].holding.count < 2 {
                        r.things[i].holding.append(item)
                        r.log.append("edit: " + item + " → in " + name + "'s hands")
                    }
                }
                if !has.isEmpty || !needs.isEmpty { await show(r, pause: 0.2) }
                facing.append((p.id, faceSaid))
                // Someone apart is not the one the player is dealing with yet.
                if apart, var a = adventure, let k = a.whereabouts.firstIndex(where: { $0.name == name }) {
                    a.whereabouts[k].engaged = false
                    adventure = a
                }
                await show(r)
            }
            for (id, f) in facing where !f.isEmpty { Placer.turn(&r, id, toward: f) }
        }
        // What people wear or carry goes with them, not on the floor.
        for (owner, item) in worn {
            let who: Thing? = owner == "you" ? r.player : r.named(owner)
            guard let t = who, let i = r.index(t.id) else { continue }
            if r.things[i].wearing.isEmpty { r.things[i].wearing = item } else if !r.things[i].wearing.contains(item) { r.things[i].wearing += ", " + item }
        }
        // Small things the story names go on the surface it puts them on, or in someone's hands:
        // one batch, a choice for each.
        let tops = Array(Set(r.objects.filter { Rules.surfaces.contains($0.icon) && $0.on == nil }.map { Zone.short($0.name) })).sorted()
        let hands = r.people.filter { $0.kind == .person }.map { Cards.first($0.name) + "'s hands" }
        let smallOpts = tops + hands
        let smallList = Array(smalls.prefix(6))
        if !smallList.isEmpty, smallOpts.isEmpty { r.log.append("refuse: " + smallList.joined(separator: ", ") + " (nothing to set it on)") }
        if !smallList.isEmpty, !smallOpts.isEmpty, !Task.isCancelled {
            let lines = smallList.enumerated().map { "\($0.offset + 1) = the " + Zone.short($0.element) }
            let oq = "THE ROOM NOW: " + r.objects.map(\.name).joined(separator: ", ") + ".\nQUESTION: Where is each of these as the story opens?\n" + lines.joined(separator: "\n")
                + "\nCHOICES: " + smallOpts.joined(separator: "; ")
                + "\nOutput ONLY one JSON object, one of CHOICES for each number:\n{" + smallList.indices.map { "\"\($0 + 1)\":\"one of CHOICES\"" }.joined(separator: ",") + "}\nThe form:"
            let om = await ask("Where are the small things?", base + oq, JSONGrammar.roomRetry(allowed: smallList.map { _ in smallOpts }), 24 + 14 * smallList.count)
            for (n, item) in smallList.enumerated() {
                let said = str(om, String(n + 1))
                // The model put it in their hands: it goes there (up to three things), not onto the
                // first surface in the room.
                if said.hasSuffix("'s hands"), Self.holdable(item), let p = r.people.first(where: { Cards.first($0.name) + "'s hands" == said }), let i = r.index(p.id), r.things[i].holding.count < 3 {
                    r.things[i].holding.append(item)
                    r.log.append("edit: " + item + " → in " + p.name + "'s hands")
                } else if let top = tops.first(where: { $0 == said }) ?? tops.first,
                          Placer.place(&r, Thing(kind: .object, name: item, icon: "small"), zone: .on(top)).placed {
                    r.log.append("place: " + item + " → on the " + top)
                } else {
                    r.log.append("refuse: " + item + " (no room on any surface)")
                }
            }
        }
        // You start where the opening puts you ("on a stool at the long mahogany bar").
        if let a = adventure, let me = r.player {
            let opening = [a.spot, a.scene].first { !$0.isEmpty } ?? ""
            // Where: read off the opening's own words when they name a thing on the map, or else the
            // model picks from the places.
            var z = Adventure.zone(from: opening, in: r)
            if z == nil, !opening.isEmpty {
                let menu = Zone.menu(r, people: true)
                let om = await ask("Where are you as it opens?", base + "THE ROOM NOW: " + r.objects.map(\.name).joined(separator: ", ") + ".\nTHE OPENING SAYS: " + clip(opening, 200) + "\nQUESTION: Where is the player as the story opens?\nPLACES: " + menu.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"where\":\"one of PLACES\"}\nThe form:", JSONGrammar.one("where", from: menu), 30)
                z = Zone.parse(str(om, "where"))
            }
            if let z {
                let note = Placer.placePerson(&r, me, zone: z)
                r.log.append("move: you → " + z.text + (note.isEmpty ? "" : " (" + note + ")"))
            }
            // Sitting, when the opening has you sit: on the free seat nearest where you are, or a
            // stool brought over. The model says whether you sit.
            if !opening.isEmpty, let meNow = r.player, meNow.on == nil {
                let sq = "THE OPENING SAYS: " + clip(opening, 200) + "\nQUESTION: As the story opens, by the premise and the opening, is the player sitting down?"
                let sm = await ask("Are you sitting as it opens?", base + sq + "\nOutput ONLY one JSON object:\n{\"answer\":\"yes or no\"}\nThe form:", JSONGrammar.one("answer", from: ["yes", "no"]), 24)
                if str(sm, "answer").lowercased().hasPrefix("y") {
                    let taken = Set(r.people.compactMap(\.on))
                    // Never a seat that belongs to someone else (Dolores's chair). The model says which
                    // free seat the premise puts you on ("a window seat"); otherwise the nearest.
                    let free = r.objects.filter({ Rules.seats.contains($0.icon) && !taken.contains($0.id) && ($0.owner ?? "").isEmpty })
                    var picked: Thing? = nil
                    if free.count > 1 {
                        // Each seat with where it is: its nearest wall, and whether a window is there.
                        func whereIs(_ t: Thing) -> String {
                            let gaps: [(Wall, Int, Int)] = [(.west, t.x, t.y), (.east, r.width - 1 - t.x, t.y), (.north, t.y, t.x), (.south, r.depth - 1 - t.y, t.x)]
                            guard let near = gaps.min(by: { $0.1 < $1.1 }) else { return "" }
                            if near.1 > 1 { return "in the middle" }
                            let window = r.windows.contains { $0.wall == near.0 && abs($0.at - near.2) <= 2 }
                            return window ? "by the window" : "by the " + near.0.rawValue + " wall"
                        }
                        let labels = free.enumerated().map { "\($0.offset + 1). " + Fovea.bare($0.element.name) + ", " + whereIs($0.element) }
                        let opts = labels + ["none of these"]
                        let pq = "THE OPENING SAYS: " + clip(opening, 200) + "\nTHE FREE SEATS: " + labels.joined(separator: "; ") + "\nQUESTION: Which of THE FREE SEATS is the player sitting on as the story opens, by the premise and the opening (a window seat, a stool at the bar)?\nOutput ONLY one JSON object:\n{\"seat\":\"one of THE FREE SEATS, or none of these\"}\nThe form:"
                        let pm = await ask("Which seat are you on?", base + pq, JSONGrammar.one("seat", from: opts), 30)
                        if let k = labels.firstIndex(of: str(pm, "seat")) { picked = free[k] }
                    }
                    if let seat = picked ?? free.filter({ RoomGrid.distance($0, meNow) < 2.5 })
                        .min(by: { RoomGrid.distance($0, meNow) < RoomGrid.distance($1, meNow) }), let i = r.index(meNow.id) {
                        r.things[i].x = seat.x; r.things[i].y = seat.y; r.things[i].on = seat.id
                        r.log.append("move: you → on " + Fovea.bare(seat.name))
                    } else {
                        let stool = Thing(kind: .object, name: "stool", icon: "stool")
                        if Placer.place(&r, stool, zone: .beside(meNow.name)).placed, let placed = r.objects.last(where: { $0.icon == "stool" }), let i = r.index(meNow.id) {
                            r.things[i].x = placed.x; r.things[i].y = placed.y; r.things[i].on = placed.id
                            r.log.append("move: you → on a stool")
                        }
                    }
                }
            }
            if let me2 = r.player {
                let staff = r.people.first { p in p.kind == .person && (p.pastMoves.first ?? "").hasPrefix("behind") }
                if let first = staff ?? r.people.first(where: { $0.kind == .person && $0.id != me2.id }) { Placer.turn(&r, me2.id, toward: first.name) }
            }
        }
        r.log = Array(r.log.suffix(80))
        await show(r, pause: 0)
        if let a = adventure { library.save(a) }
    }
}


// MARK: - For the overnight tests

extension StoryEngine {
    /// Waits for the rebuild after the last reply to finish, so the tests read the world only once
    /// it has caught up (a person playing slowly would see the same).
    func settle() async {
        if let job = memoryJob { await job.value }
    }
    /// Every model question asked in this story so far ("[turn 3 · rebuild] Is anyone new here? → {...}").
    var questionsAsked: [String] { questionLogFor == adventure?.id ? questionLog : [] }
    /// How many entries the trace (the Live log) holds, and the entries from a point on.
    var traceCount: Int { traceFor == adventure?.id ? traceLog.count : 0 }
    func traceEntries(from i: Int) -> [String] { traceFor == adventure?.id ? Array(traceLog.dropFirst(max(0, i))) : [] }
}
