import Foundation
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
    private(set) var adventure: Adventure?
    private(set) var streaming = ""
    private(set) var stage = ""
    /// The question the rebuild after a reply is asking right now ("" when it is not running),
    /// so the World panel can show it live.
    private(set) var rebuildStep = ""
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
    /// The reasoning behind the last plan, kept with the reply for the story export.
    private var planThoughts = ""
    var error: String?

    /// Names learned this turn, for the world check.
    private var namesThisTurn: [String] = []

    /// Read replies aloud as they are written.
    var narrate: Bool { didSet { UserDefaults.standard.set(narrate, forKey: "narrate") } }
    /// The Game Master writes a short private plan before each reply (a few seconds more per turn).
    var gmPlans: Bool { didSet { UserDefaults.standard.set(gmPlans, forKey: "gmPlans") } }
    /// The plan and the look-ahead use the model's reasoning mode (Qwen's thinking): much slower,
    /// up to about a minute per turn, but the Game Master really works the problem first.
    var deepThinking: Bool { didSet { UserDefaults.standard.set(deepThinking, forKey: "deepThinking") } }
    /// The grounded engine: the world lives in the app as cards, a short read of the player's
    /// message decides which cards this moment needs, and the storyteller sees only those (see
    /// `runGroundedTurn`). Off, the classic Game Master plans and reviews with the whole world each turn.
    var grounded: Bool { didSet { UserDefaults.standard.set(grounded, forKey: "groundedEngine") } }
    /// How far the current reasoning step is toward its room to think (0 to 1), or nil when
    /// nothing is reasoning. About 4 characters a token.
    var thinkingProgress: Double? {
        guard thinkBudget > 0, llm.thoughtChars > 0 else { return nil }
        return min(1, Double(llm.thoughtChars) / 4 / Double(thinkBudget))
    }
    /// The token room of the reasoning call under way (0 when none is).
    private var thinkBudget = 0
    /// Hands-free: the microphone opens after every reply, and the send phrase sends.
    private(set) var handsFree = false

    private let llm: LLMService
    private let narrator: Narrator
    private let dictation: Dictation
    private let library: Library
    private var memoryJob: Task<Void, Never>?
    /// The showrunner's notes or the bible refresh, chained after the memory pass.
    private var housekeepingJob: Task<Void, Never>?
    /// True while housekeeping is actually talking to the model (a turn then waits for it).
    private var housekeepingRunning = false
    private var undoSnapshot: Adventure?
    /// A turn the app had to stop because it left the foreground mid-reply; it runs again on return.
    /// Where the player was when the turn began, so the review knows which place people were left in.
    private var placeBeforeTurn = ""
    /// How the grounded engine read the player's last message, for the export.
    private var lastRead = ""
    /// What the catch-up on a place found this turn, for the turn guide.
    private var catchUpNotes: [String] = []
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
        gmPlans = UserDefaults.standard.object(forKey: "gmPlans") as? Bool ?? true
        deepThinking = UserDefaults.standard.object(forKey: "deepThinking") as? Bool ?? true
        grounded = UserDefaults.standard.object(forKey: "groundedEngine") as? Bool ?? true
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
        forge?.abort()
        housekeepingJob?.cancel()
        ComputerSounds.shared.stopHum()
    }

    /// Turns hands-free on or off. On, the story is read aloud and the microphone opens
    /// whenever the narrator is quiet.
    func setHandsFree(_ on: Bool) {
        handsFree = on
        if on {
            narrate = true
            listenIfReady()
        } else {
            dictation.stop()
        }
    }

    private func listenIfReady() {
        guard handsFree, let a = adventure, !a.ended, !busy, !dictation.listening, !narrator.speaking, !narrator.preparing else { return }
        Task { await dictation.start() }
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
        let forge = Forge(name: e.title.isEmpty ? (source.map { $0.report?.title ?? $0.title } ?? "Your world") : e.title, curated: CuratedExperiences.all.contains { $0.id == e.id })
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
            var request = (e.simulator ? Prompts.architect + "\n" + Prompts.architectSimulator : Prompts.architect)
            if source != nil { request += "\n" + Prompts.continuation }
            request += "\n" + Prompts.architectNameless(playerNamed: !player.name.isEmpty)
            var prompt = "PLAYER'S ANSWERS\n" + e.answers(player: player)
                + "\n\nFEELING TO ACHIEVE: " + (e.feeling.isEmpty ? "surprise me" : e.feeling)
                + "\nPLAY MODE: " + (e.simulator ? "experience (no plot)" : "story")
                + "\nSESSION LENGTH: \(a.minutes) minutes (about \(max(3, a.minutes * 60 / 90)) player replies)."
                + (a.isShort ? "\nThis is a SHORT story: a small cast, 2-3 places, 3 acts, one clear goal." : "")
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
            plan = JSONExtract.object(raw)
            if plan == nil, let retry = try? await llm.complete(system: nil, prompt: request + "\n\n" + prompt,
                                                                options: .init(maxTokens: 1500, temperature: 0.5)) {
                plan = JSONExtract.object(retry)
            }
            guard !Task.isCancelled else { return }
            apply(plan ?? [:], to: &a, setup: e, player: player)
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
            forge.reach(Forge.stages.count - 1)
            adventure = a
            undoSnapshot = nil
            refreshVocabulary()
            library.save(a)

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
            if kind == .person { people += 1; if people > cap + 1 { continue } }
            let pronouns = str("pronouns", item)
            if kind == .person, !pronouns.isEmpty { a.facts.append("\(name) uses \(pronouns).") }
            addLore(&a, LoreEntry(name: name, kind: kind, desc: str("desc", item), role: str("role", item),
                                  known: kind != .person || (!a.nameless && (item["known"] as? Bool ?? false)), wants: str("wants", item)))
        }

        a.beats = ((plan["beats"] as? [Any]) ?? []).compactMap { b in
            (b as? String) ?? ((b as? [String: Any])?["beat"] as? String)
        }.map { Beat(text: $0) }
        a.roadmap = ((plan["roadmap"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let g = r["goal"] as? String else { return nil }
            return Act(from: (r["from"] as? NSNumber)?.doubleValue ?? 0, to: (r["to"] as? NSNumber)?.doubleValue ?? Double(a.minutes), goal: g)
        }
        if a.roadmap.isEmpty && !e.simulator {
            let m = Double(a.minutes)
            a.roadmap = [
                Act(from: 0, to: m * 0.35, goal: "Set up the world, the goal and the first obstacle."),
                Act(from: m * 0.35, to: m * 0.8, goal: "A turn: raise the stakes and test the player, toward a climax."),
                Act(from: m * 0.8, to: m, goal: "Land a satisfying storybook ending that delivers the feeling."),
            ]
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
    /// app holds it now, then every turn with what happened behind the scenes (with the grounded
    /// engine: how the message was read, what was fetched and why, the prompt's size, and what was
    /// filed afterwards).
    func storyText() -> String {
        guard let a = adventure else { return "" }
        var out = ["# " + a.title, ""]
        if !a.setup.feeling.isEmpty { out.append("Feeling: " + a.setup.feeling) }
        if !a.setup.goal.isEmpty { out.append("Goal: " + a.setup.goal) }
        let engineLine: String = grounded
            ? "Grounded engine (read, fetch, paint, file)" + (gmPlans ? "" : ", reading off")
            : "Game Master planning " + (gmPlans ? "on" : "off") + ", reasoning " + (reasons ? "on" : "off")
        out.append(engineLine + " · " + Self.build)
        if grounded {
            out += ["", "## Premise (the storyteller's only standing view of the story)", Cards.premise(a)]
        } else {
            out += ["", "## Story bible", a.bible]
        }
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
        }
        let placeCards = a.lore.filter { $0.kind == .place }.map(\.name)
        if !placeCards.isEmpty { out.append("- Place cards: " + placeCards.joined(separator: ", ")) }
        let items = a.lore.filter { $0.kind == .item || $0.kind == .faction || $0.kind == .other }.map(\.name)
        if !items.isEmpty { out.append("- Other cards: " + items.joined(separator: ", ")) }
        out.append("- Now: " + (a.location.isEmpty ? "on the move" : a.location) + (a.storyTime.isEmpty ? "" : " · " + a.storyTime))
        if !a.carrying.isEmpty { out.append("- You have: " + a.carrying.joined(separator: "; ")) }
        let here = Cards.props(a)
        if !here.isEmpty { out.append("- Props here: " + here.joined(separator: "; ")) }
        if !a.facts.isEmpty { out += ["", "## Facts on file (\(a.facts.count); each reply gets only the ones it needs)"] + a.facts.map { "- " + $0 } }
        out += ["", "## The story", ""]
        let me = a.playerName.isEmpty ? "YOU" : a.playerName.uppercased()
        for t in a.transcript {
            if let b = t.before, !b.isEmpty { out += [b, ""] }
            out.append((t.role == .player ? me : "GAME MASTER") + ":\n" + t.text)
            out.append("")
            if let b = t.after, !b.isEmpty { out += [b, ""] }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Playing

    func send(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !busy, let a = adventure, !a.ended else { return }
        dictation.stop()
        dictation.clear()
        busy = true
        pendingInput = input   // shown at once, while the Game Master finishes its review
        currentTask = Task {
            defer { busy = false; pendingInput = nil }
            await runTurn(input: input, hidden: false)
        }
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

    private func runTurn(input: String, hidden: Bool, forceFinal: Bool = false) async {
        if grounded { await runGroundedTurn(input: input, hidden: hidden, forceFinal: forceFinal); return }
        guard var a = adventure else { return }
        let turnBegan = Date()
        ComputerSounds.shared.startHum()
        // Housekeeping already talking to the model holds the GPU, so wait for it (it is one call,
        // once every few turns). If it hasn't started yet, it waits for a later turn instead.
        if housekeepingRunning, let job = housekeepingJob {
            stage = "Updating the story notes"
            await job.value
            guard !Task.isCancelled else { return }
            a = adventure ?? a
        } else {
            housekeepingJob?.cancel()
        }
        // Let the memory pass and the look-ahead finish first. With planning on they are part of the
        // Game Master's thinking, so the turn waits for them (up to three minutes); otherwise briefly.
        if let job = memoryJob {
            stage = gmPlans ? "The Game Master is finishing its review" : "Remembering"
            let waiter = Task { await job.value }
            let limit: Double = gmPlans ? 180 : 4
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { await waiter.value }
                group.addTask { try? await Task.sleep(for: .seconds(limit)) }
                await group.next()
                group.cancelAll()
            }
            guard !Task.isCancelled else { return }
            a = adventure ?? a
        }
        let snapshot = a
        placeBeforeTurn = a.location
        lastRead = ""
        // The clock pauses while the Game Master thinks: the wait for its review just now, and the
        // planning before the last reply began.
        let played = clockTick(&a, hidden: hidden, paused: Date().timeIntervalSince(turnBegan) + a.gmWait)
        let ticked = Date()
        if forceFinal { a.left = 0 }
        // The story clock moves with play (a cozy scene runs at about real time), never backwards.
        if !hidden, let c = a.clock {
            a.clock = c + max(1, Int((played / 60).rounded()))
            a.storyTime = Continuity.storyTime(clock: a.clock!, old: a.storyTime)
        }
        // The player says what time it is ("it's about half past 10"): that is the time now.
        if !hidden, let said = Continuity.statedTime(input, near: a.clock) {
            a.clock = said
            a.storyTime = Continuity.storyTime(clock: said, old: a.storyTime)
        }
        let opening = hidden && a.transcript.isEmpty
        // The opening scene paints the place, so it gets more room than an ordinary reply.
        let maxOut = opening ? 520 : a.isShort ? 300 : 420
        let playerNarrates = !hidden && Self.narrates(input)
        let playerAsks = !hidden && !playerNarrates && Self.asks(input)
        namesThisTurn = []
        let introduced = hidden ? false : learnPlayerName(&a, input: input)
        var notes = directorNotes(a, playerNarrates: playerNarrates, playerAsks: playerAsks, opening: opening)
        if !hidden, !playerNarrates, Continuity.moves(input) {
            notes.insert("THE PLAYER IS MOVING: show them going where they said, the way there, and what they find when they arrive. People are where the scene puts them: someone elsewhere is found there, never suddenly beside the player.", at: playerAsks ? 1 : 0)
        }
        let planning = gmPlans && !hidden
        // How hard the rules, bible and briefing are squeezed to make room (0 = not at all).
        var tight = 0
        func briefing(_ memories: [String], plan: String = "") -> String {
            let continuity = continuityText(a, tight: tight)
            return "[GAME MASTER BRIEFING: private, for this reply only]\n"
                + (plan.isEmpty ? "" : "YOUR PLAN FOR THIS REPLY (you wrote it after reviewing the story; carry it out)\n" + plan + "\n\n")
                + briefingText(a, memories: memories, director: notes, tight: tight)
                + (continuity.isEmpty ? "" : "\n\n" + continuity)
                + "\n[END OF BRIEFING]\n\n" + (hidden ? "INSTRUCTION: " : "THE PLAYER: ") + input
        }

        // Fit everything into the context the fit check planned for, by a hard rule: the reply's
        // room, the plan's room and a safety margin come off the top; the rest must hold the rules
        // and bible, the briefing, the two newest turns and at least a few recalled memories. If it
        // doesn't, the rules side is squeezed step by step (older notes, then the bible), then the
        // two newest turns are shortened. Only then do older turns and more memories get the rest.
        stage = "Recalling memories"
        let budget = LLMService.contextBudget - maxOut - Self.safetyTokens - (planning ? Self.planRoom : 0)
        let recent = Array(a.transcript.enumerated()).dropFirst(a.summarisedTurns).suffix(10)
        let newest = Array(recent.suffix(2))
        let minRecall = hidden ? 0 : Self.minRecallTokens
        let newestCost = newest.reduce(0) { $0 + min(Self.tokens($1.element.text), 300) + 8 }
        var system = systemPrompt(a, tight: tight)
        // The story's own recent words keep its voice and its thread better than any list of facts,
        // so the extras (map, recent events, long notes) give way before the last four turns do.
        let wanted = min(900, recent.suffix(4).reduce(0) { $0 + Self.tokens($1.element.text) + 8 })
        if Self.tokens(system) + Self.tokens(briefing([])) + wanted + minRecall > budget {
            tight = 1
            system = systemPrompt(a, tight: tight)
        }
        while tight < Self.tightest, Self.tokens(system) + Self.tokens(briefing([])) + newestCost + minRecall > budget {
            tight += 1
            system = systemPrompt(a, tight: tight)
        }
        let fixed = Self.tokens(system) + Self.tokens(briefing([]))
        // The story's own recent turns come first; recalled memories get what is left (never less
        // than the minimum), because most of what they would say is already in those turns.
        let recallReserve = minRecall + 40
        var kept: [(Int, StoryTurn)] = []
        var used = fixed
        for (i, t) in recent.reversed() {
            let cost = Self.tokens(t.text) + 8
            if kept.count >= 2 && used + cost + recallReserve > budget { break }
            kept.insert((i, t), at: 0)
            used += cost
        }
        // Never over budget, and always some room to recall: the kept turns are shortened from the
        // oldest (keeping each one's end, where the story stands), the newest last of all.
        for k in kept.indices where used + minRecall > budget {
            let t = kept[k].1
            let over = used + minRecall - budget
            let keepChars = max(240, t.text.count - over * 7 / 2 - 40)
            guard keepChars < t.text.count else { continue }
            var c = t
            c.text = "…" + String(t.text.suffix(keepChars))
            used -= Self.tokens(t.text) - Self.tokens(c.text)
            kept[k] = (kept[k].0, c)
        }
        let keptIDs = Set(kept.map { $0.1.id })
        let older = a.transcript.enumerated().filter { !keptIDs.contains($0.element.id) }.map { ($0.offset + 1, $0.element) }
        let room = min(Self.recallChars, max(0, (budget - used) * 7 / 2))
        let recalled = hidden ? [] : await Recall.memories(for: a, input: input, olderTurns: older, chaptersInPrompt: min(6, a.chapters.count), budget: room,
                                                           earlier: earlierStories(a))
        guard !Task.isCancelled else { adventure = snapshot; return }
        // A recalled note about someone the briefing already describes says nothing new.
        // Things made when the world was built stay locked until the story or the player brings
        // them up: an item nobody has mentioned is not offered to the storyteller.
        let spoken = a.transcript.map(\.text).joined(separator: " ") + " " + input
        let locked = a.lore.filter { ($0.kind == .item || $0.kind == .faction) && !$0.byPlayer && !Continuity.names(place: $0.name, in: spoken) }.map(\.name)
        var memories = recalled.filter { m in !a.cast.contains { m.hasPrefix($0.name) } && !locked.contains { m.hasPrefix($0) } }
        a.lastDirector = adventure?.lastDirector ?? a.lastDirector   // the director just noted which nudge it used

        if !hidden { a.transcript.append(StoryTurn(role: .player, text: input)) }
        pendingInput = nil
        adventure = a
        streaming = ""
        thinkingSince = Date()

        // The Game Master reviews the state and plans the reply (a separate, short model call).
        var plan = ""
        if planning {
            stage = "The Game Master is planning"
            if plan.isEmpty, !hidden {
                let told = revealName(&a, input: input, to: "", introduced: introduced)
                if !told.isEmpty { notes.insert("NAME: " + told + " Say it in this reply.", at: 0); adventure = a }
            }
            if plan.isEmpty { plan = await makePlan(snapshot: a, input: input, memories: memories, notes: notes) }
            guard !Task.isCancelled else { adventure = snapshot; return }
            // The plan has a fixed room in the budget; it never takes more.
            plan = Self.fitTokens(plan, Self.planRoom - 40)
        }
        // Room the plan was promised and did not use goes to the story's own recent words.
        // So does room kept for recalled memories that none came back to fill.
        if let oldest = kept.first, !oldest.1.text.hasPrefix("…") {
            var spare = planning ? max(0, Self.planRoom - 40 - Self.tokens(plan)) : 0
            spare += max(0, budget - used - memories.reduce(0) { $0 + Self.tokens($1) + 8 } - 40)
            for (i, t) in recent.reversed() where i < kept[0].0 {
                let cost = Self.tokens(t.text) + 8
                guard cost <= spare else { break }
                kept.insert((i, t), at: 0)
                spare -= cost
            }
        }
        var history = kept.map { ChatTurn(role: $0.1.role == .player ? .user : .assistant, text: $0.1.text) }
        if history.first?.role == .assistant { history.insert(ChatTurn(role: .user, text: "(The story begins.)"), at: 0) }
        history.append(ChatTurn(role: .user, text: briefing(memories, plan: plan)))
        if a.nameless {
            // The storyteller never sees a name the story hasn't said: people go by their role.
            let told = nameTold(a)
            system = Continuity.unnamed(system, in: a, playerTold: told)
            history = history.map { ChatTurn(role: $0.role, text: Continuity.unnamed($0.text, in: a, playerTold: told)) }
        }
        stage = "The storyteller is writing"
        a.gmWait = Date().timeIntervalSince(ticked)
        if narrate { narrator.begin() }
        var reply = ""
        var interrupted = false
        // Who is known to be somewhere else: they stay out of this reply (see PresenceFilter).
        // Nor do sentences of the last replies come back word for word.
        var presence: PresenceFilter? = nil
        var redrawn = false
        if !opening, !hidden {
            let f = PresenceFilter(absent: absentPeople(a, input: input, plan: plan),
                                   earlier: a.transcript.filter { $0.role == .gm }.suffix(3).map(\.text))
            if !f.idle { presence = f }
        }
        do {
            for try await piece in llm.stream(system: system, history: history, options: .init(maxTokens: maxOut, temperature: 0.85)) {
                if stage != "" {
                    stage = ""; thinkingSince = nil; forge?.close()
                    if !narrate { ComputerSounds.shared.stopHum() }   // otherwise it hums on until the voice starts
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
                let ok = presence!.finish(restore: true)
                reply = presence!.accepted
                streaming = reply
                if narrate, !ok.isEmpty { narrator.feed(ok) }
                if presence!.gutted {
                    // The check left almost nothing: the reply is written once more, with the reason
                    // in one line. If that comes to nothing either, the first version is let through.
                    let out = presence!.caught.map(\.name)
                    var note = "(Write the reply again in 80 to 140 words. "
                    if !out.isEmpty {
                        note += out.joined(separator: " and ") + (out.count == 1 ? " is" : " are")
                        note += " not part of this scene: do not show or quote them. "
                    }
                    note += "Stay with the player and whoever they are with. Use new sentences, none from earlier replies.)"
                    var again = history
                    if let last = again.popLast() { again.append(ChatTurn(role: .user, text: last.text + "\n\n" + note)) }
                    var second = PresenceFilter(absent: presence!.absent, earlier: a.transcript.filter { $0.role == .gm }.suffix(3).map(\.text))
                    let left = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    let survived = left.split(whereSeparator: \.isWhitespace).count < 12 ? "" : left
                    for try await piece in llm.stream(system: system, history: again, options: .init(maxTokens: 260, temperature: 0.85)) {
                        let ok = second.feed(piece)
                        streaming = (survived.isEmpty ? "" : survived + "\n\n") + second.preview
                        if narrate, !ok.isEmpty { narrator.feed(ok) }
                    }
                    let tail = second.finish(restore: false)
                    if narrate, !tail.isEmpty { narrator.feed(tail) }
                    let more = second.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
                    if more.split(whereSeparator: \.isWhitespace).count >= 20 {
                        reply = (survived.isEmpty ? "" : survived + "\n\n") + more
                        redrawn = true
                    } else {
                        let back = presence!.giveBack()
                        reply = presence!.accepted
                        if narrate, !back.isEmpty { narrator.feed(back) }
                    }
                    streaming = reply
                }
            }
        } catch LLMError.interrupted {
            interrupted = true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        if interrupted {
            // The app left the foreground mid-reply: drop the half-written reply and write it
            // again when the app comes back.
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
        // Small models slip the player's name into speech before anyone has heard it. Until the
        // player says it, it is taken out of the saved reply, so the slip never feeds later turns.
        if !nameTold(a), !a.cast.contains(where: \.known) { reply = Self.dropName(a.playerName, from: reply) }
        // The narration never addresses the player by name ("You are alone, Simon, ..."), only characters do.
        reply = Self.dropNameFromNarration(a.playerName, from: reply)
        guard !reply.isEmpty, !Task.isCancelled else {
            streaming = ""
            adventure = snapshot
            return
        }
        // The memory pass may have finished while the reply was written: keep what it learned.
        if let now = adventure, now.id == a.id { a.takeMemory(from: now) }
        // The opening scene is the first time the people appear in the story itself; anyone the bible
        // gave no clear pronouns for takes them from it.
        if opening { checkPronouns(&a, texts: [a.bible, reply]) }
        // Checks in code, every reply: a person called by the wrong pronouns, the time of day running
        // backwards or mixed, narration out of second person, or a prop the player never had. Each slip
        // becomes a correction for the next reply (until the reply after it).
        settleClock(&a, reply: reply, opening: opening)
        if !opening {
            a.fixes.removeAll { $0.hasPrefix(Self.checked) }
            a.fixes += continuitySlips(a, reply: reply).map { Self.checked + $0 }
            for p in presence?.caught ?? [] {
                a.fixes.append(Self.checked + "\(p.name) is not with the player: \(p.name) is \(Continuity.placed(p.at)) and stays out of the scene until the story shows them arriving.")
            }
        }
        var before: [String] = []
        // How the context was packed, so a playthrough can be reviewed (token counts are estimates).
        let memTokens: Int = memories.reduce(0) { $0 + Self.tokens($1) }
        let turnTokens: Int = kept.reduce(0) { $0 + Self.tokens($1.1.text) + 8 }
        let systemTokens = Self.tokens(system)
        let briefTokens = Self.tokens(briefing(memories, plan: plan))
        var ctx: [String] = []
        ctx.append("CONTEXT (about \(systemTokens + briefTokens + turnTokens + maxOut) of \(LLMService.contextBudget) tokens, \(maxOut) kept for the reply):")
        ctx.append("- rules and story bible: \(systemTokens)" + (tight > 0 ? " (squeezed to fit, level \(tight) of \(Self.tightest))" : ""))
        ctx.append("- briefing with memories and plan: \(briefTokens) (facts, continuity, notes and people alone: \(Self.tokens(briefing([]))))")
        ctx.append("- recent turns word for word: \(kept.count) of \(max(0, a.transcript.count - 1)) (\(turnTokens))")
        ctx.append("- recalled memories: \(memories.count) (\(memTokens), room for \(room * 2 / 7))")
        if !plan.isEmpty { ctx.append("- plan: \(Self.tokens(plan))") }
        ctx.append("- older turns folded into \(a.chapters.count) chapter summaries: \(a.summarisedTurns)")
        ctx.append("- continuity: \(a.timeline.count) timeline entries, \(a.whereabouts.count) people placed, \(a.facts.count) facts")
        before.append(ctx.joined(separator: "\n"))
        if !notes.isEmpty { before.append("DIRECTOR NOTES:\n" + notes.map { "- " + $0 }.joined(separator: "\n")) }
        if !memories.isEmpty { before.append("RECALLED MEMORIES:\n" + memories.map { "- " + $0 }.joined(separator: "\n")) }
        if planning, !planThoughts.isEmpty { before.append("REASONING:\n" + planThoughts) }
        if !plan.isEmpty { before.append((lastRead.isEmpty ? "" : "READ (fixed choices, settled in code): " + lastRead + "\n") + "PLAN:\n" + plan) }
        if let f = presence, !f.dropped.isEmpty {
            var why: [String] = f.caught.map { "\($0.name) is \(Continuity.placed($0.at)), not with the player" }
            if f.echoes > 0 { why.append("\(f.echoes) sentence\(f.echoes == 1 ? "" : "s") copied word for word from earlier replies") }
            if f.spokeForPlayer > 0 { why.append("the reply put words in the player's mouth") }
            let cut = f.dropped.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            var check = "REPLY CHECK (in code, as the reply was written): "
            if redrawn {
                check += "too little was left, so the reply was written again. First attempt, left out:\n" + cut
            } else if f.restored {
                check += "something should have been left out, but too little would have remained, so the reply was kept whole."
            } else {
                check += why.joined(separator: "; ") + ". Left out of the reply:\n" + cut
            }
            before.append(check)
        }
        a.transcript.append(StoryTurn(role: .gm, text: reply, before: before.isEmpty ? nil : before.joined(separator: "\n\n")))
        streaming = ""
        if a.left == 0 && !hidden { a.ended = true }
        adventure = a
        undoSnapshot = hidden ? nil : snapshot
        library.save(a)
        refreshVocabulary()

        if a.ended && !hidden {
            // The story is over: the ending screen offers Continue. The memory pass and the review
            // still read the final reply, so the tracker (place, scene, who is where, facts, time)
            // shows how the story ended, which is where the next part picks up.
            let exchange = "THE PLAYER: " + input + "\n\nTHE STORY: " + reply
            memoryJob = Task {
                await self.waitForVoice()
                await self.remember(exchange)
                if self.gmPlans { await self.review() }
            }
        } else if a.ended {
        } else if !hidden {
            let exchange = "THE PLAYER: " + input + "\n\nTHE STORY: " + reply
            // Background thinking while the reply is read aloud: wait until the voice has made its speech
            // (it needs the GPU), then the memory pass, then the Game Master's look-ahead.
            let memory = Task {
                await self.waitForVoice()
                await self.remember(exchange)
                if self.gmPlans { await self.review() }
            }
            memoryJob = memory
            // Housekeeping follows the memory pass, never alongside it (one model call at a time).
            housekeepingJob?.cancel()
            housekeepingJob = Task {
                await memory.value
                await self.housekeep()
            }
        } else if gmPlans {
            // After the opening scene: the first look-ahead (facts and the first move) while it is read.
            memoryJob = Task {
                await self.waitForVoice()
                await self.review()
            }
        }
        if !a.ended && (!narrate || !narrator.speaking) {
            busy = false
            listenIfReady()
        }
    }

    /// The longest plan the Game Master may write before a reply (without reasoning).
    static let planTokens = 260
    /// The plan's room in the reply's briefing, its heading included.
    static let planRoom = 290
    /// Kept free in every prompt, because token counts here are estimates.
    static let safetyTokens = 96
    /// Recalled memories always get at least this much room in a reply's briefing.
    static let minRecallTokens = 180
    /// The most the rules, bible and briefing can be squeezed (see `systemPrompt` and `briefingText`).
    static let tightest = 3
    /// Shown in the story export, so a playthrough can be matched to the code that ran it.
    static let build = "build 2026-11-11d"
    /// The plan's room with reasoning on: the thinking plus the plan (about a minute on a phone).
    static let deepPlanTokens = 1100

    /// Waits while a neural voice is still making speech, so background thinking never makes the
    /// narrator stop mid-sentence waiting for the GPU (at most a minute and a half).
    private func waitForVoice() async {
        var waited = 0.0
        while narrator.synthesizing, waited < 90, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 0.5
        }
    }

    /// Runs a background or planning call, with the model's reasoning when deep thinking is on.
    /// A model without a thinking mode (or one that thinks past its room) gives back nothing, and
    /// then the call is made again without it.
    /// Reasoning first, when it is on and the storyteller can do it (not GGUF models).
    var reasons: Bool { deepThinking && llm.canReason }

    private func think(_ prompt: String, quickTokens: Int, deepTokens: Int, temperature: Float, thoughts: ThoughtSink? = nil,
                       grammar: String? = nil) async -> String {
        if reasons {
            thinkBudget = deepTokens
            defer { thinkBudget = 0 }
            let out = (try? await llm.complete(system: nil, prompt: prompt,
                                               options: .init(maxTokens: deepTokens, temperature: 0.6, repetitionPenalty: 1.05, thinking: true,
                                                              thoughts: thoughts))) ?? ""
            if !out.isEmpty || Task.isCancelled { return out }
        }
        return (try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: quickTokens, temperature: temperature,
                                                                                   repetitionPenalty: 1.12, grammar: grammar))) ?? ""
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

    /// The Game Master's private plan for the next reply: it reviews a compact view of the story
    /// (the bible, the facts, its own look-ahead, the briefing, the last exchange and what the
    /// player just did) and decides what the reply must do. With deep thinking on, the model
    /// reasons first. The prompt plus the room to think stay inside the context the fit check
    /// planned for, so it never raises peak memory.
    private func makePlan(snapshot a: Adventure, input: String, memories: [String], notes: [String]) async -> String {
        planThoughts = ""
        let previous = a.transcript.dropLast().last(where: { $0.role == .player })?.text ?? ""
        // Built at full size, then squeezed until it fits beside the room to think and write (and the
        // few lines a second try adds).
        let room = (reasons ? Self.deepPlanTokens : Self.planTokens) + Self.safetyTokens + 160
        var prompt = ""
        for scale in [1.0, 0.75, 0.55, 0.4] {
            prompt = planPrompt(a, input: input, memories: memories, notes: notes, scale: scale)
            if Self.tokens(prompt) + room <= LLMService.contextBudget { break }
        }
        var lines = await planLines(prompt)
        // A plan about the player's earlier message (small models latch onto the last "player" text
        // they read) is made again once, with the mix-up pointed out.
        let said = lines.first { $0.range(of: #"^[-*\s]*PLAYER\**:"#, options: .regularExpression) != nil } ?? ""
        if Continuity.planIsStale(playerLine: said, input: input, previous: previous) {
            let first = planThoughts
            lines = await planLines(prompt + "\n\nCAREFUL: your first plan was about the earlier message (\"" + clip(previous, 160)
                                    + "\"), which is already answered. Plan for the NEW MESSAGE: " + clip(input, 400) + "\n\nYour five lines:")
            planThoughts = first.isEmpty ? planThoughts : first + "\n\n(Planned again: the first plan was about the earlier message.)\n" + planThoughts
        }
        // The PLAYER line is the player's own words, so it can never drift from what they said.
        guard lines.contains(where: { $0.range(of: #"^[-*\s]*PLAYER\**:"#, options: .regularExpression) == nil }) else { return "" }
        lines.removeAll { $0.range(of: #"^[-*\s]*PLAYER\**:"#, options: .regularExpression) != nil }
        lines.insert("PLAYER: " + clip(input.replacingOccurrences(of: "\n", with: " "), 300), at: 0)
        return clip(lines.joined(separator: "\n"), 1200)
    }

    // MARK: The grounded engine: read, fetch, paint, file

    /// How the player's new message was read: fixed choices, checked against what exists.
    struct PlayerRead {
        var to = ""          // a cast member's name, or "" for nobody
        var going = ""       // "" for staying, a known place, or "somewhere new"
        var newPlace = ""    // going somewhere new: its name, from the message
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
        if !menu.isEmpty { prompt += "\nCARDS: " + menu.joined(separator: "; ") }
        let played = a.elapsed / 60
        if let act = a.roadmap.first(where: { played >= $0.from && played <= $0.to }) ?? a.roadmap.first(where: { played < $0.to }) {
            prompt += "\nTHE STORY IS HEADING TOWARD (only if the player goes along): " + clip(act.goal, 220)
        }
        if let last = a.transcript.dropLast().last(where: { $0.role == .gm }) {
            prompt += "\n\nTHE STORY JUST SAID (already answered; context only):\n" + clip("…" + String(last.text.suffix(400)), 420)
        }
        prompt += "\n\nTHE PLAYER'S NEW MESSAGE: " + clip(input, 800)
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
        let prompt = context + "\n\n" + Prompts.lookQuestion + "\nThe form:"
        let grammar = JSONGrammar.look(cast: cast, places: places, cards: menu, people: cast)
        let reply = (try? await llm.complete(system: nil, prompt: prompt,
                                             options: .init(maxTokens: 120, temperature: 0.2, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
        guard let m = JSONExtract.object(reply) ?? Optional(Self.salvageJSON(reply)), !m.isEmpty else { return nil }
        func s(_ k: String) -> String { (m[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var read = PlayerRead()
        // Whatever came back is matched to what exists; anything else is "nobody" or "staying".
        let to = s("to").lowercased()
        read.to = cast.first { $0.lowercased() == to } ?? cast.first { n in
            guard let first = n.lowercased().split(separator: " ").first.map(String.init), first.count >= 3 else { return false }
            return to.split(whereSeparator: { !$0.isLetter }).map(String.init).contains(first)
        } ?? ""
        let going = s("going").lowercased()
        if going == "somewhere new" { read.going = "somewhere new" }
        else if let p = places.first(where: { $0.lowercased() == going }) { read.going = p }
        let named = s("new_place")
        if read.going == "somewhere new", named.count > 2, !Self.echoesPrompt(named) { read.newPlace = Self.ownPlace(named) }
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
        prompt += "\n\n" + Prompts.planQuestion + "\nThe form:"
        let reply = (try? await llm.complete(system: nil, prompt: prompt,
                                             options: .init(maxTokens: 200, temperature: 0.2, repetitionPenalty: 1.1, grammar: JSONGrammar.plan))) ?? ""
        let m = JSONExtract.object(reply) ?? Self.salvageJSON(reply)
        func s(_ k: String) -> String { (m[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        read.answer = Self.echoesPrompt(s("answer")) ? "" : clip(s("answer"), 260)
        read.beat = Self.echoesPrompt(s("beat")) ? "" : clip(s("beat"), 260)
        read.does = Self.echoesPrompt(s("does")) ? "" : clip(s("does"), 200)
        // The restated action must be the player's own words: one that adds what they didn't say
        // ("You tell her your name is Clara") is dropped, and the message itself is used.
        let castWords: String = a.cast.map { $0.name + " " + $0.role }.joined(separator: " ")
        let ownText: String = input + " you yourself " + a.playerName + " " + castWords
        let own = Continuity.wordSet(ownText)
        if !read.does.isEmpty, !Continuity.grounded(read.does, in: own, share: 0.5) {
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
    private func settle(_ a: inout Adventure, read: PlayerRead, input: String) {
        let said = Continuity.wordSet(input)
        let me = a.playerName.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let addressed = read.to.lowercased().split(separator: " ").first.map(String.init) ?? ""
        // Leaving takes two things agreeing: the reading, and words that read like going somewhere
        // (or the player already being on the way).
        let leaving = !read.going.isEmpty && (Continuity.leavesPlace(input) || a.location.isEmpty)
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
                if comes {
                    a.whereabouts[i].here = true; a.whereabouts[i].engaged = true; a.whereabouts[i].leftAt = nil
                } else if a.whereabouts[i].here != false {
                    a.whereabouts[i].here = false; a.whereabouts[i].engaged = false; a.whereabouts[i].leftAt = from
                } else if let at = a.whereabouts[i].leftAt, !at.isEmpty, at.caseInsensitiveCompare(read.going) == .orderedSame {
                    a.whereabouts[i].here = true; a.whereabouts[i].leftAt = nil
                }
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
        lines.append("ANSWER: " + (answer.isEmpty ? "none" : answer))
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
    private func runGroundedTurn(input: String, hidden: Bool, forceFinal: Bool) async {
        guard var a = adventure else { return }
        let turnBegan = Date()
        ComputerSounds.shared.startHum()
        housekeepingJob?.cancel()
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
        }
        let snapshot = a
        placeBeforeTurn = a.location
        lastRead = ""
        planThoughts = ""
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
        }
        // The last turn the player was in this place, for a catch-up when they come back.
        if !a.location.isEmpty { a.placeSeen[a.location.lowercased()] = a.playerTurns }
        let opening = hidden && a.transcript.isEmpty
        let maxOut = opening ? 520 : 300
        let playerNarrates = !hidden && Self.narrates(input)
        let playerAsks = !hidden && !playerNarrates && Self.asks(input)
        namesThisTurn = []
        var introduced = hidden ? false : learnPlayerName(&a, input: input)
        // "I walk over to introduce myself": the player gives the name the story already knows.
        if !hidden, a.nameless, !a.playerName.isEmpty,
           input.range(of: #"(?i)\bintroduc(e|es|ing) (myself|me)\b"#, options: .regularExpression) != nil { introduced = true }

        if !hidden { a.transcript.append(StoryTurn(role: .player, text: input)) }
        pendingInput = nil
        adventure = a
        streaming = ""
        thinkingSince = Date()

        // 1. Look. One short call: who the player turns to, where they go, and what to look up.
        var read: PlayerRead? = nil
        let context = readContext(a, input: input)
        if !hidden, !playerNarrates, gmPlans {
            stage = "Looking around"
            read = await lookPlayer(a, input: input, context: context)
            guard !Task.isCancelled else { adventure = snapshot; return }
        }

        // 2. Settle and look up. Code settles who the player is with and where, then answers each
        // lookup from the store (and adds a few of its own: the person the player turns to, a card
        // the message names).
        var moment = ""
        var extra: [String] = []
        var looked: [Looks.Answer] = []
        catchUpNotes = []
        if !hidden, !playerNarrates {
            settle(&a, read: read ?? PlayerRead(), input: input)
            if read == nil { lastRead = (gmPlans ? "no usable reading; " : "reading off; ") + lastRead }
            // Arriving somewhere with no description yet: the place is built before the reply, so
            // the reply can bring it to life.
            let arrived = !a.location.isEmpty && a.location.caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
            if arrived, let card = Cards.placeCard(a), card.desc.isEmpty, !card.byPlayer {
                stage = "Building " + a.location
                let built = await buildPlace(&a)
                guard !Task.isCancelled else { adventure = snapshot; return }
                if !built.isEmpty {
                    catchUpNotes.append("Built: " + built)
                    lastRead += "; built " + a.location
                }
            }
            // Back in a place after a good while away: one short question catches it up.
            let back = !a.location.isEmpty && a.location.caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
            if back, let seen = a.placeSeen[a.location.lowercased()], a.playerTurns - seen >= Self.catchUpTurns {
                let gap = a.playerTurns - seen
                stage = "Catching up on " + a.location
                let changes = await catchUp(&a, turns: gap)
                guard !Task.isCancelled else { adventure = snapshot; return }
                if !changes.isEmpty {
                    extra.append("SINCE YOU WERE LAST HERE: " + changes.joined(separator: " "))
                    catchUpNotes += changes.map { "While you were away: " + $0 }
                    lastRead += "; caught up on " + a.location + " after \(gap) turns away"
                }
            }
        }
        if !hidden {
            let asked = read?.looks ?? []
            let looks = asked + Looks.auto(a, input: input, to: read?.to ?? "", asked: asked)
            stage = looks.isEmpty ? "Gathering the world" : "Looking things up"
            for l in looks {
                var ans = Looks.answer(l, in: a)
                if l.kind == .remember {
                    let recent = Set(a.transcript.suffix(5).map(\.id))
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
            }
        }
        // Read, question 2: the moment, planned from what was looked up.
        if read != nil {
            stage = "Planning the moment"
            await planPlayer(a, input: input, context: context, looked: looked, into: &read!)
            guard !Task.isCancelled else { adventure = snapshot; return }
        }
        if !hidden, !playerNarrates {
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
        let pick = Cards.pick(a, input: hidden ? "" : input, opening: opening, around: around)
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
        let lead = "[GAME MASTER BRIEFING: private, for this reply only]\n" + card + "\n[END OF BRIEFING]\n\n" + (hidden ? "INSTRUCTION: " : "THE PLAYER: ") + input
        // The story's own last turns keep its voice and thread: as many of the last four as fit.
        // Anything older is reached with a "remember" lookup.
        let budget = LLMService.contextBudget - maxOut - Self.safetyTokens
        var used = Self.tokens(system) + Self.tokens(lead)
        var kept: [StoryTurn] = []
        let past = hidden ? a.transcript : Array(a.transcript.dropLast())
        for t in past.suffix(4).reversed() {
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
        }
        stage = "The storyteller is writing"
        a.gmWait = Date().timeIntervalSince(ticked)
        if narrate { narrator.begin() }
        var reply = ""
        var interrupted = false
        var presence: PresenceFilter? = nil
        var redrawn = false
        if !opening, !hidden {
            let f = PresenceFilter(absent: absentPeople(a, input: input, plan: moment),
                                   earlier: a.transcript.filter { $0.role == .gm }.suffix(3).map(\.text))
            if !f.idle { presence = f }
        }
        do {
            for try await piece in llm.stream(system: system, history: history, options: .init(maxTokens: maxOut, temperature: 0.85)) {
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
                if presence!.gutted {
                    // The check left almost nothing: the reply is written once more, with the reason in one line.
                    let out = presence!.caught.map(\.name)
                    var note = "(Write the reply again in 80 to 140 words. "
                    if !out.isEmpty {
                        note += out.joined(separator: " and ") + (out.count == 1 ? " is" : " are")
                        note += " not part of this scene: do not show or quote them. "
                    }
                    note += "Stay with the player and whoever they are with. Use new sentences, none from earlier replies.)"
                    var again = history
                    if let last = again.popLast() { again.append(ChatTurn(role: .user, text: last.text + "\n\n" + note)) }
                    var second = PresenceFilter(absent: presence!.absent, earlier: a.transcript.filter { $0.role == .gm }.suffix(3).map(\.text))
                    let left = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    let survived = left.split(whereSeparator: \.isWhitespace).count < 12 ? "" : left
                    for try await piece in llm.stream(system: system, history: again, options: .init(maxTokens: 260, temperature: 0.85)) {
                        let ok = second.feed(piece)
                        streaming = (survived.isEmpty ? "" : survived + "\n\n") + second.preview
                        if narrate, !ok.isEmpty { narrator.feed(ok) }
                    }
                    let tail = second.finish(restore: false)
                    if narrate, !tail.isEmpty { narrator.feed(tail) }
                    let more = second.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
                    if more.split(whereSeparator: \.isWhitespace).count >= 20 {
                        reply = (survived.isEmpty ? "" : survived + "\n\n") + more
                        redrawn = true
                    } else {
                        let back = presence!.giveBack()
                        reply = presence!.accepted
                        if narrate, !back.isEmpty { narrator.feed(back) }
                    }
                    streaming = reply
                }
            }
        } catch LLMError.interrupted {
            interrupted = true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
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
        if !nameTold(a), !a.cast.contains(where: \.known) { reply = Self.dropName(a.playerName, from: reply) }
        reply = Self.dropNameFromNarration(a.playerName, from: reply)
        guard !reply.isEmpty, !Task.isCancelled else {
            streaming = ""
            adventure = snapshot
            return
        }
        if let now = adventure, now.id == a.id { a.takeMemory(from: now) }
        if opening { checkPronouns(&a, texts: [a.bible, reply]) }
        settleClock(&a, reply: reply, opening: opening)
        if !opening {
            a.fixes.removeAll { $0.hasPrefix(Self.checked) }
            a.fixes += continuitySlips(a, reply: reply).map { Self.checked + $0 }
            for p in presence?.caught ?? [] {
                a.fixes.append(Self.checked + "\(p.name) is not with the player: \(p.name) is \(Continuity.placed(p.at)) and stays out of the scene until the story shows them arriving.")
            }
        }
        a.scene = Cards.sceneLine(a)

        // Behind the scenes, for the story export: short, and every step shown.
        var before: [String] = []
        if !hidden {
            if read == nil, !playerNarrates {
                before.append("READ: " + (gmPlans ? "nothing usable came back; code settled the scene alone" : "off (planning is off)"))
            } else if let r = read {
                let to: String = r.to.isEmpty ? "nobody" : r.to
                let motion: String = r.going.isEmpty ? "staying" : "going: " + r.going
                let asked: String = r.looks.isEmpty ? "nothing" : r.looks.map(\.text).joined(separator: ", ")
                var l = "LOOK: to \(to) · \(motion) · asked to look up: \(asked)"
                if !r.does.isEmpty { l += "\nPLAN:\n  does: " + r.does }
                if !r.answer.isEmpty { l += "\n  answer: " + r.answer }
                if !r.beat.isEmpty { l += "\n  next: " + r.beat }
                before.append(l)
            } else {
                before.append("READ: skipped (the player is narrating; their words are canon)")
            }
            if !lastRead.isEmpty { before.append("SETTLED IN CODE: " + lastRead) }
        }
        if !looked.isEmpty {
            let lines: [String] = looked.map { ans in
                let who: String = ans.look.byCode ? " (added by code)" : ""
                return "  - " + ans.look.text + who + " → " + clip(ans.text.isEmpty ? "nothing" : ans.text, 160)
            }
            before.append("LOOKED UP:\n" + lines.joined(separator: "\n"))
        }
        let inView: [String] = pick.why.map { "  - " + $0 }
        before.append("IN VIEW:\n" + inView.joined(separator: "\n"))
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
        a.transcript.append(StoryTurn(role: .gm, text: reply, before: before.joined(separator: "\n")))
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
        let premise = Cards.premise(a)
        if !premise.isEmpty { s += "\n\n## THE STORY\n" + premise }
        let pinned = a.lore.filter { $0.byPlayer && !$0.isPlayer }
        if !pinned.isEmpty {
            s += "\n\n## FACTS THE PLAYER SET (always true)\n" + pinned.prefix(6).map { "- \($0.name): " + clip($0.desc, 200) }.joined(separator: "\n")
        }
        return s
    }

    /// At most a few notes for this reply, only where they apply: the opening, a question, the
    /// player moving, narrating, the end of the session, and phrases that keep coming back.
    private func groundedNotes(_ a: Adventure, input: String, going: Bool, opening: Bool, playerNarrates: Bool, playerAsks: Bool) -> [String] {
        if opening {
            let me = a.lore.first(where: \.isPlayer)?.desc ?? ""
            return [
                "THIS IS THE OPENING SCENE, and it may run to about 200 words. The listener cannot see anything yet: first tell them plainly where they are" + (a.location.isEmpty ? "" : " (\(a.location))") + ", what they are doing and who is there, then paint it with sound, smell, light and texture.",
                me.isEmpty ? "Make clear who the player is and why they are here." : "Make clear who the player is (\(clip(me, 160))) and why they are here.",
                "Set up the feeling (" + (a.setup.feeling.isEmpty ? "the one the player came for" : a.setup.feeling) + ") from the first lines, and end on someone turned to the player.",
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
        // Notes the turn already made (a catch-up on a place) stay with the snapshot.
        let open: WorldFrame? = start.frames.last.flatMap { $0.turn == start.playerTurns ? $0 : nil }
        var notes: [String] = open?.notes ?? []
        defer { rebuildStep = "" }

        func roleOf(_ c: LoreEntry) -> String { c.role.isEmpty ? "" : " (the story may call them \"" + Continuity.roleLabel(c.role) + "\")" }
        var base = Prompts.rebuildIntro
        base += "\n\nPLACE BEFORE: " + (start.location.isEmpty ? "(not named yet: the player just went somewhere new)" : start.location)
        let peopleLines: [String] = start.cast.map { $0.name + roleOf($0) }
        base += "\nPEOPLE IN THE STORY: " + (peopleLines.isEmpty ? "(none)" : peopleLines.joined(separator: "; "))
        if !playerSaid.isEmpty { base += "\n\nTHE PLAYER: " + clip(playerSaid, 500) }
        base += "\n\nTHE STORY: " + clip(reply, 1400) + "\n\nQUESTION: "

        func ask(_ label: String, _ question: String, _ grammar: String, _ tokens: Int) async -> [String: Any]? {
            guard !Task.isCancelled else { return nil }
            rebuildStep = label
            let raw = (try? await llm.complete(system: nil, prompt: base + question,
                                               options: .init(maxTokens: tokens, temperature: 0.2, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
            guard !Task.isCancelled else { return nil }
            return JSONExtract.object(raw) ?? Self.salvageJSON(raw)
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
            if let i = now.transcript.firstIndex(where: { $0.id == lastID }) {
                var note = "REBUILT:" + (asked.isEmpty ? " nothing asked yet" : "\n" + asked.map { "  - " + $0 }.joined(separator: "\n"))
                if !filed.isEmpty { note += "\nFILED:\n" + filed.map { "  - " + $0 }.joined(separator: "\n") }
                if !refused.isEmpty { note += "\nREFUSED (not in the story's words): " + refused.prefix(6).joined(separator: "; ") }
                now.transcript[i].after = note
            }
            Self.updateFrame(&now, asked: asked, notes: notes)
            adventure = now
        }

        // 1. Where is the player now? A place picked from the map, or a new one by name.
        let known = start.places.filter { !$0.isEmpty }
        var options: [String] = start.location.isEmpty ? [] : [start.location]
        options += known.filter { $0.caseInsensitiveCompare(start.location) != .orderedSame }.suffix(6)
        options.append("somewhere new")
        let pm = await ask("Where are you now?", Prompts.rebuildPlace + "\nTHE LIST: " + options.joined(separator: "; "),
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

        // 2. Who is with the player at the end? Someone counts as arriving or leaving only when the
        // reply itself shows them.
        let cast = start.cast
        if !cast.isEmpty {
            let hm = await ask("Who is with you?", Prompts.rebuildPeople + "\nTHE LIST: " + cast.map { $0.name + roleOf($0) }.joined(separator: "; "),
                               JSONGrammar.names("here", from: cast.map(\.name), max: 6), 80)
            guard hm != nil else { return }
            let listed = ((hm?["here"] as? [Any]) ?? []).compactMap { $0 as? String }
            asked.append("Who is with you? → " + (listed.isEmpty ? "nobody" : listed.joined(separator: ", ")))
            let leaves = #"(?i)\b(leaves|walks out|heads (out|off)|goes out|disappears|slips out|steps out|is gone|walks away|hurries off)\b"#
            commit { now in
                for c in cast {
                    let isListed = listed.contains { $0.caseInsensitiveCompare(c.name) == .orderedSame }
                    let shown = Cards.mentions(c, in: reply)
                    guard shown else { continue }
                    if let i = now.whereabouts.firstIndex(where: { Cards.card(for: $0, in: now)?.id == c.id }) {
                        if isListed, now.whereabouts[i].here == false {
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

        // 3. What is each person in view doing? One short question each, for the ones the reply shows.
        let mid: Adventure = adventure ?? start
        var inView: [LoreEntry] = []
        for w in mid.whereabouts where w.here != false {
            let f = Cards.first(w.name).lowercased()
            guard f != me, f != "you", let c = Cards.card(for: w, in: mid), Cards.mentions(c, in: reply) else { continue }
            inView.append(c)
        }
        for c in inView.prefix(3) {
            let dm = await ask("What is " + c.name + " doing?", Prompts.rebuildDoing(c.name + roleOf(c)), JSONGrammar.text("doing", chars: 80), 40)
            guard dm != nil else { return }
            let doing = (dm?["doing"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard doing.count > 3, !Self.echoesPrompt(doing) else { continue }
            asked.append(c.name + " doing? → " + doing)
            commit { now in
                guard let i = now.whereabouts.firstIndex(where: { Cards.card(for: $0, in: now)?.id == c.id }), now.whereabouts[i].here != false else { return }
                now.whereabouts[i].doing = clip(doing, 100)
            }
        }

        // 4. What does the player have? New things are added; a thing leaves only when the moment
        // shows it going. Only what this reply shows counts (ordering a drink is not having it).
        let had = start.carrying.isEmpty ? "(nothing listed)" : start.carrying.joined(separator: "; ")
        let cm = await ask("What do you have?", "YOU HAD: " + had + "\n" + Prompts.rebuildCarrying, JSONGrammar.strings("has", max: 6, chars: 60), 120)
        guard cm != nil else { return }
        let inReply = Continuity.wordSet(reply)
        let held = checked(strings(cm, "has", cap: 6).map { clip($0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), 70) }).filter { h in
            if start.carrying.contains(where: { Self.similar($0, h) }) || Continuity.grounded(h, in: inReply) { return true }
            refused.append(h + " (not in this reply)")
            return false
        }
        asked.append("What do you have? → " + (held.isEmpty ? "nothing new" : held.joined(separator: "; ")))
        commit { now in
            guard !held.isEmpty else { return }
            let said = (playerSaid + " " + reply).lowercased()
            let gone = #"\b(give|gives|gave|given|hand|hands|handed|pay|pays|paid|sell|sold|eat|eats|ate|eaten|drink|drank|finish|finished|drop|dropped|leave|left|put|puts|set|sets|place|places|placed|slide|slides|slid|lose|lost|toss|tossed|swap|swapped|trade|traded)\b"#
            let parting = said.range(of: gone, options: .regularExpression) != nil
            var ledger = held
            for old in start.carrying where !held.contains(where: { Self.similar($0, old) }) {
                let noun = old.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
                if parting, noun.count >= 3, said.contains(noun) { filed.append("Gone from your hands: " + old); continue }
                ledger.append(old)
            }
            for h in held where !start.carrying.contains(where: { Self.similar($0, h) }) { filed.append("You have: " + h) }
            now.carrying = Array(ledger.prefix(8))
        }

        // 5. What is around? Only what this reply showed, kept with the place.
        let tm = await ask("What is around?", Prompts.rebuildThings, JSONGrammar.strings("things", max: 6, chars: 60), 120)
        guard tm != nil else { return }
        let around = checked(strings(tm, "things", cap: 6).map { clip($0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), 70) }).filter { e in
            if Continuity.grounded(e, in: inReply) { return true }
            refused.append(e)
            return false
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

        // 6. Anything lasting? Filed under the person it names (the role a nameless story uses
        // becomes the name).
        let late: Adventure = adventure ?? start
        var present: [LoreEntry] = []
        for w in late.whereabouts where w.here != false {
            if let c = Cards.card(for: w, in: late) { present.append(c) }
        }
        let knownFacts = present.flatMap { Cards.facts(about: $0, in: start).suffix(3) } + start.facts.suffix(3)
        var fq = Prompts.rebuildFacts
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
        asked.append("Anything lasting? → " + (fresh.isEmpty ? "nothing new" : fresh.joined(separator: " ")))
        commit { now in
            var facts = now.facts
            for f in fresh where !facts.contains(where: { Self.similar($0, f) }) {
                if let i = facts.firstIndex(where: { Self.sameOpening($0, f) }) { facts[i] = clip(f, 200) } else { facts.append(clip(f, 200)) }
                let under = start.cast.first { Cards.mentions($0, in: f) }?.name ?? (f.hasPrefix("You") ? "you" : "the world")
                filed.append("Fact, under \(under): " + f)
                notes.append("Learned: " + f)
            }
            // The store can hold many facts: only the ones a lookup asks for are ever sent.
            if facts.count > 40 { facts = Array(facts.prefix(6) + facts.suffix(34)) }
            now.facts = facts
        }
        guard var now = adventure, now.id == start.id else { return }
        if !now.location.isEmpty { now.placeSeen[now.location.lowercased()] = now.playerTurns }
        now.checks = Self.worldChanges(from: start, to: now, refused: refused, named: namesThisTurn)
        adventure = now
        library.save(now)
    }

    /// Updates the turn guide's snapshot with what was looked up before the reply.
    private func recordFrame(looked: [String]) {
        guard var a = adventure else { return }
        Self.updateFrame(&a, looked: looked, asked: [], notes: catchUpNotes)
        adventure = a
    }

    /// "my hotel room" as a place name: "Your hotel room".
    static func ownPlace(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'"))
        for p in ["my ", "My "] where s.hasPrefix(p) { s = "your " + s.dropFirst(p.count) }
        return s.prefix(1).uppercased() + String(s.dropFirst())
    }

    /// Builds a place the player arrives in: one short call writes its description and a few
    /// things in it, true to the premise. Returns a short summary for the turn guide.
    private func buildPlace(_ a: inout Adventure) async -> String {
        guard let i = a.lore.firstIndex(where: { $0.kind == .place && $0.name.caseInsensitiveCompare(a.location) == .orderedSame }) else { return "" }
        var prompt = "You build places for an audio story."
        let premise = Cards.premise(a)
        if !premise.isEmpty { prompt += "\n\nTHE STORY: " + clip(premise, 500) }
        if !a.storyTime.isEmpty { prompt += "\nTIME: " + a.storyTime }
        let ground = a.facts.prefix(8).filter { f in !a.cast.contains { Cards.mentions($0, in: f) } && !f.hasPrefix("You") }.prefix(2)
        if !ground.isEmpty { prompt += "\nTHE WORLD: " + ground.joined(separator: " ") }
        if !placeBeforeTurn.isEmpty { prompt += "\nCOMING FROM: " + placeBeforeTurn }
        prompt += "\nTHE PLACE: " + a.location
        prompt += "\n\n" + Prompts.buildPlace
        let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                           options: .init(maxTokens: 200, temperature: 0.6, repetitionPenalty: 1.1, grammar: JSONGrammar.place))) ?? ""
        let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
        let desc = ((m["desc"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let things: [String] = ((m["things"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 3 && !Self.echoesPrompt($0) && !Self.brokenEntry($0) }
        guard desc.count > 20, !Self.echoesPrompt(desc) else { return "" }
        a.lore[i].desc = clip(desc, 300)
        if !things.isEmpty {
            a.placeThings[a.location.lowercased()] = Array(things.prefix(5))
            a.things = Array(things.prefix(5))
        }
        return a.location + (things.isEmpty ? "" : " (" + things.prefix(5).joined(separator: "; ") + ")")
    }

    /// How many turns away from a place before coming back to it asks what changed meanwhile.
    static let catchUpTurns = 5

    /// Coming back to a place after a good while away: one short question catches it up (who of
    /// the people left there is still there, and what ordinary things changed). Returns the changes,
    /// for the briefing and the turn guide.
    private func catchUp(_ a: inout Adventure, turns gap: Int) async -> [String] {
        let key = a.location.lowercased()
        let left = a.whereabouts.filter { $0.here != false && Cards.first($0.name).lowercased() != Cards.first(a.playerName).lowercased() }.map(\.name)
        var prompt = "You keep an audio story's world consistent."
        let desc: String = Cards.placeCard(a)?.desc ?? ""
        prompt += "\n\nPLACE: " + a.location
        if !desc.isEmpty { prompt += ": " + clip(desc, 240) }
        let things = a.placeThings[key] ?? []
        if !things.isEmpty { prompt += "\nTHINGS HERE: " + things.prefix(6).joined(separator: "; ") }
        prompt += "\nPEOPLE LEFT HERE: " + (left.isEmpty ? "(nobody)" : left.joined(separator: "; "))
        prompt += "\nTIME AWAY: the player has been elsewhere for \(gap) turns of the story"
        prompt += "\n\n" + Prompts.awayQuestion
        let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                           options: .init(maxTokens: 120, temperature: 0.4, repetitionPenalty: 1.1, grammar: JSONGrammar.away(people: left)))) ?? ""
        let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
        guard !m.isEmpty else { return [] }
        let still = ((m["still_here"] as? [Any]) ?? []).compactMap { $0 as? String }
        var out: [String] = []
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
    static func updateFrame(_ a: inout Adventure, looked: [String]? = nil, asked: [String]? = nil, notes: [String]? = nil) {
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
        if let looked { f.looked = looked }
        if let asked { f.asked = asked }
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

    /// One planning call; keeps only the plan lines, in case the model wanders into the story itself.
    private func planLines(_ prompt: String) async -> [String] {
        let sink = ThoughtSink()
        let reply = await think(prompt, quickTokens: Self.planTokens, deepTokens: Self.deepPlanTokens, temperature: 0.4, thoughts: sink)
        planThoughts = sink.clean
        return reply.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^[-*\s]*(PLAYER|ANSWER|BEAT|WHO|USE)\**:"#, options: .regularExpression) != nil }
    }

    /// The planner's prompt. `scale` shrinks every long part together when it must fit a smaller room;
    /// the player's new message is never cut and always comes last.
    private func planPrompt(_ a: Adventure, input: String, memories: [String], notes: [String], scale: Double) -> String {
        func n(_ chars: Int) -> Int { Int(Double(chars) * scale) }
        var prompt = Prompts.gmPlan + "\n\nSTORY BIBLE:\n" + clip(a.bible, n(1200))
        let limits = limitsText(a)
        if !limits.isEmpty { prompt += "\n\nSET-UP LIMITS (never break):\n" + limits }
        let facts = factsText(a)
        if !facts.isEmpty { prompt += "\n\n" + clip(facts, n(1200)) }
        if !a.nextMove.isEmpty { prompt += "\n\nYOUR LOOK-AHEAD (written before the player spoke; only if they went along):\n" + clip(a.nextMove, n(500)) }
        if let notes = a.notes, !notes.text.isEmpty { prompt += "\n\nPRIVATE NOTES:\n" + clip(notes.text, n(500)) }
        else if !a.secrets.isEmpty { prompt += "\n\nPRIVATE NOTES:\n" + a.secrets.prefix(4).map { "- " + clip($0, n(160)) }.joined(separator: "\n") }
        if let m = a.mood.feeling { prompt += "\n\nFEELING READING: \(m)/10" + (a.mood.enjoying.isEmpty ? "" : ", enjoying " + a.mood.enjoying) + (a.mood.leavingPlot ? ", leaving the plot" : "") }
        prompt += "\n\nSTORY STATE:\n" + clip(briefingText(a, memories: memories, director: notes, withFacts: false, tight: scale < 0.7 ? 1 : 0), n(reasons ? 2200 : 3600))
        // The earlier exchange is labelled so it can't be mistaken for the new message.
        let last = a.transcript.dropLast().suffix(2)   // the player's new words are the last turn
        if !last.isEmpty {
            prompt += "\n\nEARLIER EXCHANGE (already answered; context only):\n"
                + last.map { ($0.role == .player ? "Earlier, the player said: " : "The story replied: ") + clip($0.text, n(600)) }.joined(separator: "\n")
        }
        let continuity = continuityText(a, tight: scale < 0.7 ? 1 : 0)
        if !continuity.isEmpty { prompt += "\n\n" + clip(continuity, n(1400)) }
        prompt += "\n\nTHE PLAYER'S NEW MESSAGE (plan for this one): " + clip(input, 800) + "\n\nYour five lines:"
        return prompt
    }

    /// The look-ahead: while the reply is read aloud, the Game Master checks it against the bible,
    /// the facts and the set-up limits, keeps the facts current, notes slips to correct from now on,
    /// and proposes the next move. Runs after the memory pass, one model call, inside the context
    /// budget like every other call.
    private func review() async {
        guard !Task.isCancelled, let start = adventure, start.transcript.last?.role == .gm else { return }
        let room = (reasons ? Self.reviewDeepTokens : Self.reviewTokens) + Self.safetyTokens
        var prompt = ""
        for scale in [1.0, 0.75, 0.55, 0.4] {
            prompt = reviewPrompt(start, scale: scale)
            if Self.tokens(prompt) + room <= LLMService.contextBudget { break }
        }
        let sink = ThoughtSink()
        let reply = await think(prompt, quickTokens: Self.reviewTokens, deepTokens: Self.reviewDeepTokens, temperature: 0.3, thoughts: sink,
                                grammar: JSONGrammar.review(cast: start.cast.map(\.name)))
        guard !Task.isCancelled, var now = adventure, now.id == start.id else { return }
        // A review that loops or runs out of room never closes its JSON: keep what it finished. Then
        // the shape is checked: lists that came back as one string are split, and anything still
        // missing that the next turn needs (the scene, the people, the facts, the next move) is asked
        // for again in a short follow-up call.
        let raw = JSONExtract.object(reply) ?? Self.salvageJSON(reply)
        let shape = Continuity.normaliseReview(raw)
        var m = shape.review
        let missing = shape.missing
        var note = ""
        if !raw.isEmpty, !missing.isEmpty {
            let extra = Continuity.normaliseReview(await repairReview(start, missing: missing)).review
            guard !Task.isCancelled, let latest = adventure, latest.id == start.id else { return }
            now = latest
            for k in missing { if let v = extra[k] { m[k] = v } }
            let still = Continuity.normaliseReview(m).missing
            note = "\n\n(Checked in code: the review was missing " + missing.joined(separator: ", ")
                + (still.isEmpty ? "; asked again and filled in.)" : "; still missing after asking again: " + still.joined(separator: ", ") + ".)")
        }
        // Keep the review with the reply it looked at, for the story export.
        let lastReply = start.transcript.last?.text ?? ""
        if let id = start.transcript.last?.id, let i = now.transcript.firstIndex(where: { $0.id == id }) {
            let thought = sink.clean
            now.transcript[i].after = (thought.isEmpty ? "" : "REASONING:\n" + thought + "\n\n") + "REVIEW:\n" + (reply.isEmpty ? "(no reply)" : reply) + note
        }
        guard !m.isEmpty else { adventure = now; library.save(now); return }
        // Everything the review says is checked in code before it is kept: no copies of the
        // instructions' own example text, no repeated lines, and short lists.
        func text(_ k: String) -> String? {
            guard let v = (m[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), v.count > 3, !Self.echoesPrompt(v) else { return nil }
            return v
        }
        func list(_ k: String, cap: Int) -> [String] {
            var out: [String] = []
            for item in ((m[k] as? [Any]) ?? []) {
                guard let v = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), v.count > 3, !Self.echoesPrompt(v),
                      !Self.brokenEntry(v) else { continue }
                if !out.contains(where: { Self.similar($0, v) }) { out.append(v) }
                if out.count >= cap { break }
            }
            return out
        }
        // The review names only what is new; the list itself is kept here, so a small model never
        // has to write it all out again (which took most of its room and often cut the review short).
        // A new fact that says an old one better takes its place. (A model without the grammar may
        // still send the whole list as "facts"; it is read the same way.)
        let people = start.cast.map(\.name) + [start.playerName]
        // The card checker: whatever the review wants on the card must be in the story's own words
        // (the bible and everything said so far). What is not is refused and noted in the export.
        let story = Continuity.wordSet(start.bible + " " + start.transcript.map(\.text).joined(separator: " "))
        var refused: [String] = []
        func checked(_ entries: [String], share: Double = 0.6) -> [String] {
            entries.filter { e in
                if Continuity.grounded(e, in: story, share: share) { return true }
                refused.append(e)
                return false
            }
        }
        // The update is told which role is which person; it sometimes writes the role in quotes
        // ("the bartender" told you...). Facts are kept with the person's name, without the quotes.
        let roles = Continuity.hiddenNames(start)
        func named(_ f: String) -> String {
            var f = f
            for r in roles {
                f = f.replacingOccurrences(of: "\"" + r.role + "\"", with: r.name, options: .caseInsensitive)
            }
            return f.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }
        let fresh = checked((list("new_facts", cap: 6) + list("facts", cap: 30)).map(named).flatMap { $0.count > 180 ? Self.sentences($0) : [$0] }, share: 0.5)
            .compactMap { Continuity.lastingFact($0, people: people) }
        var facts = now.facts
        for f in fresh {
            if let i = facts.firstIndex(where: { Self.similar($0, f) || Self.sameOpening($0, f) }) { facts[i] = clip(f, 200) } else { facts.append(clip(f, 200)) }
        }
        // The first facts are the story's foundation (pronouns, the city); the newest are what just happened.
        if facts.count > 15 { facts = Array(facts.prefix(6) + facts.suffix(9)) }
        now.facts = facts
        // A pronoun "fix" for something the reply got right is a false alarm (code checks pronouns itself).
        let castNames = start.cast.map(\.name)
        var fixes = list("fixes", cap: 1).filter { !Continuity.bogusPronounFix($0, reply: lastReply, cast: castNames) }.map { clip($0, 200) }
        if let u = text("unanswered"), u.count > 8 {
            fixes.append("Still unanswered, answer it plainly next: " + clip(u, 300))
        }
        now.fixes = fixes + now.fixes.filter { $0.hasPrefix(Self.checked) }
        if let n = text("next") { now.nextMove = clip(n, 600) }
        if let sc = text("scene"), sc.count > 10 { now.scene = clip(sc, 320) }
        // The scene card's lists. What the player has is replaced whenever the review gives it (an
        // empty list means empty hands); the things in the place are replaced when it names some.
        func items(_ k: String, cap: Int) -> [String] {
            list(k, cap: cap).map { clip($0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), 70) }.filter { $0.count >= 3 }
        }
        // The model often answers [] while the player plainly holds something, so an empty list
        // changes nothing.
        // What the player has is a ledger: new things are added, and a thing only leaves when the
        // exchange shows it going (given, paid, eaten, put down). A small model's fresh list often
        // just forgets the satchel when a ticket turns up.
        let held = checked(items("carrying", cap: 6).flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 })
        if !held.isEmpty {
            let said = ((start.transcript.last(where: { $0.role == .player })?.text ?? "") + " " + lastReply).lowercased()
            let gone = #"\b(give|gives|gave|given|hand|hands|handed|pay|pays|paid|sell|sold|eat|eats|ate|eaten|drink|drank|finish|finished|drop|dropped|leave|left|put|puts|set|sets|place|places|placed|slide|slides|slid|lose|lost|toss|tossed|swap|swapped|trade|traded)\b"#
            let parting = said.range(of: gone, options: .regularExpression) != nil
            var ledger = held
            for old in start.carrying where !held.contains(where: { Self.similar($0, old) }) {
                let noun = old.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
                if parting, noun.count >= 3, said.contains(noun) { continue }
                ledger.append(old)
            }
            now.carrying = Array(ledger.prefix(8))
        }
        var around = checked(items("things", cap: 8))
        // On the turn the player arrives somewhere, the props must come from this reply: the update
        // tends to list the room they just left ("a single lamp; wet floorboards" in the hotel).
        if now.location.caseInsensitiveCompare(start.location) != .orderedSame {
            let fresh = Continuity.wordSet(lastReply)
            around = around.filter { e in
                if Continuity.grounded(e, in: fresh) { return true }
                refused.append(e)
                return false
            }
        }
        if !around.isEmpty {
            now.things = around
            // Each place keeps its own things: the newest first, the older ones it already had after.
            let key = now.location.lowercased()
            if !key.isEmpty {
                let had = now.placeThings[key] ?? []
                now.placeThings[key] = Array((around + had.filter { o in !around.contains { Self.similar($0, o) } }).prefix(8))
            }
        }
        // The story clock is kept in code: the review may move it on (a little), never back.
        if let t = text("time") {
            if let mm = Continuity.minutes(in: t) {
                if let c = now.clock {
                    var candidate = c - ((c % 1440) + 1440) % 1440 + mm % 1440
                    if candidate < c - 360 { candidate += 1440 }   // past midnight
                    if candidate > c, candidate - c <= 180 { now.clock = candidate }
                } else {
                    now.clock = mm
                }
            }
            now.storyTime = now.clock.map { Continuity.storyTime(clock: $0, old: t) } ?? clip(t, 160)
        }
        // The timeline only grows, in the order things happened: earlier entries stay as they are and
        // new ones are added at the end. "Now" and "just now" become the story time they happened at.
        let when = now.clock.map { Continuity.clockText($0) } ?? now.storyTime.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let added = list("timeline", cap: 20).flatMap { Self.splitTimeline($0) }.filter { $0.contains(":") && !$0.contains("{") && !$0.contains("[") }.map { e -> String in
            guard let r = e.range(of: #"^(just now|right now|now|moments ago|a moment ago)\s*:"#, options: [.regularExpression, .caseInsensitive]),
                  !when.isEmpty else { return e }
            return when + ":" + e[r.upperBound...]
        }
        for e in added.prefix(3) where !now.timeline.contains(where: { Self.sameEvent($0, e) || Self.similar($0, e) }) {
            now.timeline.append(clip(e, 200))
        }
        if now.timeline.count > 12 { now.timeline = Array(now.timeline.prefix(2) + now.timeline.suffix(10)) }
        // Only real people are placed (never the instructions' "each named person").
        let names = now.lore.filter { $0.kind == .person }.flatMap { p in [p.name, p.name.split(separator: " ").first.map(String.init) ?? p.name] }
            + [now.playerName, "you", "You"]
        let whoWhere = Self.whereabouts(m["people"]).filter { w in
            !Self.echoesPrompt(w.at) && names.contains { !$0.isEmpty && $0.caseInsensitiveCompare(w.name) == .orderedSame }
        }
        if !whoWhere.isEmpty {
            // Someone the review forgot stays where they were.
            let before = now.whereabouts
            now.whereabouts = whoWhere.map { w in
                var w = w
                if let old = before.first(where: { $0.name.caseInsensitiveCompare(w.name) == .orderedSame }) { w.here = old.here; w.leftAt = old.leftAt; w.engaged = old.engaged }
                return w
            } + before.filter { o in !whoWhere.contains { $0.name.caseInsensitiveCompare(o.name) == .orderedSame } }
            now.whereabouts = Array(now.whereabouts.filter { !Self.echoesPrompt($0.at) }.prefix(8))
        }
        // Presence has three states. With the player: the people the review names. In the room but
        // in the background: there, visible, but they keep to themselves until the player turns to
        // them. Elsewhere: left behind when the player went somewhere else; never shown.
        // Who is in the room at all is kept in code. A small model cannot be trusted to say
        // it: asked who is "here", it names only whoever the player is talking to. So everyone the
        // story has placed counts as in the room until the player leaves the place without them.
        // That takes two things agreeing: the review's "left" answer, and an exchange that reads
        // like going from one place to another. Then whoever the review names as with the player
        // came along and the rest stay where the player left them. They are back in the scene when
        // the review names them again or the player returns to that place.
        let playerSaid = start.transcript.last(where: { $0.role == .player })?.text ?? ""
        let left = (m["left"] as? Bool) == true && Continuity.leavesPlace(playerSaid + " " + lastReply)
        let named = ((m["here"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased().split(separator: " ").first.map(String.init) }
        let me = now.playerName.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let toldWho = m["here"] is [Any]
        for i in now.whereabouts.indices {
            let first = now.whereabouts[i].name.lowercased().split(separator: " ").first.map(String.init) ?? ""
            // The review's list is really "who the player is dealing with": that is kept too. The
            // others in the room are background, and do not break into the conversation.
            if toldWho { now.whereabouts[i].engaged = named.contains(first) }
            if first == me || first == "you" || named.contains(first) {
                now.whereabouts[i].here = true
                now.whereabouts[i].leftAt = nil
            } else if left {
                if now.whereabouts[i].here != false {
                    now.whereabouts[i].here = false
                    now.whereabouts[i].leftAt = placeBeforeTurn.isEmpty ? start.location : placeBeforeTurn
                } else if let at = now.whereabouts[i].leftAt, !at.isEmpty, placeBeforeTurn.caseInsensitiveCompare(now.location) != .orderedSame,
                          at.caseInsensitiveCompare(now.location) == .orderedSame || Continuity.names(place: at, in: now.location) {
                    now.whereabouts[i].here = true
                    now.whereabouts[i].leftAt = nil
                }
            } else if now.whereabouts[i].here == nil {
                now.whereabouts[i].here = true
            }
        }
        for p in now.cast where now.whereabouts.count < 8 {
            let first = p.name.lowercased().split(separator: " ").first.map(String.init) ?? ""
            if named.contains(first), !now.whereabouts.contains(where: { $0.name.lowercased().hasPrefix(first) }) {
                now.whereabouts.append(Whereabout(name: p.name, at: "with the player", here: true))
            }
        }
        if !refused.isEmpty, let id = start.transcript.last?.id, let i = now.transcript.firstIndex(where: { $0.id == id }) {
            now.transcript[i].after = (now.transcript[i].after ?? "") + "\n\n(Card check in code: not in the story, so kept off the card: "
                + refused.prefix(8).joined(separator: "; ") + ".)"
        }
        now.checks = Self.worldChanges(from: start, to: now, refused: refused, named: namesThisTurn)
        adventure = now
        library.save(now)
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
            target = byRole ?? others.first { (he && !she && uses($0, "he")) || (she && !he && uses($0, "she")) } ?? (others.count == 1 ? others[0] : nil)
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

    /// The review's room to write (and to reason first, with deep thinking on).
    static let reviewTokens = 700
    static let reviewDeepTokens = 1400

    /// The review's prompt; `scale` shrinks the long parts together when it must fit a smaller room.
    private func reviewPrompt(_ start: Adventure, scale: Double) -> String {
        func n(_ chars: Int) -> Int { Int(Double(chars) * scale) }
        var prompt = Prompts.review + "\n\nFEELING TO ACHIEVE: " + (start.setup.feeling.isEmpty ? "what the player came for" : start.setup.feeling)
        prompt += "\n\nSTORY BIBLE:\n" + clip(start.bible, n(1600))
        let limits = limitsText(start)
        if !limits.isEmpty { prompt += "\n\nSET-UP LIMITS:\n" + limits }
        prompt += "\n\nCURRENT FACTS:\n" + (start.facts.isEmpty ? "(none yet)" : start.facts.map { "- " + clip($0, n(160)) }.joined(separator: "\n"))
        if !start.scene.isEmpty { prompt += "\n\nSCENE BEFORE THIS REPLY:\n" + clip(start.scene, n(500)) }
        if !start.storyTime.isEmpty { prompt += "\n\nSTORY TIME BEFORE THIS REPLY: " + start.storyTime }
        if !start.timeline.isEmpty { prompt += "\n\nTIMELINE SO FAR (already recorded; add only what this reply added):\n" + start.timeline.suffix(scale < 0.7 ? 5 : 10).map { "- " + $0 }.joined(separator: "\n") }
        if !start.whereabouts.isEmpty { prompt += "\n\nWHERE PEOPLE WERE BEFORE THIS REPLY:\n" + start.whereabouts.map { "- " + $0.line }.joined(separator: "\n") }
        let people = start.cast.prefix(6).map { "- \($0.name)" + ($0.role.isEmpty ? "" : " (\($0.role))") + ": " + clip($0.desc, n(160)) }
        if !people.isEmpty { prompt += "\n\nPEOPLE:\n" + people.joined(separator: "\n") }
        let unnamed = Continuity.hiddenNames(start)
        if !unnamed.isEmpty {
            prompt += "\n\nTHE STORY CALLS THESE PEOPLE BY THEIR ROLE (use the name in this form): " + unnamed.map { "\"\($0.role)\" is \($0.name)" }.joined(separator: "; ")
        }
        let played = start.elapsed / 60
        if let act = start.roadmap.first(where: { played >= $0.from && played <= $0.to }) ?? start.roadmap.first(where: { played < $0.to }) {
            prompt += "\n\nROADMAP NOW (minute \(Int(played)) of \(start.minutes)): " + act.goal
            if let next = start.roadmap.first(where: { $0.from > act.from }) { prompt += "\nAFTER THAT: " + next.goal }
        }
        if !start.goalProgress.isEmpty { prompt += "\nPROGRESS: " + start.goalProgress }
        prompt += "\n\nRECENT TURNS (the last one is the reply to review):\n" + recentTurns(start, 3, each: n(700))
        return prompt
    }

    /// Asks again, briefly, for the parts a review left out (no reasoning, a small prompt).
    private func repairReview(_ start: Adventure, missing: [String]) async -> [String: Any] {
        let wanted = missing.compactMap { k in Prompts.reviewKeyHelp[k].map { "\"\(k)\": " + $0 } }
        guard !wanted.isEmpty else { return [:] }
        var prompt = "You are the Game Master of an interactive audio story. Your review of the latest reply left some parts out. Output ONLY one JSON object with exactly these keys:\n{" + wanted.joined(separator: ",\n ") + "}\nWrite real content about this story, plain and exact. No commentary."
        prompt += "\n\nSTORY BIBLE:\n" + clip(start.bible, 900)
        if !start.facts.isEmpty { prompt += "\n\nFACTS:\n" + start.facts.prefix(10).map { "- " + clip($0, 140) }.joined(separator: "\n") }
        if !start.scene.isEmpty { prompt += "\n\nSCENE BEFORE THIS REPLY:\n" + clip(start.scene, 400) }
        if !start.whereabouts.isEmpty { prompt += "\n\nWHERE PEOPLE WERE:\n" + start.whereabouts.prefix(6).map { "- " + $0.line }.joined(separator: "\n") }
        let played = start.elapsed / 60
        if let act = start.roadmap.first(where: { played >= $0.from && played <= $0.to }) ?? start.roadmap.first(where: { played < $0.to }) {
            prompt += "\n\nROADMAP NOW: " + act.goal
        }
        prompt += "\n\nRECENT TURNS (the last one is the reply just written):\n" + recentTurns(start, 2, each: 700)
        let reply = (try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: 450, temperature: 0.3))) ?? ""
        return JSONExtract.object(reply) ?? Self.salvageJSON(reply)
    }

    /// How many characters of recalled memories a briefing can carry at most (about 550 tokens).
    static let recallChars = 2000

    /// A cautious token count (about 3.5 bytes a token), for planning a prompt before it is tokenised.
    /// LLMService checks the real count and trims if this ever guesses low.
    static func tokens(_ s: String) -> Int { Int(Double(s.utf8.count) / LLMService.bytesPerToken) + 1 }

    /// Cuts a text to about `n` tokens (by the same cautious count), at a line break where it can.
    static func fitTokens(_ s: String, _ n: Int) -> String {
        guard tokens(s) > n else { return s }
        var out = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = out.isEmpty ? String(line) : out + "\n" + line
            if tokens(next) > n { break }
            out = next
        }
        if out.isEmpty { out = String(s.prefix(max(0, n * 7 / 2 - 2))) }
        return out
    }

    /// Strips things small models sometimes add: headings, "GM:" prefixes, trailing option lists.
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
        let pattern = #"(?i)^(i\s+|we\s+)?(ask|asks|asking|question|wonder|inquire)\b|^(how|what|why|who|whom|whose|where|when|which)\b|\b(tell me|explain)\b|\b(how|what|why|who|where|when|which)\s+(happened|happens|is|are|was|were|did|do|does|can|could|should|will|would|has|have)\b"#
        return t.range(of: pattern, options: .regularExpression) != nil
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

    /// A timeline the model ran together ("Three days ago: ... One hour ago: ...") split into entries.
    static func splitTimeline(_ s: String) -> [String] {
        s.replacingOccurrences(of: #"([.!?])\s+(?=[A-Z][A-Za-z0-9 ,'’-]{1,30}:)"#, with: "$1\n", options: .regularExpression)
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
        if s.count <= 40, !s.contains(". ") { return s.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
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
    private func settleClock(_ a: inout Adventure, reply: String, opening: Bool) {
        if a.clock == nil, let m = Continuity.minutes(in: a.storyTime) { a.clock = m }
        let cues = Continuity.dayParts(in: reply)
        if let lo = cues.min(), let hi = cues.max(), hi - lo <= 1 {
            if let c = a.clock {
                let now = Continuity.part(of: c)
                if opening, !cues.contains(now) {
                    a.clock = Continuity.partStarts[lo]
                } else if !opening, lo > now {
                    a.clock = max(c, c - ((c % 1440) + 1440) % 1440 + Continuity.partStarts[lo])
                }
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
        let planned = plan.split(separator: "\n").filter { l in (grounded ? ["ANSWER"] : ["ANSWER", "BEAT"]).contains { l.uppercased().hasPrefix($0) } }
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
        let s = a.setup
        var sources: [String] = [a.bible, a.scene, s.describe, s.world, s.who, s.traits, s.place, s.goal, s.hook, s.beats]
        sources += a.facts
        sources += a.carrying
        sources += a.lore.map { $0.name + " " + $0.desc }
        sources += a.transcript.map(\.text)
        let known = sources.joined(separator: "\n")
        for thing in Continuity.inventedPossessions(reply, known: known) {
            out.append("The player has no \(thing): nothing in the story gave it to them. Leave it out unless the story hands it over.")
        }
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

    /// Two timeline entries about the same moment (the same words after the "when").
    static func sameEvent(_ a: String, _ b: String) -> Bool {
        func what(_ s: String) -> String { (s.split(separator: ":", maxSplits: 1).last.map(String.init) ?? s).lowercased().trimmingCharacters(in: .whitespaces) }
        return what(a) == what(b) || similar(what(a), what(b))
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

    /// The scene card: the world as it stands right now, kept in code and rendered small. It comes
    /// last in the briefing (right before the player's words, where a small model pays the most
    /// attention): the place, the time, who is in the room, who is elsewhere, what the player has,
    /// what is in the room, when past events happened, and who may use the player's name.
    private func continuityText(_ a: Adventure, tight: Int = 0) -> String {
        var l: [String] = []
        if !a.location.isEmpty || !a.scene.isEmpty {
            l.append("- Place: " + [a.location, clip(a.scene, tight >= 2 ? 200 : 280)].filter { !$0.isEmpty }.joined(separator: ". "))
        }
        if !a.storyTime.isEmpty {
            l.append("- Time: " + a.storyTime + ". " + (a.clock.map { Continuity.skyHint($0) + " " } ?? "") + "It only moves forward, a few minutes in one reply.")
        }
        if !a.whereabouts.isEmpty {
            let me = a.playerName.lowercased().split(separator: " ").first.map(String.init) ?? ""
            let others = a.whereabouts.filter { w in
                let first = w.name.lowercased().split(separator: " ").first.map(String.init) ?? ""
                return first != me && first != "you"
            }
            func pronoun(_ name: String) -> String {
                guard let f = a.facts.first(where: { $0.hasPrefix(name + " uses ") }) else { return "" }
                let rest = f.dropFirst(name.count + 6)
                return rest.hasPrefix("he") ? "he, " : rest.hasPrefix("she") ? "she, " : rest.hasPrefix("they") ? "they, " : ""
            }
            func brief(_ w: Whereabout) -> String {
                w.name + " (" + pronoun(w.name) + clip(w.at + (w.doing.isEmpty ? "" : ", " + w.doing), tight >= 2 ? 90 : 130)
                    + (w.heading.isEmpty ? "" : ", heading to " + clip(w.heading, 60)) + ")"
            }
            let inRoom = others.filter { $0.here == true }, away = others.filter { $0.here == false }, unknown = others.filter { $0.here == nil }
            // With nobody named as with the player, nobody is pushed into the background.
            let someone = inRoom.contains { $0.engaged == true }
            let here = inRoom.filter { !someone || $0.engaged != false }
            let background = inRoom.filter { someone && $0.engaged == false }
            if !background.isEmpty {
                l.append("- In the room, in the background (they keep to their own business and stay quiet unless the player speaks to them): " + background.prefix(4).map(brief).joined(separator: "; "))
            }
            if !here.isEmpty {
                l.append("- With you (only they can speak, act or be seen; nobody changes place or posture unless the reply shows it): " + here.prefix(5).map(brief).joined(separator: "; "))
            } else if !away.isEmpty, unknown.isEmpty {
                l.append("- With you: nobody.")
            }
            if !away.isEmpty {
                l.append("- Elsewhere, out of sight and earshot (leave them out of this reply; no cutting away to them): " + away.prefix(4).map(brief).joined(separator: "; "))
            }
            if !unknown.isEmpty {
                l.append("- People (no one moves or changes posture unless the reply shows it; someone elsewhere cannot speak or be seen): " + unknown.prefix(tight >= 2 ? 4 : 6).map(brief).joined(separator: "; "))
            }
        }
        if !a.carrying.isEmpty { l.append("- You have (nothing else): " + a.carrying.prefix(6).joined(separator: "; ")) }
        // A place the story has described shows its own things; things never follow the player from
        // the last place into the next.
        let around = a.location.isEmpty ? a.things : (a.placeThings[a.location.lowercased()] ?? (a.placeThings.isEmpty ? a.things : []))
        if !around.isEmpty { l.append("- In this place (mention one only when the player looks at it or uses it): " + around.prefix(tight >= 2 ? 6 : 8).joined(separator: "; ")) }
        if !a.timeline.isEmpty {
            l.append("- Earlier (never change these): " + a.timeline.suffix(tight >= 2 ? 3 : 4).map { clip($0, tight >= 2 ? 110 : 140) }.joined(separator: " | "))
        }
        if !a.playerName.isEmpty, !nameTold(a), !a.nameless {
            let knew = a.cast.filter(\.known).map(\.name)
            l.append("- Nobody here knows the player's name (\(a.playerName)) because the player has not said it"
                     + (knew.isEmpty ? "" : ", except " + knew.joined(separator: ", ") + ", who already knew them") + ". No one else says it.")
        }
        return l.isEmpty ? "" : "SCENE CARD (the world right now; the reply must agree with every line)\n" + l.joined(separator: "\n")
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

    private func directorNotes(_ a: Adventure, playerNarrates: Bool, playerAsks: Bool, opening: Bool = false) -> [String] {
        if opening {
            let me = a.lore.first(where: \.isPlayer)?.desc ?? ""
            return [
                "THIS IS THE OPENING SCENE. The listener cannot see anything yet: your words are their eyes. First tell them plainly where they are" + (a.location.isEmpty ? "" : " (\(a.location))") + ", what they are doing and what is around them, then paint it with sound, smell, light and texture.",
                "Say plainly who is with the player right now, and exactly where anyone else is (never \"might be\"). Keep positions simple: whoever speaks to the player is in front of them, facing them. The player has only what the set-up and facts say they have, nothing more.",
                me.isEmpty ? "Make clear who the player is here and why they are in this place." : "Make clear who the player is here (\(clip(me, 200))) and why they are in this place.",
                "FEELING TO ACHIEVE: " + (a.setup.feeling.isEmpty ? "the feeling the player came for" : a.setup.feeling) + ". Set it up from the first lines.",
                "Ignore the usual reply length: the opening may run to about 230 words.",
            ]
        }
        let turn = a.playerTurns + 1
        let feeling = a.setup.feeling.isEmpty ? "the feeling the player came for" : a.setup.feeling
        let final = a.left == 0
        let wrap = (a.left ?? 99) <= 3 && secsLeft(a, live: false) < Double(a.minutes) * 60 * 0.4
        let happy = (a.mood.feeling ?? 0) >= 7 || !a.mood.enjoying.isEmpty
        let roaming = !a.setup.simulator && a.mood.leavingPlot
        let calm = a.setup.simulator || happy || roaming
        var notes: [String] = []
        if playerAsks {
            notes.append("THE PLAYER ASKED A QUESTION. Answer it first, in the opening lines, plainly and concretely: the person they are speaking to tells them, or they see it for themselves. No riddles or vague hints.")
        }
        notes += ["FEELING TO ACHIEVE: \(feeling). Make this reply deliver it."
            + ((a.mood.feeling ?? 10) < 5 ? " Last reading was \(a.mood.feeling ?? 0)/10, so lean into it harder." : "")]
        if happy { notes.append("The player is enjoying this" + (a.mood.enjoying.isEmpty ? "" : " (\(a.mood.enjoying))") + ". No new complications or interruptions; deepen what is working.") }
        if roaming { notes.append("The player is leaving the plot behind. Let it go; make wherever they are worth being in.") }

        let played = a.elapsed / 60
        let phase = calm ? "savour" : played / Double(max(1, a.minutes)) < 0.5 ? "rising" : played / Double(max(1, a.minutes)) < 0.85 ? "peak" : "release"
        if !(happy && phase == "savour") { notes.append("PACING: " + [
            "rising": "momentum is building; keep things moving and curious.",
            "peak": "a high-intensity beat; force a decisive moment.",
            "release": "aftermath and breathing room; let consequences land.",
            "savour": "stay in the moment and let it breathe; just more of what the player came for.",
        ][phase]!) }

        if playerNarrates {
            notes.append("THE PLAYER IS NARRATING: their passage is canon. Do not retell it; continue where it ends, in their voice. Keep it short.")
        } else if !final {
            var pool = Prompts.director.keys.filter { k in
                !((calm || wrap || playerAsks) && Prompts.disruptive.contains(k)) && !((playerAsks || a.setup.simulator || wrap) && k == "seed")
                    && turn - (a.lastDirector[k] ?? -99) >= 3
            }
            pool.shuffle()
            if let k = pool.first {
                notes.append(Prompts.director[k]!)
                adventure?.lastDirector[k] = turn
            }
        }

        // An experience has no arc (one saved with an arc ignores it); a story steers by its roadmap.
        if !a.setup.simulator, !a.roadmap.isEmpty {
            let act = a.roadmap.first { played >= $0.from && played <= $0.to } ?? a.roadmap.first { played < $0.to } ?? a.roadmap.last!
            notes.append(calm
                ? "SECRET ROADMAP (on hold while the player is happy where they are; offer it again only if they reach for it): " + act.goal
                : "SECRET ROADMAP (minute \(Int(played)) of \(a.minutes)): steer gently toward this without revealing it: " + act.goal)
        }
        if let left = a.left {
            notes.append("TIME: minute \(Int(played)) of \(a.minutes), roughly \(left) more player replies after this one.")
        }
        if final {
            notes.append("THIS IS THE FINAL REPLY. Bring it to a definitive storybook ending that lands the feeling (\(feeling)), paying off what the player actually cared about. Do not ask what they do next; end on a closing image, in the place the player is now and with whoever is with them there.")
            notes.append("The ending uses only the people, places and things already in the story: no new objects, tickets or places, and the same city and region as the facts. Second person to the last line: \"you\", never \"they\" or the player's name.")
        } else if a.left == 1 {
            notes.append("One reply left after this: start bringing it home.")
        } else if wrap {
            notes.append("WRAP-UP: the session is nearly over. Steer toward a payoff and an ending. No new threads.")
        }
        if !final && !playerNarrates {
            // A calm scene is not broken into by a new arrival.
            notes.append(Prompts.endings.filter { !((calm || wrap) && $0 == Prompts.interruptingEnding) }.randomElement()!)
        }
        // The showrunner's agendas, acted out: someone pursues what they want, on screen.
        if !a.isShort, !calm, !wrap, !playerNarrates, !playerAsks, let cast = a.notes?.cast, let c = cast.randomElement(), Double.random(in: 0..<1) < 0.6 {
            notes.append("Motive in action: \(c.name) wants \(c.wants)" + (c.fears.isEmpty ? "" : " and fears \(c.fears)")
                + ". Show them pursuing it visibly in this reply (a choice, a lie, a favour, a closed door), even where it cuts against what the player wants.")
        }
        let repeats = repeatedPhrases(a)
        if !repeats.isEmpty { notes.append("Avoid repeating these phrases from recent replies: " + repeats.joined(separator: ", ")) }
        // Last, right before the player's words: small models follow what they read most recently.
        if playerAsks { notes.append("Now reply to the player below, starting with a clear answer to their question.") }
        return notes
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
        guard let start = adventure else { return }
        let known = start.lore.filter { !$0.isPlayer }.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", ")
        let steps = start.beats.filter { !$0.done }.map(\.text).joined(separator: "; ")
        let prompt = Prompts.memory + "\n\nFEELING TO ACHIEVE: " + start.setup.feeling
            + "\nTHE PLAYER: " + (start.playerName.isEmpty ? "you" : start.playerName)
            + "\nALREADY KNOWN: " + (known.isEmpty ? "(none)" : known)
            + "\nOPEN STORY STEPS: " + (steps.isEmpty ? "(none)" : steps)
            + "\n\nLATEST EXCHANGE\n" + exchange
        // The grounded engine files each reply itself (`rebuild`). Here only the housekeeping
        // remains for it: names the story has revealed, and folding old turns into chapters.
        var m: [String: Any] = [:]
        if !grounded {
            guard let reply = try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: 350, temperature: 0.3, repetitionPenalty: 1.12,
                                                                                             grammar: JSONGrammar.memory)),
                  let parsed = JSONExtract.object(reply) else { return }
            m = parsed
        }
        guard var a = adventure, a.id == start.id else { return }

        a.events.append(contentsOf: ((m["events"] as? [String]) ?? []).prefix(2))
        a.events = Array(a.events.suffix(30))
        if let raw = (m["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let loc = Self.placeName(raw, known: a.lore.filter { $0.kind == .place }.map(\.name) + a.places)
            // The player is somewhere new only if the exchange itself names that place: a small
            // model otherwise picks any place it knows of (the "Back Alley" nobody walked into).
            if a.location.isEmpty || loc.caseInsensitiveCompare(a.location) == .orderedSame || Continuity.names(place: loc, in: exchange) {
                Self.enrichPlace(&a, loc, with: raw)
                a.visit(loc, from: a.location)
                a.location = loc
            }
        }
        if let gp = m["goal_progress"] as? String, !gp.isEmpty { a.goalProgress = gp }
        let turn = a.playerTurns
        for p in ((m["lore"] as? [[String: Any]]) ?? []) + ((m["people"] as? [[String: Any]]) ?? []) {
            guard let name = (p["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  name.caseInsensitiveCompare(a.playerName) != .orderedSame, a.lore.count < 40 else { continue }
            let kind = (p["type"] as? String).map(LoreEntry.kind(from:)) ?? .person
            let i = addLore(&a, LoreEntry(name: name, kind: kind, desc: p["desc"] as? String ?? "", role: p["role"] as? String ?? "",
                                          known: kind != .person || exchange.contains(name)), lately: true)
            a.lore[i].updatedTurn = turn
        }
        // A person's name counts as revealed once the story has said it.
        let told = exchange.components(separatedBy: "THE STORY:").last ?? ""
        for i in a.lore.indices where a.lore[i].kind == .person && !a.lore[i].known {
            let first = a.lore[i].name.split(separator: " ").first.map(String.init) ?? a.lore[i].name
            if told.contains(a.lore[i].name) || (first.count > 2 && told.contains(first)) { a.lore[i].known = true }
        }
        for done in (m["beats_done"] as? [String]) ?? [] {
            if let i = a.beats.firstIndex(where: { !$0.done && ($0.text.localizedCaseInsensitiveContains(done) || done.localizedCaseInsensitiveContains($0.text)) }) {
                a.beats[i].done = true
            }
        }
        if let mood = m["mood"] as? [String: Any] {
            a.mood = Mood(
                feeling: (mood["feeling"] as? NSNumber)?.intValue,
                enjoying: mood["enjoying"] as? String ?? "",
                leavingPlot: mood["leaving_plot"] as? Bool ?? false)
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

    /// Runs after the memory pass. At most one extra model call per turn, and only every few
    /// turns: the first showrunner notes after turn 2, then a bible rewrite at turns 10, 20, ...
    /// and revised notes at turns 12, 22, ... (sooner after a hand edit). Each prompt is kept
    /// well inside the context the fit check planned for, and the call waits its turn for the
    /// GPU like everything else, so memory never goes above a normal turn's.
    private func housekeep() async {
        guard !Task.isCancelled, let start = adventure, !start.ended, (start.left ?? 99) > 1 else { return }
        let turn = start.playerTurns
        let bibleDue = turn >= 10 && turn - start.bibleTurn >= 10
        // A first attempt that came back unusable is tried again four turns later, not every turn.
        let notesDue = start.notes == nil
            ? turn >= 2 && (start.notesTurn == 0 || turn - start.notesTurn >= 4)
            : start.notesStale || turn - start.notesTurn >= 10
        guard bibleDue || notesDue else { return }
        housekeepingRunning = true
        defer { housekeepingRunning = false }
        if bibleDue { await refreshBible(start, turn: turn) } else { await makeNotes(start, turn: turn) }
    }

    private func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }

    /// What the player set by hand, for background calls: it beats the transcript.
    private func playerFacts(_ a: Adventure) -> String {
        let pinned = a.lore.filter(\.byPlayer).suffix(12)
        guard !pinned.isEmpty else { return "" }
        return "PLAYER-SET FACTS (keep them exactly, even where the transcript says otherwise):\n"
            + pinned.map { "- \($0.name) (\($0.label.lowercased())): " + clip($0.desc, 240) }.joined(separator: "\n") + "\n\n"
    }

    private func recentTurns(_ a: Adventure, _ n: Int, each: Int) -> String {
        a.transcript.suffix(n).map { ($0.role == .player ? "PLAYER: " : "STORY: ") + clip($0.text, each) }.joined(separator: "\n")
    }

    private func refreshBible(_ start: Adventure, turn: Int) async {
        let hidden = hiddenPeople(start)
        var prompt = Prompts.bibleRefresh + "\n\nCURRENT BIBLE:\n" + clip(start.bible, 2400) + "\n\n" + playerFacts(start)
        if !hidden.isEmpty {
            prompt += "NAMES THE PLAYER HAS NOT LEARNED (write the role, never the name): " + hidden.map { "\($0.name) = \"\($0.role)\"" }.joined(separator: "; ") + "\n\n"
        }
        if !start.mapText.isEmpty { prompt += "MISSION MAP: " + start.mapText + "\n\n" }
        if !start.chapters.isEmpty { prompt += "STORY SO FAR:\n" + start.chapters.suffix(3).map { "- " + clip($0, 400) }.joined(separator: "\n") + "\n\n" }
        prompt += "RECENT TURNS:\n" + recentTurns(start, 8, each: 600)
        let reply = try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: 420, temperature: 0.4))
        guard !Task.isCancelled, var now = adventure, now.id == start.id else { return }
        let bible = Self.tidy(reply ?? "")
        // Skip it if you edited the bible while this ran, or the model gave back something too short to be a bible.
        if bible.split(separator: " ").count >= 60, now.bible == start.bible { now.bible = bible }
        now.bibleTurn = turn
        adventure = now
        library.save(now)
    }

    private func makeNotes(_ start: Adventure, turn: Int) async {
        let revise = start.notes != nil
        var prompt = Prompts.showrunner
        if revise { prompt += "\n" + Prompts.showrunnerRevise }
        if start.setup.simulator { prompt += "\n" + Prompts.showrunnerSimulator }
        if start.isShort { prompt += "\nThis is a SHORT story: keep the notes small and simple (2-3 secrets, 1-2 threads)." }
        prompt += "\nThe cast has at most \(start.minutes >= 30 ? 3 : 2) named characters besides the player, plus one antagonist; do not add new named people."
        prompt += "\nEverything should serve the FEELING TO ACHIEVE: " + (start.setup.feeling.isEmpty ? "what the player came for" : start.setup.feeling) + "."
        if let notes = start.notes {
            prompt += "\n\nCURRENT NOTES:\n" + notes.text
        } else if !start.secrets.isEmpty {
            prompt += "\n\nSECRETS PLANNED AT THE START (keep the ones still hidden):\n" + start.secrets.map { "- " + clip($0, 300) }.joined(separator: "\n")
        }
        prompt += "\n\nBIBLE:\n" + clip(start.bible, 2000) + "\n\n" + playerFacts(start)
        let lore = start.lore.filter { !$0.isPlayer }.sorted { ($0.updatedTurn ?? 0) > ($1.updatedTurn ?? 0) }.prefix(16)
        if !lore.isEmpty { prompt += "LORE:\n" + lore.map { "- \($0.name) (\($0.kind.rawValue)): " + clip($0.desc, 160) }.joined(separator: "\n") + "\n\n" }
        if !start.mapText.isEmpty { prompt += "MISSION MAP: " + start.mapText + "\n\n" }
        prompt += "RECENT TURNS:\n" + recentTurns(start, 6, each: 500)

        let reply = try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: 450, temperature: 0.7))
        guard !Task.isCancelled, var now = adventure, now.id == start.id else { return }
        if let g = reply.flatMap(JSONExtract.object) {
            func str(_ d: [String: Any], _ k: String) -> String { (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            var notes = ShowrunnerNotes()
            notes.voice = str(g, "voice")
            notes.secrets = ((g["secrets"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            notes.threads = ((g["threads"] as? [Any]) ?? []).compactMap { t in
                if let s = t as? String { return ShowrunnerNotes.StoryThread(thread: s) }
                guard let d = t as? [String: Any], !str(d, "thread").isEmpty else { return nil }
                return ShowrunnerNotes.StoryThread(thread: str(d, "thread"), status: str(d, "status").isEmpty ? "seeded" : str(d, "status"))
            }
            notes.bigReveal = str(g, "big_reveal")
            // Only the story's own named people get agendas, so the notes never invent a new cast.
            let names = start.cast.map { $0.name.lowercased() }
            notes.cast = ((g["cast"] as? [[String: Any]]) ?? []).compactMap { c in
                let name = str(c, "name")
                guard !name.isEmpty, name.caseInsensitiveCompare(start.playerName) != .orderedSame else { return nil }
                let first = name.lowercased().split(separator: " ").first.map(String.init) ?? ""
                guard names.isEmpty || names.contains(where: { $0 == name.lowercased() || $0.hasPrefix(first + " ") || $0 == first }) else { return nil }
                return ShowrunnerNotes.Agenda(name: name, wants: str(c, "wants"), fears: str(c, "fears"), secret: str(c, "secret"), nextMove: str(c, "next_move"))
            }
            if !notes.voice.isEmpty || !notes.secrets.isEmpty { now.notes = notes }
        }
        now.notesStale = false
        now.notesTurn = turn
        adventure = now
        library.save(now)
    }

    private func refreshVocabulary() {
        guard let a = adventure else { return }
        dictation.vocabulary = a.cast.flatMap { $0.name.split(separator: " ").map(String.init) } + [a.location, a.playerName].filter { !$0.isEmpty }
    }
}
