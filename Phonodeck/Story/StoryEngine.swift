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

    /// Read replies aloud as they are written.
    var narrate: Bool { didSet { UserDefaults.standard.set(narrate, forKey: "narrate") } }
    /// The Game Master writes a short private plan before each reply (a few seconds more per turn).
    var gmPlans: Bool { didSet { UserDefaults.standard.set(gmPlans, forKey: "gmPlans") } }
    /// The plan and the look-ahead use the model's reasoning mode (Qwen's thinking): much slower,
    /// up to about a minute per turn, but the Game Master really works the problem first.
    var deepThinking: Bool { didSet { UserDefaults.standard.set(deepThinking, forKey: "deepThinking") } }
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
        narrator.onFinished = { [weak self] in self?.narrationFinished() }
        dictation.onSend = { [weak self] text in self?.send(text) }
    }

    var canUndo: Bool { undoSnapshot != nil && !busy }

    // MARK: Opening and closing

    func open(_ a: Adventure) {
        stopAll()
        forge = nil
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

    /// "Same cast, new story": a new story with an earlier one's cast and world. `link` is how it
    /// connects (one of `Prompts.sequelLinks`), `hook` what happens this time (may be empty).
    func createSequel(from src: Adventure, link: String, hook: String, minutes: Int) {
        var e = src.setup
        e.id = UUID()
        e.title = ""
        e.minutes = minutes
        e.hook = hook.trimmingCharacters(in: .whitespacesAndNewlines)
        e.beats = ""
        var player = PlayerDetails.saved
        if player.name.isEmpty { player.name = src.playerName }
        create(e, player: player, source: src, link: link)
    }

    /// The earlier story, as the architect reads it for a sequel.
    private func sourceWorld(_ src: Adventure) -> String {
        var s = "EARLIER STORY: \"" + (src.report?.title ?? src.title) + "\"\nBIBLE:\n" + clip(src.bible, 1800)
        let lore = src.lore.filter { !$0.isPlayer }.prefix(14)
        if !lore.isEmpty { s += "\nPEOPLE, PLACES AND THINGS:\n" + lore.map { "- \($0.name) (\($0.kind.rawValue)): " + clip($0.desc, 200) }.joined(separator: "\n") }
        if let r = src.report, !r.summary.isEmpty { s += "\nHOW IT WENT:\n" + clip(r.summary, 900) }
        else if !src.chapters.isEmpty { s += "\nHOW IT WENT:\n" + src.chapters.suffix(4).map { "- " + clip($0, 300) }.joined(separator: "\n") }
        if let last = src.transcript.last(where: { $0.role == .gm }) { s += "\nHOW IT ENDED:\n" + clip(last.text, 700) }
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
            var request = (e.simulator ? Prompts.architect + "\n" + Prompts.architectSimulator : Prompts.architect)
            if source != nil { request += "\n" + Prompts.sequel }
            let prompt = (source.map { sourceWorld($0) + "\n\nCONNECTION TO THE EARLIER STORY: " + link + "\n\n" } ?? "")
                + "PLAYER'S ANSWERS\n" + e.answers(player: player)
                + "\n\nFEELING TO ACHIEVE: " + (e.feeling.isEmpty ? "surprise me" : e.feeling)
                + "\nPLAY MODE: " + (e.simulator ? "experience (no plot)" : "story")
                + "\nSESSION LENGTH: \(a.minutes) minutes (about \(max(3, a.minutes * 60 / 90)) player replies)."
                + (a.isShort ? "\nThis is a SHORT story: a small cast, 2-3 places, 3 acts, one clear goal." : "")
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
            }
            forge.reach(Forge.stages.count - 1)
            adventure = a
            undoSnapshot = nil
            refreshVocabulary()
            library.save(a)

            await runTurn(input: Prompts.openingInstruction(simulator: e.simulator, short: a.isShort), hidden: true)
            building = false
            forge.close()
        }
    }

    private func apply(_ plan: [String: Any], to a: inout Adventure, setup e: Experience, player: PlayerDetails) {
        func str(_ k: String, _ d: [String: Any]? = nil) -> String { ((d ?? plan)[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if !str("title").isEmpty, e.title.isEmpty { a.title = str("title") }
        a.bible = str("bible").isEmpty ? e.describe + "\n\n" + e.answers(player: player) : str("bible")
        let openingPlace = str("location").isEmpty ? e.place : str("location")

        // The player
        let p = plan["player"] as? [String: Any]
        let playerName = !player.name.isEmpty ? player.name : !str("name", p).isEmpty ? str("name", p) : str("player_name")
        a.playerName = playerName
        a.lore = [LoreEntry(name: playerName.isEmpty ? "You" : playerName, kind: .person,
                            desc: [str("desc", p), e.who, e.traits].filter { !$0.isEmpty }.joined(separator: ". "), isPlayer: true)]

        // Places, people and things
        for place in (plan["places"] as? [Any]) ?? [] {
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
                                  known: kind != .person || (item["known"] as? Bool ?? false), wants: str("wants", item)))
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
        if e.simulator {
            a.beats = []
            if a.roadmap.isEmpty {
                let m = Double(a.minutes)
                let goal = e.goal.isEmpty ? "what the player came for" : e.goal
                a.roadmap = [
                    Act(from: 0, to: m * 0.3, goal: "Settle in: a first meeting and a small shared moment, toward " + goal + "."),
                    Act(from: m * 0.3, to: m * 0.75, goal: "Deepen it: do something together, trade stories, discover a small delight."),
                    Act(from: m * 0.75, to: m, goal: "A warm closing moment that seals " + goal + " and lands the feeling."),
                ]
            }
        }
        a.facts += ((plan["facts"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(10)
        a.facts = Array(a.facts.prefix(14))
        a.storyTime = clip(str("time"), 160)
        a.timeline = ((plan["timeline"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(5).map { clip($0, 200) }
        a.whereabouts = Self.whereabouts(plan["people"]).filter { w in
            w.name.caseInsensitiveCompare(playerName) != .orderedSame && w.name.caseInsensitiveCompare("you") != .orderedSame
        }
        checkPronouns(&a, texts: [a.bible])
        a.secrets = (plan["secrets"] as? [String]) ?? []
        if !e.beats.isEmpty { a.secrets.append("Story guide: " + e.beats) }
    }

    /// Adds an entry, or updates the one with the same name (the player's own edits always win).
    @discardableResult
    private func addLore(_ a: inout Adventure, _ e: LoreEntry) -> Int {
        let key = e.name.lowercased()
        if let i = a.lore.firstIndex(where: { $0.name.lowercased() == key || (e.kind == .person && !e.role.isEmpty && !$0.known && $0.role.lowercased() == e.role.lowercased()) }) {
            if !a.lore[i].byPlayer {
                if !e.desc.isEmpty { a.lore[i].desc = e.desc }
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
        a.notesStale = a.notes != nil   // so the cast agendas stop describing the old version
        adventure = a
        library.save(a)
        refreshVocabulary()
    }

    func deleteLore(_ id: UUID) {
        guard var a = adventure else { return }
        a.lore.removeAll { $0.id == id && !$0.isPlayer }
        adventure = a
        library.save(a)
    }

    /// The whole story as plain text, for copying out to refine it: the set-up and the world as
    /// the Game Master holds it now, then every turn in order with what happened behind the scenes
    /// (the plan and its reasoning before each reply, the review after it).
    func storyText() -> String {
        guard let a = adventure else { return "" }
        var out = ["# " + a.title, ""]
        if !a.setup.feeling.isEmpty { out.append("Feeling: " + a.setup.feeling) }
        if !a.setup.goal.isEmpty { out.append("Goal: " + a.setup.goal) }
        out.append("Game Master planning " + (gmPlans ? "on" : "off") + ", reasoning " + (deepThinking ? "on" : "off"))
        out += ["", "## Story bible", a.bible]
        let people = a.lore.filter { $0.kind == .person }.map { "- " + $0.name + ($0.isPlayer ? " (the player)" : $0.role.isEmpty ? "" : " (\($0.role))") + ": " + $0.desc }
        if !people.isEmpty { out += ["", "## People"] + people }
        if !a.facts.isEmpty { out += ["", "## Facts now"] + a.facts.map { "- " + $0 } }
        if !a.storyTime.isEmpty { out += ["", "## Story time now", a.storyTime] }
        if !a.timeline.isEmpty { out += ["", "## Timeline"] + a.timeline.map { "- " + $0 } }
        if !a.whereabouts.isEmpty { out += ["", "## Where people are"] + a.whereabouts.map { "- " + $0.line } }
        if !a.scene.isEmpty { out += ["", "## Scene now", a.scene] }
        out += ["", "## The story", ""]
        let me = a.playerName.isEmpty ? "YOU" : a.playerName.uppercased()
        for t in a.transcript {
            if let b = t.before, !b.isEmpty { out += ["[Behind the scenes, before the reply]", b, ""] }
            out.append((t.role == .player ? me : "GAME MASTER") + ":\n" + t.text)
            out.append("")
            if let b = t.after, !b.isEmpty { out += ["[Behind the scenes, the review while it was read aloud]", b, ""] }
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

    func addTime(_ minutes: Int) {
        guard var a = adventure else { return }
        a.minutes += minutes
        a.ended = false
        a.report = nil
        adventure = a
        library.save(a)
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
        guard var a = adventure else { return }
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
        // Game Master's thinking, so the turn waits for them (up to two minutes); otherwise briefly.
        if let job = memoryJob {
            stage = gmPlans ? "The Game Master is finishing its review" : "Remembering"
            let waiter = Task { await job.value }
            let limit: Double = gmPlans ? 120 : 4
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
        clockTick(&a, hidden: hidden)
        if forceFinal { a.left = 0 }
        let system = systemPrompt(a)
        let opening = hidden && a.transcript.isEmpty
        // The opening scene paints the place, so it gets more room than an ordinary reply.
        let maxOut = opening ? 520 : a.isShort ? 300 : 420
        let playerNarrates = !hidden && Self.narrates(input)
        let playerAsks = !hidden && !playerNarrates && Self.asks(input)
        var notes = directorNotes(a, playerNarrates: playerNarrates, playerAsks: playerAsks, opening: opening)
        if !hidden, !playerNarrates, Self.moves(input) {
            notes.insert("THE PLAYER IS MOVING: show them going where they said, the way there, and what they find when they arrive. People are where the scene puts them: someone elsewhere is found there, never suddenly beside the player.", at: playerAsks ? 1 : 0)
        }
        let planning = gmPlans && !hidden
        let continuity = continuityText(a)
        func briefing(_ memories: [String], plan: String = "") -> String {
            "[GAME MASTER BRIEFING: private, for this reply only]\n"
                + (plan.isEmpty ? "" : "YOUR PLAN FOR THIS REPLY (you wrote it after reviewing the story; carry it out)\n" + plan + "\n\n")
                + briefingText(a, memories: memories, director: notes)
                + (continuity.isEmpty ? "" : "\n\n" + continuity)
                + "\n[END OF BRIEFING]\n\n" + (hidden ? "INSTRUCTION: " : "THE PLAYER: ") + input
        }

        // Fit everything into the context the fit check planned for: the system prompt and the
        // briefing first, then the last few turns, then recalled memories, then older turns.
        stage = "Recalling memories"
        let budget = LLMService.contextBudget - maxOut - 200 - (planning ? 380 : 0)   // room for the plan in the briefing
        let fixed = Self.tokens(system) + Self.tokens(briefing([]))
        let recent = Array(a.transcript.enumerated()).dropFirst(a.summarisedTurns).suffix(10)
        let recallReserve = Self.recallChars * 2 / 7
        var kept: [(Int, StoryTurn)] = []
        var used = fixed
        for (i, t) in recent.reversed() {
            let cost = Self.tokens(t.text) + 8
            if kept.count >= 4 && used + cost + recallReserve > budget { break }
            kept.insert((i, t), at: 0)
            used += cost
        }
        let keptIDs = Set(kept.map { $0.1.id })
        let older = a.transcript.enumerated().filter { !keptIDs.contains($0.element.id) }.map { ($0.offset + 1, $0.element) }
        let room = min(Self.recallChars, max(0, (budget - used) * 7 / 2))
        let memories = hidden ? [] : await Recall.memories(for: a, input: input, olderTurns: older, chaptersInPrompt: min(6, a.chapters.count), budget: room,
                                                           earlier: earlierStories(a))
        guard !Task.isCancelled else { adventure = snapshot; return }
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
            plan = await makePlan(snapshot: a, input: input, memories: memories, notes: notes)
            guard !Task.isCancelled else { adventure = snapshot; return }
        }
        var history = kept.map { ChatTurn(role: $0.1.role == .player ? .user : .assistant, text: $0.1.text) }
        if history.first?.role == .assistant { history.insert(ChatTurn(role: .user, text: "(The story begins.)"), at: 0) }
        history.append(ChatTurn(role: .user, text: briefing(memories, plan: plan)))
        stage = "The storyteller is writing"
        if narrate { narrator.begin() }
        var reply = ""
        var interrupted = false
        do {
            for try await piece in llm.stream(system: system, history: history, options: .init(maxTokens: maxOut, temperature: 0.85)) {
                if stage != "" {
                    stage = ""; thinkingSince = nil; forge?.close()
                    if !narrate { ComputerSounds.shared.stopHum() }   // otherwise it hums on until the voice starts
                }
                reply += piece
                streaming = reply
                if narrate { narrator.feed(piece) }
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
        var before: [String] = []
        if !notes.isEmpty { before.append("DIRECTOR NOTES:\n" + notes.map { "- " + $0 }.joined(separator: "\n")) }
        if !memories.isEmpty { before.append("RECALLED MEMORIES:\n" + memories.map { "- " + $0 }.joined(separator: "\n")) }
        if planning, !planThoughts.isEmpty { before.append("REASONING:\n" + planThoughts) }
        if !plan.isEmpty { before.append("PLAN:\n" + plan) }
        a.transcript.append(StoryTurn(role: .gm, text: reply, before: before.isEmpty ? nil : before.joined(separator: "\n\n")))
        streaming = ""
        if a.left == 0 && !hidden { a.ended = true }
        adventure = a
        undoSnapshot = hidden ? nil : snapshot
        library.save(a)
        refreshVocabulary()

        if a.ended {
            await writeReportCard()
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
    private func think(_ prompt: String, quickTokens: Int, deepTokens: Int, temperature: Float, thoughts: ThoughtSink? = nil) async -> String {
        if deepThinking {
            thinkBudget = deepTokens
            defer { thinkBudget = 0 }
            let out = (try? await llm.complete(system: nil, prompt: prompt,
                                               options: .init(maxTokens: deepTokens, temperature: 0.6, repetitionPenalty: nil, thinking: true,
                                                              thoughts: thoughts))) ?? ""
            if !out.isEmpty || Task.isCancelled { return out }
        }
        return (try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: quickTokens, temperature: temperature))) ?? ""
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
        if !a.facts.isEmpty { s += "FACTS (always true):\n" + a.facts.map { "- " + $0 }.joined(separator: "\n") }
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
        var prompt = Prompts.gmPlan + "\n\nSTORY BIBLE:\n" + clip(a.bible, 1200)
        let limits = limitsText(a)
        if !limits.isEmpty { prompt += "\n\nSET-UP LIMITS (never break):\n" + limits }
        let facts = factsText(a)
        if !facts.isEmpty { prompt += "\n\n" + clip(facts, 1200) }
        if !a.scene.isEmpty { prompt += "\n\nSCENE BEFORE THE PLAYER'S ACTION:\n" + a.scene }
        if !a.nextMove.isEmpty { prompt += "\n\nYOUR LOOK-AHEAD (written before the player spoke; only if they went along):\n" + clip(a.nextMove, 500) }
        if let n = a.notes, !n.text.isEmpty { prompt += "\n\nPRIVATE NOTES:\n" + clip(n.text, 500) }
        else if !a.secrets.isEmpty { prompt += "\n\nPRIVATE NOTES:\n" + a.secrets.prefix(4).map { "- " + clip($0, 160) }.joined(separator: "\n") }
        if let m = a.mood.feeling { prompt += "\n\nFEELING READING: \(m)/10" + (a.mood.enjoying.isEmpty ? "" : ", enjoying " + a.mood.enjoying) + (a.mood.leavingPlot ? ", leaving the plot" : "") }
        prompt += "\n\nSTORY STATE:\n" + clip(briefingText(a, memories: memories, director: notes, withFacts: false), deepThinking ? 2200 : 3600)
        let last = a.transcript.dropLast().suffix(2)   // the player's new words are the last turn
        if !last.isEmpty { prompt += "\n\nLAST EXCHANGE:\n" + last.map { ($0.role == .player ? "PLAYER: " : "STORY: ") + clip($0.text, 600) }.joined(separator: "\n") }
        let continuity = continuityText(a)
        if !continuity.isEmpty { prompt += "\n\n" + continuity }
        prompt += "\n\nWHAT THE PLAYER JUST DID: " + clip(input, 800) + "\n\nYour six lines:"
        let sink = ThoughtSink()
        let reply = await think(prompt, quickTokens: Self.planTokens, deepTokens: Self.deepPlanTokens, temperature: 0.4, thoughts: sink)
        planThoughts = sink.clean
        // Keep only the plan lines, in case the model wanders into writing the story itself.
        let lines = reply.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^[-*\s]*(PLAYER|ANSWER|BEAT|WHO|USE|AVOID)\**:"#, options: .regularExpression) != nil }
        return clip(lines.joined(separator: "\n"), 1200)
    }

    /// The look-ahead: while the reply is read aloud, the Game Master checks it against the bible,
    /// the facts and the set-up limits, keeps the facts current, notes slips to correct from now on,
    /// and proposes the next move. Runs after the memory pass, one model call, inside the context
    /// budget like every other call.
    private func review() async {
        guard !Task.isCancelled, let start = adventure, !start.ended, start.transcript.last?.role == .gm else { return }
        var prompt = Prompts.review + "\n\nFEELING TO ACHIEVE: " + (start.setup.feeling.isEmpty ? "what the player came for" : start.setup.feeling)
        prompt += "\n\nSTORY BIBLE:\n" + clip(start.bible, 1600)
        let limits = limitsText(start)
        if !limits.isEmpty { prompt += "\n\nSET-UP LIMITS:\n" + limits }
        prompt += "\n\nCURRENT FACTS:\n" + (start.facts.isEmpty ? "(none yet)" : start.facts.map { "- " + clip($0, 160) }.joined(separator: "\n"))
        if !start.scene.isEmpty { prompt += "\n\nSCENE BEFORE THIS REPLY:\n" + start.scene }
        if !start.storyTime.isEmpty { prompt += "\n\nSTORY TIME BEFORE THIS REPLY: " + start.storyTime }
        if !start.timeline.isEmpty { prompt += "\n\nTIMELINE SO FAR (keep every entry and its time):\n" + start.timeline.suffix(10).map { "- " + $0 }.joined(separator: "\n") }
        if !start.whereabouts.isEmpty { prompt += "\n\nWHERE PEOPLE WERE BEFORE THIS REPLY:\n" + start.whereabouts.map { "- " + $0.line }.joined(separator: "\n") }
        let people = start.cast.prefix(6).map { "- \($0.name)" + ($0.role.isEmpty ? "" : " (\($0.role))") + ": " + clip($0.desc, 160) }
        if !people.isEmpty { prompt += "\n\nPEOPLE:\n" + people.joined(separator: "\n") }
        let played = start.elapsed / 60
        if let act = start.roadmap.first(where: { played >= $0.from && played <= $0.to }) ?? start.roadmap.first(where: { played < $0.to }) {
            prompt += "\n\nROADMAP NOW (minute \(Int(played)) of \(start.minutes)): " + act.goal
            if let next = start.roadmap.first(where: { $0.from > act.from }) { prompt += "\nAFTER THAT: " + next.goal }
        }
        if !start.goalProgress.isEmpty { prompt += "\nPROGRESS: " + start.goalProgress }
        prompt += "\n\nRECENT TURNS (the last one is the reply to review):\n" + recentTurns(start, 3, each: 700)
        let sink = ThoughtSink()
        let reply = await think(prompt, quickTokens: 700, deepTokens: 1400, temperature: 0.3, thoughts: sink)
        guard !Task.isCancelled, var now = adventure, now.id == start.id else { return }
        // Keep the review with the reply it looked at, for the story export.
        if let id = start.transcript.last?.id, let i = now.transcript.firstIndex(where: { $0.id == id }) {
            let thought = sink.clean
            now.transcript[i].after = (thought.isEmpty ? "" : "REASONING:\n" + thought + "\n\n") + "REVIEW:\n" + (reply.isEmpty ? "(no reply)" : reply)
        }
        guard let m = JSONExtract.object(reply) else { adventure = now; library.save(now); return }
        func list(_ k: String) -> [String] {
            ((m[k] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let facts = list("facts")
        if facts.count >= 3 { now.facts = Array(facts.prefix(14)) }
        var fixes = Array(list("fixes").prefix(3))
        if let u = (m["unanswered"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), u.count > 8 {
            fixes.append("Still unanswered, answer it plainly next: " + clip(u, 300))
        }
        now.fixes = fixes
        if let n = (m["next"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { now.nextMove = clip(n, 600) }
        if let sc = (m["scene"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), sc.count > 10 { now.scene = clip(sc, 600) }
        if let t = (m["time"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), t.count > 3 { now.storyTime = clip(t, 160) }
        let timeline = list("timeline")
        // The timeline only grows: a reply that drops earlier entries keeps them.
        if timeline.count >= now.timeline.count || timeline.count >= 3 {
            let kept = now.timeline.filter { old in !timeline.contains { Self.sameEvent($0, old) } }
            now.timeline = Array((timeline.count >= now.timeline.count ? timeline : kept + timeline).map { clip($0, 200) }.suffix(12))
        }
        let whoWhere = Self.whereabouts(m["people"])
        if !whoWhere.isEmpty {
            // Someone the review forgot stays where they were.
            now.whereabouts = whoWhere + now.whereabouts.filter { o in !whoWhere.contains { $0.name.caseInsensitiveCompare(o.name) == .orderedSame } }
            now.whereabouts = Array(now.whereabouts.prefix(8))
        }
        adventure = now
        library.save(now)
    }

    /// How many characters of recalled memories a briefing can carry at most (about 550 tokens).
    static let recallChars = 2000

    /// A cautious token count (about 3.5 bytes a token), for planning a prompt before it is tokenised.
    /// LLMService checks the real count and trims if this ever guesses low.
    static func tokens(_ s: String) -> Int { s.utf8.count * 2 / 7 + 1 }

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

    /// The player says they go somewhere or look for someone ("I go find the caretaker").
    static func moves(_ input: String) -> Bool {
        let pattern = #"(?i)\b(go|goes|going|gotta go|head|heading|walk|walking|run|running|hurry|climb|swim|follow|leave|return|go back|look for|looking for|search for|go find|try to find)\b"#
        return input.range(of: pattern, options: .regularExpression) != nil
    }

    /// The player writes prose rather than commands.
    static func narrates(_ input: String) -> Bool {
        input.split(separator: " ").count > 25 && input.contains(".")
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

    private func clockTick(_ a: inout Adventure, hidden: Bool) {
        let now = Date()
        if !hidden, let last = a.lastSendAt {
            let dt = min(Self.maxGap, max(0, now.timeIntervalSince(last)))
            a.elapsed += dt
            a.turnTimes = Array((a.turnTimes + [dt.rounded()]).suffix(12))
        }
        a.lastSendAt = now
        var left = Int((secsLeft(a, live: false) / turnSecs(a) + 0.35).rounded(.down))
        if hidden && left == 0 { left = 1 }
        a.left = max(0, left)
    }

    // MARK: Prompts

    private func systemPrompt(_ a: Adventure) -> String {
        var s = Prompts.gmRules
        if a.isShort { s += "\n\n" + Prompts.shortRules }
        s += "\n\n" + Prompts.castRules(minutes: a.minutes, names: a.cast.map(\.name))
        if !a.playerName.isEmpty {
            s += "\n\nTHE PLAYER CHARACTER is \(a.playerName), and that is \"you\". The name appears only in other characters' dialogue."
        }
        s += "\n\n" + Prompts.feelingRules(a.setup.feeling)
        s += "\n\n" + Prompts.modeRules(simulator: a.setup.simulator)
        let age = PlayerDetails.saved.age
        if age > 0 { s += "\n\n" + Prompts.ageRules(age) }
        let limits = limitsText(a)
        if !limits.isEmpty { s += "\n\n## SET-UP LIMITS (the player chose these; never break them)\n" + limits }
        s += "\n\n## STORY BIBLE\n" + a.bible
        let pinned = a.lore.filter(\.byPlayer)
        if !pinned.isEmpty {
            s += "\n\n## FACTS THE PLAYER SET (always true; they win over anything said before)\n"
                + pinned.map { "- \($0.name) (\($0.label.lowercased())): \($0.desc)" }.joined(separator: "\n")
        }
        if !a.chapters.isEmpty { s += "\n\n## STORY SO FAR\n" + a.chapters.suffix(6).map { "- " + $0 }.joined(separator: "\n") }
        if let notes = a.notes, !notes.text.isEmpty {
            s += "\n\n## PRIVATE GM NOTES (do not blurt these out; seed clues. If the player asks directly, characters still answer what they honestly know)\n" + notes.text
        } else if !a.secrets.isEmpty {
            s += "\n\n## PRIVATE NOTES (do not blurt these out; seed clues. If the player asks directly, characters still answer what they honestly know)\n" + a.secrets.map { "- " + $0 }.joined(separator: "\n")
        }
        s += "\n\n## HOW EACH TURN ARRIVES\nThe latest message starts with a private briefing for this reply only (mission map, relevant memories, director notes), then the player's action. Follow the briefing, never mention it, and reply to the action."
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
        let first = name.split(separator: " ").first.map(String.init) ?? name
        guard first.count > 1, let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: first) + "\\b") else { return nil }
        let ns = text as NSString
        var he = 0, she = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = m.range.location + m.range.length
            var window = ns.substring(with: NSRange(location: start, length: min(160, ns.length - start)))
            if let p = window.range(of: "\n\n") { window = String(window[..<p.lowerBound]) }
            for o in others where o != first { if let r = window.range(of: o) { window = String(window[..<r.lowerBound]) } }
            for w in window.lowercased().split(whereSeparator: { !$0.isLetter }) {
                switch w {
                case "he", "him", "his", "himself": he += 1
                case "she", "her", "hers", "herself": she += 1
                default: break
                }
            }
        }
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

    /// People positions from a model's JSON: [{name, where, doing, heading}].
    static func whereabouts(_ raw: Any?) -> [Whereabout] {
        ((raw as? [[String: Any]]) ?? []).compactMap { d in
            func f(_ k: String) -> String { (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            let name = f("name"), at = f("where")
            guard !name.isEmpty, !at.isEmpty else { return nil }
            let heading = f("heading")
            let none = ["", "none", "nowhere", "staying", "n/a", "-"].contains(heading.lowercased())
            return Whereabout(name: String(name.prefix(60)), at: String(at.prefix(160)), doing: String(f("doing").prefix(120)),
                              heading: none ? "" : String(heading.prefix(120)))
        }
    }

    /// Two timeline entries about the same moment (the same words after the "when").
    static func sameEvent(_ a: String, _ b: String) -> Bool {
        func what(_ s: String) -> String { (s.split(separator: ":", maxSplits: 1).last.map(String.init) ?? s).lowercased().trimmingCharacters(in: .whitespaces) }
        return what(a) == what(b)
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

    /// Whether the player has told the story their name (or someone already knew them).
    private func nameTold(_ a: Adventure) -> Bool {
        let name = a.playerName.trimmingCharacters(in: .whitespaces)
        let first = name.split(separator: " ").first.map(String.init) ?? name
        guard first.count > 1 else { return true }
        return a.transcript.contains { $0.role == .player && $0.text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: first))\\b", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// The continuity check, placed last in the briefing (right before the player's words, where a
    /// small model pays the most attention): the story time, when past events happened, where each
    /// person is and where they are heading, and who may use the player's name.
    private func continuityText(_ a: Adventure) -> String {
        var l: [String] = []
        if !a.storyTime.isEmpty { l.append("- Story time now: " + a.storyTime + ". Time only moves forward, and only a little in one reply.") }
        if !a.timeline.isEmpty {
            l.append("- When things happened (never change these):")
            l.append(contentsOf: a.timeline.suffix(8).map { "  - " + $0 })
        }
        if !a.whereabouts.isEmpty {
            l.append("- Where people are (no one moves unless the reply shows them going; someone elsewhere cannot speak or be seen):")
            l.append(contentsOf: a.whereabouts.prefix(6).map { "  - " + $0.line })
        }
        if !a.playerName.isEmpty, !nameTold(a) {
            let knew = a.cast.filter(\.known).map(\.name)
            l.append("- Nobody here knows the player's name (\(a.playerName)) because the player has not said it"
                     + (knew.isEmpty ? "" : ", except " + knew.joined(separator: ", ") + ", who already knew them") + ". No one else says it.")
        }
        return l.isEmpty ? "" : "CONTINUITY CHECK (true right now; the reply must agree with every line)\n" + l.joined(separator: "\n")
    }

    private func briefingText(_ a: Adventure, memories: [String], director: [String], withFacts: Bool = true) -> String {
        var lines: [String] = []
        if withFacts {
            if !a.scene.isEmpty { lines.append("SCENE BEFORE THE PLAYER'S ACTION (only people present can speak or act; anyone elsewhere stays there until the player reaches them or they visibly arrive):\n" + a.scene); lines.append("") }
            let f = factsText(a)
            if !f.isEmpty { lines.append(f); lines.append("") }
        }
        lines.append("Location: " + (a.location.isEmpty ? "unknown" : a.location))
        if !a.mapText.isEmpty { lines.append("Mission map: " + a.mapText) }
        if a.setup.simulator {
            lines.append("Player's goal: " + (a.setup.goal.isEmpty ? "(open: follow their lead)" : a.setup.goal))
            if !a.goalProgress.isEmpty { lines.append("Progress: " + a.goalProgress) }
        } else if !a.beats.isEmpty {
            let next = a.beats.first { !$0.done }
            lines.append("Story steps: " + a.beats.map { ($0.done ? "[done] " : $0 == next ? "[now] " : "[later] ") + $0.text }.joined(separator: "; "))
        }
        if !a.events.isEmpty { lines.append("Recent events: " + a.events.suffix(6).joined(separator: "; ")) }
        let people = a.cast.map { "\($0.name)" + ($0.role.isEmpty ? "" : " (\($0.role))") + ": \($0.desc)" + ($0.wants.isEmpty ? "" : " Wants: \($0.wants)") }
        if !people.isEmpty { lines.append("People: " + people.joined(separator: " | ")) }
        let recent = (a.transcript.suffix(2).map(\.text) + [a.location]).joined(separator: " ").lowercased()
        let things = a.lore.filter { $0.kind != .person && !$0.desc.isEmpty && recent.contains($0.name.lowercased()) }.prefix(5)
        if !things.isEmpty { lines.append("Places and things here: " + things.map { "\($0.name): \($0.desc)" }.joined(separator: " | ")) }
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

    private func directorNotes(_ a: Adventure, playerNarrates: Bool, playerAsks: Bool, opening: Bool = false) -> [String] {
        if opening {
            let me = a.lore.first(where: \.isPlayer)?.desc ?? ""
            return [
                "THIS IS THE OPENING SCENE. The listener cannot see anything yet: your words are their eyes. First tell them plainly where they are" + (a.location.isEmpty ? "" : " (\(a.location))") + ", what they are doing and what is around them, then paint it with sound, smell, light and texture.",
                "Say plainly who is with the player right now, and exactly where anyone else is (never \"might be\"). The player has only what the set-up and facts say they have, nothing more.",
                me.isEmpty ? "Make clear who the player is here and why they are in this place." : "Make clear who the player is here (\(clip(me, 200))) and why they are in this place.",
                "FEELING TO ACHIEVE: " + (a.setup.feeling.isEmpty ? "the feeling the player came for" : a.setup.feeling) + ". Set it up from the first lines.",
                "Ignore the usual reply length: the opening may run to about 230 words.",
            ]
        }
        let turn = a.playerTurns + 1
        let feeling = a.setup.feeling.isEmpty ? "the feeling the player came for" : a.setup.feeling
        let final = a.left == 0
        let wrap = (a.left ?? 99) <= 3
        let happy = (a.mood.feeling ?? 0) >= 7 || !a.mood.enjoying.isEmpty
        let roaming = !a.setup.simulator && a.mood.leavingPlot
        let calm = a.setup.simulator || happy || roaming
        var notes: [String] = []
        if playerAsks {
            notes.append("THE PLAYER ASKED A QUESTION. Answer it first, in the opening lines, plainly and concretely: a character who would know tells them, or they see it for themselves. No riddles or vague hints.")
        }
        notes += ["FEELING TO ACHIEVE: \(feeling). Make this reply deliver it."
            + ((a.mood.feeling ?? 10) < 5 ? " Last reading was \(a.mood.feeling ?? 0)/10, so lean into it harder." : "")]
        if happy { notes.append("The player is enjoying this" + (a.mood.enjoying.isEmpty ? "" : " (\(a.mood.enjoying))") + ". No new complications or interruptions; deepen what is working.") }
        if roaming { notes.append("The player is leaving the plot behind. Let it go; make wherever they are worth being in.") }

        let played = a.elapsed / 60
        let phase = calm ? "savour" : played / Double(max(1, a.minutes)) < 0.5 ? "rising" : played / Double(max(1, a.minutes)) < 0.85 ? "peak" : "release"
        notes.append("PACING: " + [
            "rising": "momentum is building; keep things moving and curious.",
            "peak": "a high-intensity beat; force a decisive moment.",
            "release": "aftermath and breathing room; let consequences land.",
            "savour": "stay in the moment and let it breathe; just more of what the player came for.",
        ][phase]!)

        if playerNarrates {
            notes.append("THE PLAYER IS NARRATING: their passage is canon. Do not retell it; continue where it ends, in their voice. Keep it short.")
        } else if !final {
            var pool = Prompts.director.keys.filter { k in
                !((calm || wrap || playerAsks) && Prompts.disruptive.contains(k)) && !(playerAsks && k == "seed")
                    && turn - (a.lastDirector[k] ?? -99) >= 3
            }
            pool.shuffle()
            if let k = pool.first {
                notes.append(Prompts.director[k]!)
                adventure?.lastDirector[k] = turn
            }
        }

        if a.setup.simulator, !a.roadmap.isEmpty {
            let act = a.roadmap.first { played >= $0.from && played <= $0.to } ?? a.roadmap.first { played < $0.to } ?? a.roadmap.last!
            notes.append("GENTLE ARC (minute \(Int(played)) of \(a.minutes)): take one small step toward this, at the player's pace: " + act.goal)
        } else if !a.roadmap.isEmpty {
            let act = a.roadmap.first { played >= $0.from && played <= $0.to } ?? a.roadmap.first { played < $0.to } ?? a.roadmap.last!
            notes.append(calm
                ? "SECRET ROADMAP (on hold while the player is happy where they are; offer it again only if they reach for it): " + act.goal
                : "SECRET ROADMAP (minute \(Int(played)) of \(a.minutes)): steer gently toward this without revealing it: " + act.goal)
        }
        if let left = a.left {
            notes.append("TIME (minute \(Int(played)) of \(a.minutes)): about \(max(1, Int(secsLeft(a, live: false) / 60))) of \(a.minutes) minutes left (roughly \(left) more player replies after this one).")
        }
        if final {
            notes.append("THIS IS THE FINAL REPLY. Bring it to a definitive storybook ending that lands the feeling (\(feeling)), paying off what the player actually cared about. Do not ask what they do next; end on a closing image.")
        } else if a.left == 1 {
            notes.append("One reply left after this: start bringing it home.")
        } else if wrap {
            notes.append("WRAP-UP: the session is nearly over. Steer toward a payoff and an ending. No new threads.")
        }
        if !final && !playerNarrates { notes.append(Prompts.endings.randomElement()!) }
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
        guard let reply = try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: 350, temperature: 0.3)),
              let m = JSONExtract.object(reply), var a = adventure, a.id == start.id
        else { return }

        a.events.append(contentsOf: ((m["events"] as? [String]) ?? []).prefix(2))
        a.events = Array(a.events.suffix(30))
        if let raw = (m["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let loc = Self.placeName(raw, known: a.lore.filter { $0.kind == .place }.map(\.name) + a.places)
            Self.enrichPlace(&a, loc, with: raw)
            a.visit(loc, from: a.location)
            a.location = loc
        }
        if let gp = m["goal_progress"] as? String, !gp.isEmpty { a.goalProgress = gp }
        let turn = a.playerTurns
        for p in ((m["lore"] as? [[String: Any]]) ?? []) + ((m["people"] as? [[String: Any]]) ?? []) {
            guard let name = (p["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  name.caseInsensitiveCompare(a.playerName) != .orderedSame, a.lore.count < 40 else { continue }
            let kind = (p["type"] as? String).map(LoreEntry.kind(from:)) ?? .person
            let i = addLore(&a, LoreEntry(name: name, kind: kind, desc: p["desc"] as? String ?? "", role: p["role"] as? String ?? "",
                                          known: kind != .person || exchange.contains(name)))
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
            a.timeline = now.timeline
            a.whereabouts = now.whereabouts
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

    // MARK: Report card

    func writeReportCard() async {
        guard var a = adventure else { return }
        stage = "Writing your report card"
        defer { stage = "" }
        let story = a.transcript.suffix(16).map { ($0.role == .player ? "PLAYER: " : "STORY: ") + $0.text }.joined(separator: "\n\n")
        let prompt = Prompts.reportCard + "\n\nFEELING TO ACHIEVE: " + a.setup.feeling
            + (a.mood.feeling.map { "\nLast feeling reading: \($0)/10" } ?? "")
            + "\n\nSTORY SO FAR\n" + a.chapters.joined(separator: "\n") + "\n\n" + story
        guard let reply = try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: 600, temperature: 0.6)),
              let m = JSONExtract.object(reply) else {
            error = "The report card didn't come out right. Tap Report card to try again."
            return
        }
        func grade(_ k: String) -> Grade {
            let g = m[k] as? [String: Any] ?? [:]
            return Grade(grade: g["grade"] as? String ?? "B", comment: g["comment"] as? String ?? "")
        }
        a.report = ReportCard(
            title: m["title"] as? String ?? a.title, summary: m["summary"] as? String ?? "",
            storyteller: grade("storyteller"), player: grade("player"), next: m["next"] as? String ?? "")
        adventure = a
        library.save(a)
    }
}
