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
    var error: String?

    /// Names learned this turn, for the world check.
    private var namesThisTurn: [String] = []
    /// What the player put down or gave away this turn: the rebuild doesn't put it back in their hands.
    private var putDownThisTurn: [String] = []

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
        forge?.abort()
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
            adventure = a
            undoSnapshot = nil
            refreshVocabulary()
            library.save(a)
            // The first room is drawn now, on the build screen, before the opening is written;
            // it is never redrawn after.
            forge.reach(Forge.roomStage)
            var scene = "THE STORY: " + clip(a.bible, 700)
            let held = Cards.props(a)
            if !held.isEmpty { scene += "\nTHINGS HERE: " + held.prefix(8).joined(separator: "; ") }
            let people = a.whereabouts.filter { $0.here != false }.map { w in w.name + (w.at.isEmpty ? "" : " (" + w.at + ")") }
            if !people.isEmpty { scene += "\nPEOPLE HERE: " + people.joined(separator: "; ") }
            await furnishRoom(story: scene)
            guard !Task.isCancelled else { return }
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
    func storyText(prompts: Bool = false) -> String {
        guard let a = adventure else { return "" }
        var out = ["# " + a.title, ""]
        if !a.setup.feeling.isEmpty { out.append("Feeling: " + a.setup.feeling) }
        if !a.setup.goal.isEmpty { out.append("Goal: " + a.setup.goal) }
        out.append("Foveated story (read, yes/no pass, paint, lean rebuild) · " + Self.build)
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
        out += ["", "## The story", ""]
        let me = a.playerName.isEmpty ? "YOU" : a.playerName.uppercased()
        for t in a.transcript {
            if let b = t.before, !b.isEmpty { out += [b, ""] }
            out.append((t.role == .player ? me : "GAME MASTER") + ":\n" + t.text)
            out.append("")
            if let b = t.after, !b.isEmpty { out += [b, ""] }
            if prompts, let p = t.prompt, !p.isEmpty { out += ["PROMPT SENT FOR THIS REPLY:", "<<<", p, ">>>", ""] }
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

    /// Kept free in every prompt, because token counts here are estimates.
    static let safetyTokens = 96
    /// The most the rules, bible and briefing can be squeezed (see `systemPrompt` and `briefingText`).
    static let tightest = 3
    /// Shown in the story export, so a playthrough can be matched to the code that ran it.
    static let build = "build 2026-11-13z12"

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
        var going = ""       // "" for staying, a known place, or "somewhere new"
        var newPlace = ""    // going somewhere new: its name, from the message
        var takes = ""       // what the player picks up or takes, in the read's words
        var putsDown = ""    // what the player puts down or gives away
        var spot = ""        // where in the place the player moves to
        var tells = ""       // what the player tells about themselves ("your name is Simon")
        var body = ""        // a change to the player's body ("sitting", "coat off")
        var feels = ""       // how the player says they feel
        var goalStep = ""    // what the player's own message does toward the goal
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
        let goal: String = a.setup.goal.isEmpty ? "" : "\nWHAT THE PLAYER CAME FOR: " + clip(a.setup.goal, 200)
        let prompt = context + goal + "\n\n" + Prompts.lookQuestion + "\nThe form:"
        let grammar = JSONGrammar.look(cast: cast, places: places, cards: menu, people: cast)
        let reply = (try? await llm.complete(system: nil, prompt: prompt,
                                             options: .init(maxTokens: 300, temperature: 0.2, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
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
        let takes = s("takes")
        func field(_ k: String) -> String {
            let v = s(k)
            return v.count > 2 && !Self.echoesPrompt(v) && !["nothing", "none", "empty", "n/a", "no change", "staying"].contains(v.lowercased()) ? v : ""
        }
        read.takes = field("takes")
        read.putsDown = field("puts_down")
        read.spot = field("spot")
        read.tells = field("tells")
        read.body = field("body")
        read.feels = field("feels")
        read.goalStep = field("goal_step")
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
        let reply = (try? await llm.complete(system: nil, prompt: prompt,
                                             options: .init(maxTokens: 200, temperature: 0.2, repetitionPenalty: 1.1, grammar: JSONGrammar.plan(asked: asked)))) ?? ""
        let m = JSONExtract.object(reply) ?? Self.salvageJSON(reply)
        func s(_ k: String) -> String { (m[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        read.answer = Self.echoesPrompt(s("answer")) || Self.outOfTime(s("answer"), a) ? "" : clip(s("answer"), 260)
        // The plan left a question unanswered (a model that ignores grammars, or an answer too
        // vague to use): one short question asks for the answer alone.
        if asked, read.answer.count < 6 || Self.vagueAnswer(read.answer) {
            let q: String = prompt.components(separatedBy: Prompts.planQuestion).first ?? context
            let ask: String = q + "\n\nQUESTION: The player asked: \"" + clip(input, 300) + "\". What plain, concrete answer does the person they asked give, in one short sentence? Never vague, never a riddle, never the player's own words. {\"answer\":\"one short sentence\"}\nThe form:"
            let raw = (try? await llm.complete(system: nil, prompt: ask,
                                               options: .init(maxTokens: 80, temperature: 0.2, repetitionPenalty: 1.1, grammar: JSONGrammar.text("answer", chars: 200)))) ?? ""
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
        if read.going.isEmpty || (read.going == "somewhere new" && read.newPlace.isEmpty), !a.location.isEmpty,
           let noun = Self.newPlaceWord(input, in: a) {
            read.going = "somewhere new"
            read.newPlace = "The " + noun
        }
        let me = a.playerName.lowercased().split(separator: " ").first.map(String.init) ?? ""
        // "Her" or "him" with no name: when only one person here fits, that is who is meant.
        let namesSomeone = a.cast.contains { c in
            let f = Cards.first(c.name).lowercased()
            return said.contains(f) || Continuity.wordSet(c.role).contains(where: { $0.count > 3 && said.contains($0) })
        }
        if !namesSomeone {
            for (words, tag) in [(["her", "she"], " uses she/her"), (["him", "he"], " uses he/him")] where words.contains(where: { said.contains($0) }) {
                let fits = a.whereabouts.filter { w in
                    w.here != false && a.facts.contains { $0.hasPrefix(w.name + tag) }
                }
                if fits.count == 1, read.to.caseInsensitiveCompare(fits[0].name) != .orderedSame { read.to = fits[0].name }
                break
            }
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
        if hidden, a.transcript.isEmpty, let card = Cards.placeCard(a), card.desc.count < 120, !card.byPlayer {
            stage = "Building " + a.location
            if let i = a.lore.firstIndex(where: { $0.id == card.id }) { a.lore[i].desc = "" }
            let hint: String = [card.desc, a.scene].filter { !$0.isEmpty }.joined(separator: " ")
            let built = await buildPlace(&a, hint: hint)
            guard !Task.isCancelled else { return }
            if built.isEmpty, let i = a.lore.firstIndex(where: { $0.id == card.id }) { a.lore[i].desc = card.desc }
            if !built.isEmpty { catchUpNotes.append("Built: " + built) }
            lap("building the opening place")
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
        let maxOut = opening ? 520 : 300
        let playerNarrates = !hidden && Self.narrates(input)
        let playerAsks = !hidden && !playerNarrates && Self.asks(input)
        // Foveated: no lookups and no plan; one yes/no pass over the cards picks what the reply sees.
        let fov = !hidden && !playerNarrates
        foveaUsed = fov
        foveaYes = []
        var foveaTold = ""
        namesThisTurn = []
        putDownThisTurn = []
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
            if !r.spot.isEmpty, Continuity.grounded(r.spot, in: said, share: 0.5), a.spot.caseInsensitiveCompare(r.spot) != .orderedSame {
                a.spot = clip(r.spot, 90)
                actsNow.append("You are now → " + r.spot)
            }
            if !r.tells.isEmpty, Continuity.grounded(r.tells, in: said, share: 0.6) {
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
            if !r.body.isEmpty, Continuity.grounded(r.body, in: said, share: 0.5), a.body.caseInsensitiveCompare(r.body) != .orderedSame {
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
            pre.append(line)
            Self.updateFrame(&a, looked: [], asked: [], notes: catchUpNotes, steps: [], pre: pre)
            adventure?.frames = a.frames
        }
        if let pickedNow { step("You pick up → " + pickedNow + " (in your hands now)") }
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
            settle(&a, read: read ?? PlayerRead(), input: input)
            if read == nil { lastRead = "no usable reading; " + lastRead }
            let facingNow: [String] = a.whereabouts.filter { $0.here != false && $0.engaged == true }.map(\.name)
            step("Who are you talking to? → " + (facingNow.isEmpty ? "nobody in particular" : facingNow.joined(separator: ", ")))
            let movedNow = a.location.caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
            step("Are you going anywhere? → " + (movedNow ? (a.location.isEmpty ? "somewhere new" : a.location) : "staying"))
            // Arriving somewhere with no description yet: the place is built before the reply, so
            // the reply can bring it to life.
            let arrived = !a.location.isEmpty && a.location.caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
            if arrived, let card = Cards.placeCard(a), card.desc.isEmpty, !card.byPlayer {
                stage = "Building " + a.location
                lapFrom = Date()
                let built = await buildPlace(&a)
                guard !Task.isCancelled else { adventure = snapshot; return }
                lap("building " + a.location)
                if !built.isEmpty {
                    catchUpNotes.append("Built: " + built)
                    lastRead += "; built " + a.location
                    step("What is this place like? → " + built)
                }
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
        if !hidden, !fov {
            let asked = read?.looks ?? []
            let looks = asked + Looks.auto(a, input: input, to: read?.to ?? "", asked: asked)
            stage = looks.isEmpty ? "Gathering the world" : "Looking things up"
            lapFrom = Date()
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
                step(l.text.prefix(1).uppercased() + String(l.text.dropFirst()) + "? → " + clip(ans.text.isEmpty ? "nothing" : ans.text, 160))
            }
            if !looks.isEmpty { lap("lookups") }
        }
        // Is the player bringing someone new in? Asked only when the message reads like an arrival
        // or a meeting; the newcomer gets a card before the reply, so nobody else is swapped in.
        let arrival = #"(?i)\b(in walks?|walks? in|comes? (in|over|up|through)|enters?|arrives?|shows? up|appears?|meet (him|her|them|your|his|the)|introduces? (me|us)|joins? us)\b"#
        if !hidden, !playerNarrates, input.range(of: arrival, options: .regularExpression) != nil {
            stage = "Is someone new coming in?"
            lapFrom = Date()
            let raw = (try? await llm.complete(system: nil, prompt: context + "\n\n" + Prompts.newcomer + "\nThe form:",
                                               options: .init(maxTokens: 70, temperature: 0.2, repetitionPenalty: 1.1,
                                                              grammar: JSONGrammar.yesNo("new", then: "name", 30, and: "role", 60)))) ?? ""
            guard !Task.isCancelled else { adventure = snapshot; return }
            lap("someone new")
            let m = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
            var came: String? = nil
            let recent: String = a.transcript.suffix(6).map(\.text).joined(separator: " ")
            if (m["new"] as? String) == "yes" {
                came = addNewcomer(&a, name: (m["name"] as? String) ?? "", role: (m["role"] as? String) ?? "", about: input + " " + recent, engaged: true)
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
            let raw = (try? await llm.complete(system: nil, prompt: q,
                                               options: .init(maxTokens: 50, temperature: 0.2, repetitionPenalty: 1.1, grammar: JSONGrammar.yesNo("can", then: "missing", chars: 60)))) ?? ""
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
            var keep: [Bool] = []
            if !items.isEmpty {
                var intent = Fovea.PlayerIntent()
                if let r = read {
                    intent.to = r.to; intent.going = r.going; intent.newPlace = r.newPlace
                    intent.takes = r.takes; intent.putsDown = r.putsDown; intent.tells = r.tells
                }
                let ask: String = Fovea.gatePrompt(a, input: input, intent: Fovea.intent(intent), lastReply: lastGMBefore, items: items)
                let raw = (try? await llm.complete(system: nil, prompt: ask,
                                                   options: .init(maxTokens: 12 + items.count * 9, temperature: 0.1, repetitionPenalty: 1.0,
                                                                  grammar: JSONGrammar.gate(count: items.count)))) ?? ""
                guard !Task.isCancelled else { adventure = snapshot; return }
                let m: [String: Any] = JSONExtract.object(raw) ?? Self.salvageJSON(raw)
                keep = Fovea.chosen(items, answer: m, input: input)
                gateLog = ask + " " + raw
                lap("what matters")
            }
            var kept: [Fovea.Item] = []
            for (i, item) in items.enumerated() where i < keep.count && keep[i] { kept.append(item) }
            foveaYes = Set(kept.map(\.kind))
            foveaView = []
            for (i, item) in items.enumerated() {
                let mark: String = i < keep.count && keep[i] ? "  + " : "  - "
                foveaView.append(mark + Fovea.clip(item.text, 90))
            }
            // The notes that only apply now (the final reply, the player moving, phrases that keep
            // coming back) still go with the moment.
            var events: [String] = extra + notes
            if !foveaTold.isEmpty { events.insert(foveaTold + " Say it in this reply.", at: 0) }
            system = Fovea.system(a, nameless: a.nameless, playerNamed: !a.nameless || nameTold(a), age: PlayerDetails.saved.age)
            lead = Fovea.lead(a, input: input, arrived: arrivedNow, events: events, kept: kept)
            roomSent = lead.components(separatedBy: "\n").filter { $0.hasPrefix("THE ROOM: ") || $0.hasPrefix("- ") && $0.contains(" Now: ") }
            let shown: String = kept.isEmpty ? "only the room and who you face" : kept.map { Fovea.clip($0.text, 50) }.joined(separator: "; ")
            step("What matters right now? → " + shown + " (\(items.count - kept.count) of \(items.count) left out)")
            lastRead += "; foveated: \(kept.count) of \(items.count) card items in"
        }
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
                    var second = PresenceFilter(absent: presence!.absent, earlier: a.transcript.filter { $0.role == .gm }.suffix(3).map(\.text), player: input)
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
        if fov {
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
        a.transcript.append(StoryTurn(role: .gm, text: reply, before: before.joined(separator: "\n"), prompt: sentPrompt))
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
            return lines + [
                "THIS IS THE OPENING SCENE, and it may run to about 200 words. The listener cannot see anything yet: first tell them plainly where they are" + (a.location.isEmpty ? "" : " (\(a.location))") + ", what they are doing and who is there, then spend most of it painting the place itself: what you see in front of you, then sound, smell, light and texture.",
                "Show the people only from the outside: how they look, what their hands are doing, how they sound. Say nothing of their hopes, dreams, worries, plans or past, and give no hints of them; those come out only when the player asks.",
                me.isEmpty ? "Make clear who the player is and why they are here." : "Make clear who the player is (\(clip(me, 160))) and why they are here.",
                "Set up the feeling (" + (a.setup.feeling.isEmpty ? "the one the player came for" : a.setup.feeling) + ") from the first lines.",
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
        let wanted = foveaYes

        func roleOf(_ c: LoreEntry) -> String { c.role.isEmpty ? "" : " (the story may call them \"" + Continuity.roleLabel(c.role) + "\")" }
        var base = Prompts.rebuildIntro
        base += "\n\nPLACE BEFORE: " + (start.location.isEmpty ? "(not named yet: the player just went somewhere new)" : start.location)
        let peopleLines: [String] = start.cast.map { $0.name + roleOf($0) }
        base += "\nPEOPLE IN THE STORY: " + (peopleLines.isEmpty ? "(none)" : peopleLines.joined(separator: "; "))
        if !playerSaid.isEmpty { base += "\n\nTHE PLAYER: " + clip(playerSaid, 500) }
        base += "\n\nTHE STORY: " + clip(reply, 1400) + "\n\nQUESTION: "

        func ask(_ label: String, _ question: String, _ grammar: String, _ tokens: Int) async -> [String: Any]? {
            guard !Task.isCancelled else { return nil }
            if lean, foveaSkip(label, wanted: wanted, start: start, playerSaid: playerSaid) {
                times.append(label + " skipped (out of view)")
                return [:]
            }
            rebuildStep = label
            let t0 = Date()
            let raw = (try? await llm.complete(system: nil, prompt: base + question,
                                               options: .init(maxTokens: tokens, temperature: 0.2, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
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
            // On the way somewhere unnamed, a place already on the map counts only when the
            // exchange names it; otherwise the small model is reaching for the last name it knows.
            let knownLoc = (now.lore.filter { $0.kind == .place }.map(\.name) + now.places).contains { $0.caseInsensitiveCompare(loc) == .orderedSame }
            if now.location.isEmpty, !missed, knownLoc, !now.transcript.isEmpty,
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

        // A room the story has just entered is laid out now, while the reply is read aloud.
        await furnishRoom(story: (playerSaid.isEmpty ? "" : "THE PLAYER: " + clip(playerSaid, 300) + "\n") + "THE STORY: " + clip(reply, 900))
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

        // Anyone new? Someone the story shows or names who has no card yet gets one.
        var knownWords: Set<String> = Continuity.wordSet(start.playerName + " " + start.lore.map(\.name).joined(separator: " "))
        knownWords.formUnion(["mr", "mrs", "miss", "the", "los", "angeles", "god", "broadway", "hollywood", "paris", "london", "new", "york"])
        var strangerHint = reply.range(of: #"\b(Mr|Mrs|Ms|Miss|Dr)\.? [A-Z]"#, options: .regularExpression) != nil
            || reply.range(of: Self.someoneNew, options: .regularExpression) != nil
            || playerSaid.range(of: Self.someoneNew, options: .regularExpression) != nil
        if !strangerHint {
            for sentence in PresenceFilter.sentences(reply) {
                let words = sentence.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
                for w in words.dropFirst() where w.count > 2 && w.first?.isUppercase == true && !knownWords.contains(w.lowercased()) {
                    strangerHint = true
                }
            }
        }
        if strangerHint {
            let nm = await ask("Is anyone new here?", Prompts.rebuildNewPerson, JSONGrammar.yesNo("new", then: "name", 30, and: "role", 60), 70)
            guard nm != nil else { return }
            let isNew = ((nm?["new"] as? String) ?? "") == "yes"
            let nameSaid: String = (nm?["name"] as? String) ?? ""
            let roleSaid: String = (nm?["role"] as? String) ?? ""
            asked.append("Is anyone new here? → " + (isNew && nameSaid.count > 2 ? nameSaid : "no"))
            // A new person has to be there in the telling itself: not only named in someone's
            // speech, and not a name the player brought up (their own alias, a brother back home).
            let plainName: String = nameSaid.lowercased().replacingOccurrences(of: #"^(the|a|an) "#, with: "", options: .regularExpression)
            let telling: String = PresenceFilter.sentences(reply).filter { !$0.contains("\"") && !$0.contains("“") }.joined(separator: " ").lowercased()
            let playerWords: Set<String> = Continuity.wordSet(start.transcript.filter { $0.role == .player }.map(\.text).joined(separator: " "))
            let nameWords: [String] = plainName.split(separator: " ").map(String.init).filter { $0.count > 2 }
            let fromPlayer = !nameWords.isEmpty && nameWords.allSatisfy { playerWords.contains($0) }
            let present = plainName.count > 2 && telling.contains(plainName) && !fromPlayer
            commit { now in
                guard isNew else { return }
                if present, let added = addNewcomer(&now, name: nameSaid, role: roleSaid, about: reply, engaged: false) {
                    filed.append("New person card: " + added + (roleSaid.isEmpty ? "" : " (" + roleSaid + ")"))
                } else {
                    refused.append(nameSaid + " (not a new person the story shows)")
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
            inView.append(c)
        }
        // Each of them on the grid: what they are doing, their expression, what they hold, where
        // they are and what they face. One question each, only for people the moment shows (the
        // rest were out of view, so nothing the player saw could have changed them).
        let gridNow: Room? = mid.room
        let personZones: [String] = gridNow.map { Zone.menu($0, people: true) } ?? []
        var faceList: [String] = ["you", "the door"]
        if let g = gridNow {
            if !g.windows.isEmpty { faceList.append("the window") }
            faceList += g.people.filter { $0.kind == .person }.map(\.name)
            faceList += Array(g.objects.filter { !Rules.rule($0.icon).small && $0.icon != "rug" }.map(\.name).prefix(6))
        }
        for c in inView.prefix(3) {
            let q = "THE PLACES: " + (["stays put"] + personZones).joined(separator: "; ") + "\nTHE FACES: " + faceList.joined(separator: "; ")
                + "\n\nAbout " + c.name + roleOf(c) + " at the end of the moment, only as the story shows it. Output ONLY one JSON object:\n{\"doing\":\"what they are doing, a few words\",\"expression\":\"their expression, a few words\",\"holding\":\"what they hold, or nothing\",\"where\":\"one of THE PLACES; stays put if they didn't move\",\"facing\":\"one of THE FACES\"}\nThe form:"
            let dm = await ask(c.name + " now?", q, JSONGrammar.personNow(zones: personZones, faces: faceList), 110)
            guard let dm else { return }
            func field(_ k: String) -> String {
                let v = ((dm[k] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
                return v.count > 2 && !Self.echoesPrompt(v) && !["nothing", "none", "n/a"].contains(v.lowercased()) ? v : ""
            }
            let doing = field("doing")
            let face = field("expression")
            let holds = field("holding")
            let whereSaid = field("where")
            let facingSaid = field("facing")
            asked.append(c.name + " now? → " + [doing, face, whereSaid == "stays put" ? "" : whereSaid, facingSaid.isEmpty ? "" : "facing " + facingSaid]
                .filter { !$0.isEmpty }.joined(separator: "; "))
            commit { now in
                if !doing.isEmpty, let i = now.whereabouts.firstIndex(where: { Cards.card(for: $0, in: now)?.id == c.id }), now.whereabouts[i].here != false {
                    if now.whereabouts[i].doing.caseInsensitiveCompare(doing) != .orderedSame { filed.append(c.name + " now: " + doing) }
                    now.whereabouts[i].doing = clip(doing, 100)
                }
                guard var r = now.room, let t = r.named(c.name), t.isPerson else { return }
                var p = t
                if !face.isEmpty, face != p.expression { p.expression = clip(face, 60); filed.append(c.name + " looks: " + face) }
                p.holding = holds.isEmpty ? [] : [clip(holds, 50)]
                if !doing.isEmpty { p.doing = clip(doing, 100) }
                Placer.put(&r, p)
                if !whereSaid.isEmpty, whereSaid != "stays put", let z = Zone.parse(whereSaid), t.pastMoves.first != z.text {
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

        // What the person facing the player said, kept with them, word for word (code, no question).
        let lines: [String] = Self.quotes(in: reply)
        if let speaker = mid.whereabouts.first(where: { $0.here != false && $0.engaged == true }).flatMap({ Cards.card(for: $0, in: mid) }), !lines.isEmpty {
            commit { now in
                guard var r = now.room, let t = r.named(speaker.name), let i = r.index(t.id) else { return }
                r.things[i].dialogue = Array((r.things[i].dialogue + lines.map { clip($0, 160) }).suffix(8))
                now.room = r
            }
        }

        // How the people the player is with feel about them now: a word or two each.
        let facingNow: [LoreEntry] = mid.whereabouts.filter { $0.here != false && $0.engaged == true }.compactMap { Cards.card(for: $0, in: mid) }
        for c in facingNow.prefix(2) {
            let fm = await ask("How does " + c.name + " feel about you?", Prompts.rebuildFeeling(c.name + roleOf(c)), JSONGrammar.text("feels", chars: 30), 20)
            guard fm != nil else { return }
            let feels = ((fm?["feels"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n"))
            guard feels.count > 2, !Self.echoesPrompt(feels), feels.split(separator: " ").count <= 4 else { continue }
            asked.append(c.name + " feels? → " + feels)
            commit { now in
                let key = c.name.lowercased()
                if let was = now.feelings[key], was.caseInsensitiveCompare(feels) != .orderedSame { filed.append(c.name + " now feels " + feels + " (was " + was + ")") }
                now.feelings[key] = feels.lowercased()
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
            if learnedSaid.count > 5, !Self.echoesPrompt(learnedSaid), Continuity.grounded(learnedSaid, in: mineOnly, share: 0.5) { learned = learnedSaid }
            let wantOK = wants.count > 3 && !Self.echoesPrompt(wants)
            // What happened between them and the player, kept on their card: only what the player's
            // own words or the reply show.
            let betweenSaid: String = ((wm?["between"] as? String) ?? "").trimmingCharacters(in: trim)
            var together: String = ""
            let togetherWords: Set<String> = Continuity.wordSet(playerSaid + " " + reply + " you your " + c.name + " " + c.role)
            if betweenSaid.count > 5, !Self.echoesPrompt(betweenSaid), Continuity.grounded(betweenSaid, in: togetherWords, share: 0.6) {
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
                + "\n\nWhere is the player at the end of the moment, and who or what are they facing? Only what the story shows. Output ONLY one JSON object:\n{\"where\":\"one of THE PLACES; stays put if they didn't move\",\"facing\":\"one of THE FACES\"}\nThe form:"
            let sm = await ask("Where are you in the room?", q, JSONGrammar.playerNow(zones: zs, faces: fl), 50)
            guard let sm else { return }
            let whereSaid = ((sm["where"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let facingSaid = ((sm["facing"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            asked.append("Where are you in the room? → " + whereSaid + (facingSaid.isEmpty ? "" : ", facing " + facingSaid))
            commit { now in
                guard var r = now.room, let me = r.player else { return }
                if whereSaid != "stays put", let z = Zone.parse(whereSaid) {
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
            if h.range(of: #"(?i)\b(smell|scent|aroma|odou?r|light|glow|sound|air|warmth|chill|feeling|time|moment|chance|question|idea|plan|thought|memory|patience|courage|nerve|worry)s?\b"#, options: .regularExpression) != nil {
                refused.append(h + " (not something you carry)")
                return false
            }
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
        let tm = await ask("What is around?", Prompts.rebuildThings, JSONGrammar.strings("things", max: 6, chars: 60), 120)
        guard tm != nil else { return }
        let around = checked(strings(tm, "things", cap: 6).map { clip($0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), 70) }).filter { e in
            // The light, the air and the room itself are the background, and clothes are their wearer's.
            if e.range(of: #"(?i)\b(light|lamplight|gaslight|candlelight|glow|air|smell|scent|aroma|tang|warmth|chill|silence|stillness|darkness|shadows?|room|backroom|space|music|sound|crackle|steam|clouds?|rain)\b"#, options: .regularExpression) != nil {
                refused.append(e + " (background, not a thing)")
                return false
            }
            if !Rules.onPlan(e) {
                refused.append(e + " (not a thing on the floor)")
                return false
            }
            let w: Set<String> = Continuity.wordSet(e).filter { $0.count > 2 }
            if w.count >= 2, theirs.contains(where: { w.intersection($0).count >= 2 }) {
                refused.append(e + " (someone's own)")
                return false
            }
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
            let am = await ask("Did you get an answer?", Prompts.rebuildAnswered, JSONGrammar.one("answered", from: ["yes", "no"]), 12)
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

        // Does the moment contradict what is on file? A slip becomes a correction for the next reply.
        let fileNow: Adventure = adventure ?? start
        var onFile: [String] = Array(fileNow.facts.filter { !$0.contains(" uses ") }.prefix(3))
        for c in facingNow.prefix(2) {
            onFile += Cards.facts(about: c, in: fileNow).filter { !$0.contains(" uses ") }.suffix(2)
            if !c.desc.isEmpty { onFile.append(c.name + ": " + clip(c.desc, 140)) }
        }
        var seenLines: [String] = []
        // The clock is kept in code, so a line about the time of day or the weather is not checked here.
        let timey = #"(?i)\b(night|morning|evening|afternoon|noon|midnight|dawn|dusk|storm|stormy|rain)\b"#
        for l in onFile where !seenLines.contains(where: { Self.similar($0, l) }) && l.range(of: timey, options: .regularExpression) == nil { seenLines.append(l) }
        onFile = seenLines
        if !onFile.isEmpty {
            let cq: String = "ON FILE:\n" + onFile.map { "- " + clip($0, 160) }.joined(separator: "\n") + "\n" + Prompts.rebuildContradiction
            let xm = await ask("Does anything contradict the file?", cq, JSONGrammar.yesNo("contradicts", then: "line", 160, and: "said", 120), 110)
            guard xm != nil else { return }
            let yes = ((xm?["contradicts"] as? String) ?? "") == "yes"
            let lineSaid: String = ((xm?["line"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n-"))
            var hit: String = ""
            let clash: String = ((xm?["said"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .\n-\""))
            if yes, lineSaid.count > 12 {
                hit = onFile.first(where: { Self.similar($0, lineSaid) || $0.contains(lineSaid) }) ?? ""
            }
            // A slip has to be shown: words really in the story, which don't just say the line on
            // file again. A "yes" that quotes nothing, or quotes agreement, is no slip.
            if !hit.isEmpty {
                let inStory = clash.count > 8 && Continuity.grounded(clash, in: Continuity.wordSet(reply), share: 0.8)
                let agrees = Self.similar(clash, hit) || Continuity.grounded(clash, in: Continuity.wordSet(hit), share: 0.7)
                if !inStory || agrees { refused.append("Not a slip (" + (inStory ? "it agrees with the file" : "no words from the story") + "): " + clip(hit, 80)); hit = "" }
            }
            asked.append("Does anything contradict the file? → " + (hit.isEmpty ? "no" : "yes: " + clip(hit, 100)))
            commit { now in
                guard !hit.isEmpty else { return }
                now.fixes.append(Self.checked + "The last reply slipped on this, and it stays true: " + clip(hit, 160))
                filed.append("Correction for the next reply: " + clip(hit, 100))
            }
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
        if !now.location.isEmpty {
            now.placeSeen[now.location.lowercased()] = now.playerTurns
            if let c = now.clock { now.placeClock[now.location.lowercased()] = c }
        }
        now.checks = Self.worldChanges(from: start, to: now, refused: refused, named: namesThisTurn)
        adventure = now
        library.save(now)
    }

    /// Updates the turn guide's snapshot with what was looked up before the reply.
    /// After a foveated turn: the rebuild questions about the player and the room that the moment
    /// didn't touch. A move, something taken or put down, or a yes from the gate keeps a question.
    private func foveaSkip(_ label: String, wanted: Set<String>, start: Adventure, playerSaid: String) -> Bool {
        let moved = (adventure?.location ?? start.location).caseInsensitiveCompare(placeBeforeTurn) != .orderedSame
        switch label {
        case "What do you have?":
            return !wanted.contains("have") && putDownThisTurn.isEmpty && Self.pickedUp(playerSaid) == nil
        case "What is around?":
            return !wanted.contains("around") && !moved
        case "What's the background like?":
            let known = !(start.ambience[start.location.lowercased()] ?? "").isEmpty
            return known && !moved && !wanted.contains("sound")
        case "Where are you in the room?":
            return !wanted.contains("spot") && !moved
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
        guard !words.isEmpty, words.allSatisfy({ Continuity.wordSet(text).contains($0) }) else { return nil }
        // Not the player, and not someone who already has a card (by name or by role).
        if !words.isDisjoint(with: Continuity.wordSet(a.playerName)) { return nil }
        for c in a.cast {
            let theirs = Continuity.wordSet(c.name + " " + c.role).filter { !titles.contains($0) && $0.count > 2 }
            if !words.isDisjoint(with: theirs) { return nil }
        }
        let line: String = PresenceFilter.sentences(text).first(where: { s in words.contains { s.lowercased().contains($0) } }) ?? ""
        var e = LoreEntry(name: name, kind: .person, desc: clip(line.trimmingCharacters(in: .whitespacesAndNewlines), 200), role: clip(role, 60), known: true)
        e.updatedTurn = a.playerTurns
        _ = addLore(&a, e)
        if !a.whereabouts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            a.whereabouts.append(Whereabout(name: name, at: a.location.isEmpty ? "here" : a.location, here: true, engaged: engaged))
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

    /// Whether the message goes to a place by name: a going word, then the place's last word
    /// within a few words ("I returned back into the velvet thorn", "head to the jazz club").
    /// "A young man with a violin case", "the stranger": someone the story may be bringing in.
    static let someoneNew = #"(?i)\b(a|an|another|the)\s+(?:[a-z]+\s+){0,2}?(man|woman|stranger|boy|girl|waiter|waitress|guard|clerk|doorman|driver|officer|policeman|musician|singer|pianist|violinist|gentleman|lady|fellow|sailor|couple)\b"#

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
    static func keepKnown(_ known: [String]) -> [String] {
        guard known.count > 8 else { return known }
        let names = known.filter { $0.hasPrefix("your name is ") }.suffix(1)
        let rest = known.filter { !$0.hasPrefix("your name is ") }.suffix(8 - names.count)
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
        let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                           options: .init(maxTokens: 200, temperature: 0.6, repetitionPenalty: 1.1, grammar: JSONGrammar.place))) ?? ""
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
        let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                           options: .init(maxTokens: 120, temperature: 0.4, repetitionPenalty: 1.1, grammar: JSONGrammar.away(people: left)))) ?? ""
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
        if opening {
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
            let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                               options: .init(maxTokens: tokens, temperature: 0.3, repetitionPenalty: 1.1, grammar: grammar))) ?? ""
            let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value < 0x2E80 }))
            return JSONExtract.object(plain) ?? Self.salvageJSON(plain)
        }
        func str(_ d: [String: Any], _ k: String) -> String { ((d[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        let about: String = Cards.placeCard(a0)?.desc ?? ""
        var base = "You lay out a room for an audio story, as a top-down plan. Answer only from the lists given; be true to the story, its time and place."
        base += "\n\nTHE ROOM: " + placeName
        if !about.isEmpty { base += "\nWHAT IT IS LIKE: " + clip(about, 240) }
        if !fromName.isEmpty { base += "\nTHE PLAYER CAME FROM: " + fromName }
        let world = [a0.setup.world, a0.setup.place].filter { !$0.isEmpty }.joined(separator: ". ")
        if !world.isEmpty { base += "\nTHE WORLD: " + clip(world, 200) }
        base += "\n\n" + story + "\n\n"

        // 1. The shell.
        let q1 = base + "QUESTION: What is this room's type, and how big would a real one like it be, in metres (true to its time and place: a 1920s speakeasy, a ship's cabin, a cathedral)? Width is west to east, depth is north to south. List its doors (which wall, and where each leads; one leads back the way the player came) and its windows (windows in the walls only, never skylights; which wall, and what is seen through them; none outdoors). Then one line on what is happening inside, and one on what is happening outside.\nTYPES: " + RoomBuilder.types.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"type\":\"one of TYPES\",\"width\":9,\"depth\":7,\"doors\":[{\"wall\":\"north, south, east or west\",\"leads_to\":\"where it goes\"}],\"windows\":[{\"wall\":\"north, south, east or west\",\"view\":\"what is seen\"}],\"inside\":\"one line\",\"outside\":\"one line\"}\nThe form:"
        let m1 = await ask("How big is this room, in metres?", q1, JSONGrammar.roomShell(types: RoomBuilder.types), 260)
        guard !Task.isCancelled else { return }
        var type = str(m1, "type").lowercased()
        if !RoomBuilder.types.contains(type) { type = RoomBuilder.type(for: placeName + " " + about) }
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
        r.inside = Self.echoesPrompt(str(m1, "inside")) ? about : str(m1, "inside")
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
        for d in ((m1["doors"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }).prefix(3) {
            guard let wall = Wall(rawValue: str(d, "wall").lowercased()), let at = slot(wall, width: 1) else { continue }
            let to = Self.echoesPrompt(str(d, "leads_to")) ? "" : str(d, "leads_to")
            doors.append(Opening(wall: wall, at: at, leadsTo: to))
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

        // 2. The things: the fixed zones, and beside or on each kind of furniture.
        var zones = Zone.menu(r)
        for k in ["bar", "counter", "table", "desk", "shelf", "piano", "fireplace", "bed", "sofa"] { zones.append("beside the " + k) }
        for k in ["bar", "counter", "table", "desk", "shelf"] { zones.append("on the " + k) }
        let q2 = base + "THE ROOM SO FAR: a " + type + ", \(r.width) by \(r.depth) metres, doors on the " + doors.map(\.wall.rawValue).joined(separator: " and ")
            + " wall" + (windows.isEmpty ? "" : ", windows on the " + windows.map(\.wall.rawValue).joined(separator: " and ") + " wall") + ".\n"
            + "QUESTION: List up to 8 things standing in this room that the story shows or that a room like this would have: the big furniture first, then smaller things. Only things on the floor or on furniture: no clothing anyone wears, nothing on the ceiling, no sounds or smells. For each: a short name in the story's words, its kind from KINDS, what it is made of, and where it goes in general from PLACES.\nKINDS: " + Rules.kinds.joined(separator: "; ") + "\nPLACES: " + zones.joined(separator: "; ") + "\nOutput ONLY one JSON object:\n{\"things\":[{\"name\":\"a short name\",\"kind\":\"one of KINDS\",\"made_of\":\"a few words\",\"where\":\"one of PLACES\"}]}\nThe form:"
        let m2 = await ask("Building the room: what is in it", q2, JSONGrammar.roomThings(kinds: Rules.kinds, zones: zones), 420)
        guard !Task.isCancelled else { return }
        let castNames = Set(a0.cast.map { $0.name.lowercased() })
        var wanted: [(Thing, Zone)] = []
        for d in ((m2["things"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }).prefix(8) {
            let name = str(d, "name")
            guard name.count >= 3, !Self.echoesPrompt(name), !castNames.contains(name.lowercased()), Rules.onPlan(name),
                  !wanted.contains(where: { $0.0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            var kind = str(d, "kind").lowercased()
            if !Rules.kinds.contains(kind) || kind == "other" { kind = Rules.icon(for: name) }
            var t = Thing(kind: .object, name: name, icon: kind)
            t.makeup = Self.echoesPrompt(str(d, "made_of")) ? "" : str(d, "made_of")
            wanted.append((t, Zone.parse(str(d, "where")) ?? RoomBuilder.defaultZone(kind, in: r)))
        }
        // The template's centrepiece (a bar's bar, a bedroom's bed) is never left out.
        if let lead = tp.pieces.first, !wanted.contains(where: { $0.0.icon == lead.icon }) {
            wanted.insert((Thing(kind: .object, name: lead.name, icon: lead.icon), lead.zone), at: 0)
        }
        // Big furniture first, small things last, so "on the bar" has a bar to go on.
        func rank(_ icon: String) -> Int {
            let rule = Rules.rule(icon)
            return rule.small ? 3 : (Rules.seats.contains(icon) || icon == "lamp" || icon == "plant") ? 2 : icon == "rug" ? 0 : 1
        }
        wanted.sort { rank($0.0.icon) < rank($1.0.icon) }
        var refused: [(Thing, Zone, String)] = []
        for (t, z) in wanted {
            let out = Placer.place(&r, t, zone: z)
            if out.placed {
                r.log.append("place: " + t.name + " → " + z.text)
            } else {
                r.log.append("refuse: " + t.name + " " + z.text + " (" + out.reason + ")")
                refused.append((t, z, out.reason))
            }
            await show(r)
        }

        // 3. Push back once: where else, from the zones that keep the rules.
        var retry: [(Thing, Zone, [String])] = []
        for (t, z, _) in refused {
            let ok = Placer.allowed(t, in: r)
            if ok.isEmpty { Placer.fallback(&r, t, near: z); r.log.append("move: " + t.name + " → nearest allowed spot") } else { retry.append((t, z, ok)) }
        }
        if !retry.isEmpty {
            var q = base + "THE ROOM: \(r.width) by \(r.depth) metres. These things can't go where you said:\n"
            for (i, x) in retry.enumerated() {
                let why = refused.first { $0.0.id == x.0.id }?.2 ?? ""
                q += "\(i + 1). " + x.0.name + ": not " + x.1.text + ", because " + why + ". Where else? Choose from: " + x.2.joined(separator: "; ") + "\n"
            }
            q += "QUESTION: For each number, pick where it goes instead, from its own list. Output ONLY one JSON object, e.g. {\"1\":\"by the north wall\"}\nThe form:"
            for x in retry { r.log.append("ask: where else for " + x.0.name + "?") }
            await show(r, pause: 0.4)
            let m3 = await ask("Building the room: where else?", q, JSONGrammar.roomRetry(allowed: retry.map(\.2)), 40 * retry.count + 20)
            guard !Task.isCancelled else { return }
            for (i, x) in retry.enumerated() {
                let said = str(m3, String(i + 1))
                if let z = Zone.parse(said), x.2.contains(said), Placer.place(&r, x.0, zone: z).placed {
                    r.log.append("place: " + x.0.name + " → " + z.text)
                } else {
                    Placer.fallback(&r, x.0, near: x.1)
                    r.log.append("move: " + x.0.name + " → nearest allowed spot")
                }
                await show(r)
            }
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
        let entry = RoomBuilder.entrance(r, from: from)
        var me = Thing(kind: .player, name: a0.playerName.isEmpty ? "You" : a0.playerName)
        me.x = entry.x; me.y = entry.y; me.on = nil
        me.facing = Facing.toward(dx: r.width / 2 - entry.x, dy: r.depth / 2 - entry.y) ?? .n
        Placer.put(&r, me)
        if !here.isEmpty {
            let pz = Zone.menu(r, people: true)
            var faces: [String] = ["you", "the door"]
            if !windows.isEmpty { faces.append("the window") }
            faces += here
            faces += Array(r.objects.filter { !Rules.rule($0.icon).small }.map(\.name).prefix(6))
            let q4 = base + "THE ROOM NOW: " + r.objects.map(\.name).joined(separator: ", ") + ". The player has just come in by the door.\n"
                + "PLACES: " + pz.joined(separator: "; ") + "\nFACES: " + faces.joined(separator: "; ") + "\n"
                + "QUESTION: For each person here (" + here.joined(separator: ", ") + "), where are they, and who or what are they facing? Output ONLY one JSON object:\n{\"people\":[{\"name\":\"their name\",\"where\":\"one of PLACES\",\"facing\":\"one of FACES\"}]}\nThe form:"
            let m4 = await ask("Building the room: who is where", q4, JSONGrammar.roomPeople(names: here, zones: pz, faces: faces), 60 * here.count + 30)
            guard !Task.isCancelled else { return }
            var placed: Set<String> = []
            var facing: [(UUID, String)] = []
            for d in ((m4["people"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }) {
                let name = str(d, "name")
                guard here.contains(name), !placed.contains(name) else { continue }
                placed.insert(name)
                let z = Zone.parse(str(d, "where")) ?? .farCorner
                let p = Thing(kind: .person, name: name)
                let note = Placer.placePerson(&r, p, zone: z)
                r.log.append("enter: " + name + " " + z.text + (note.isEmpty ? "" : " (" + note + ")"))
                facing.append((p.id, str(d, "facing")))
                await show(r)
            }
            for name in here where !placed.contains(name) {
                let p = Thing(kind: .person, name: name)
                Placer.placePerson(&r, p, zone: .farCorner)
                facing.append((p.id, "you"))
                r.log.append("enter: " + name)
            }
            for (id, f) in facing where !f.isEmpty { Placer.turn(&r, id, toward: f) }
        }
        r.log = Array(r.log.suffix(80))
        await show(r, pause: 0)
        // Everyone placed here is in the room as far as the story is concerned too.
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
        if let a = adventure { library.save(a) }
    }
}

