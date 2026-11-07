import Foundation
import Observation

/// The story engine: builds the world, runs each turn, keeps the clock, remembers what
/// happened, and writes the report card. Ported from the web app's engine.js, with a lighter
/// load for on-device models (one Game Master call per turn, a short memory pass after it).
@Observable
@MainActor
final class StoryEngine {
    private(set) var adventure: Adventure?
    private(set) var streaming = ""
    private(set) var stage = ""
    private(set) var busy = false
    /// True while a new world is being designed (before the first scene exists).
    private(set) var building = false
    var error: String?

    /// Read replies aloud as they are written.
    var narrate: Bool { didSet { UserDefaults.standard.set(narrate, forKey: "narrate") } }
    /// After the narrator finishes, start listening automatically.
    var handsFree: Bool { didSet { UserDefaults.standard.set(handsFree, forKey: "handsFree") } }

    private let llm: LLMService
    private let narrator: Narrator
    private let dictation: Dictation
    private let library: Library
    private var memoryJob: Task<Void, Never>?
    private var undoSnapshot: Adventure?
    private var currentTask: Task<Void, Never>?

    static let secPerTurn = 90.0
    static let maxGap = 300.0

    init(llm: LLMService, narrator: Narrator, dictation: Dictation, library: Library) {
        self.llm = llm
        self.narrator = narrator
        self.dictation = dictation
        self.library = library
        narrate = UserDefaults.standard.object(forKey: "narrate") as? Bool ?? true
        handsFree = UserDefaults.standard.bool(forKey: "handsFree")
        narrator.onFinished = { [weak self] in self?.narrationFinished() }
        dictation.onSend = { [weak self] text in self?.send(text) }
    }

    var canUndo: Bool { undoSnapshot != nil && !busy }

    // MARK: Opening and closing

    func open(_ a: Adventure) {
        stopAll()
        adventure = a
        undoSnapshot = nil
        refreshVocabulary()
    }

    func close() {
        stopAll()
        if let a = adventure { library.save(a) }
        adventure = nil
    }

    func stopAll() {
        currentTask?.cancel()
        narrator.stop()
        dictation.stop()
        streaming = ""
        busy = false
    }

    private func narrationFinished() {
        guard handsFree, let a = adventure, !a.ended, !busy, !dictation.listening else { return }
        Task { await dictation.start() }
    }

    // MARK: Building a world

    func create(_ e: Experience, player: PlayerDetails) {
        stopAll()
        busy = true
        building = true
        error = nil
        currentTask = Task {
            defer { busy = false; building = false; stage = "" }
            stage = "Waking the storyteller"
            do { _ = try await llm.ensureLoaded() } catch { self.error = error.localizedDescription; return }
            guard !Task.isCancelled else { return }

            stage = "Designing your world"
            var a = Adventure(setup: e, title: e.title.isEmpty ? "Untitled" : e.title, minutes: max(5, e.minutes))
            a.playerName = player.name
            let request = (e.simulator ? Prompts.architect + "\n" + Prompts.architectSimulator : Prompts.architect)
            let prompt = "PLAYER'S ANSWERS\n" + e.answers(player: player)
                + "\n\nFEELING TO ACHIEVE: " + (e.feeling.isEmpty ? "surprise me" : e.feeling)
                + "\nSESSION LENGTH: \(a.minutes) minutes (about \(max(3, a.minutes * 60 / 90)) player replies)."
                + (a.isShort ? "\nThis is a SHORT story: a small cast, 2-3 places, 3 acts, one clear goal." : "")
            var plan: [String: Any]?
            for temperature in [Float(0.7), 0.5] where plan == nil {
                guard !Task.isCancelled else { return }
                if let reply = try? await llm.complete(system: nil, prompt: request + "\n\n" + prompt,
                                                       options: .init(maxTokens: 1100, temperature: temperature)) {
                    plan = JSONExtract.object(reply)
                }
            }
            apply(plan ?? [:], to: &a, setup: e)
            building = false
            adventure = a
            undoSnapshot = nil
            refreshVocabulary()
            library.save(a)

            stage = "Raising the curtain"
            await runTurn(input: Prompts.openingInstruction(simulator: e.simulator, short: a.isShort), hidden: true)
        }
    }

    private func apply(_ plan: [String: Any], to a: inout Adventure, setup e: Experience) {
        func str(_ k: String) -> String { (plan[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if !str("title").isEmpty, e.title.isEmpty { a.title = str("title") }
        a.bible = str("bible").isEmpty ? e.describe + "\n\n" + e.answers(player: PlayerDetails.saved) : str("bible")
        a.location = str("location").isEmpty ? e.place : str("location")
        if !str("player_name").isEmpty, a.playerName.isEmpty { a.playerName = str("player_name") }
        let cap = (a.minutes >= 30 ? 3 : 2) + 1
        a.cast = ((plan["cast"] as? [[String: Any]]) ?? []).prefix(cap).compactMap { c in
            guard let n = c["name"] as? String, !n.isEmpty else { return nil }
            return CastMember(name: n, role: c["role"] as? String ?? "", known: c["known"] as? Bool ?? false, desc: c["desc"] as? String ?? "")
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
        a.secrets = (plan["secrets"] as? [String]) ?? []
        if !e.beats.isEmpty { a.secrets.append("Story guide: " + e.beats) }
    }

    // MARK: Playing

    func send(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !busy, let a = adventure, !a.ended else { return }
        dictation.stop()
        dictation.clear()
        busy = true
        currentTask = Task {
            defer { busy = false }
            await runTurn(input: input, hidden: false)
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
        adventure = a
        library.save(a)
    }

    private func runTurn(input: String, hidden: Bool, forceFinal: Bool = false) async {
        guard var a = adventure else { return }
        // Let the memory pass finish first, but never hold up the story for long.
        if let job = memoryJob {
            stage = "Remembering"
            let waiter = Task { await job.value }
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { await waiter.value }
                group.addTask { try? await Task.sleep(for: .seconds(4)) }
                await group.next()
                group.cancelAll()
            }
            a = adventure ?? a
        }
        let snapshot = a
        clockTick(&a, hidden: hidden)
        if forceFinal { a.left = 0 }
        let system = systemPrompt(a)
        var history: [ChatTurn] = []
        for t in a.transcript.dropFirst(a.summarisedTurns).suffix(10) {
            history.append(ChatTurn(role: t.role == .player ? .user : .assistant, text: t.text))
        }
        let briefing = "[GAME MASTER BRIEFING: private, for this reply only]\n" + briefingText(a, playerNarrates: !hidden && Self.narrates(input))
            + "\n[END OF BRIEFING]\n\n" + (hidden ? "INSTRUCTION: " : "THE PLAYER: ") + input
        if history.first?.role == .assistant { history.insert(ChatTurn(role: .user, text: "(The story begins.)"), at: 0) }
        history.append(ChatTurn(role: .user, text: briefing))
        a.lastDirector = adventure?.lastDirector ?? a.lastDirector   // the director just noted which nudge it used

        if !hidden { a.transcript.append(StoryTurn(role: .player, text: input)) }
        adventure = a
        streaming = ""
        stage = "The storyteller is thinking"
        if narrate { narrator.begin() }
        var reply = ""
        do {
            let short = a.isShort
            for try await piece in llm.stream(system: system, history: history, options: .init(maxTokens: short ? 300 : 420, temperature: 0.85)) {
                if stage != "" { stage = "" }
                reply += piece
                streaming = reply
                if narrate { narrator.feed(piece) }
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        if narrate { narrator.finish() }
        stage = ""
        reply = Self.tidy(reply)
        guard !reply.isEmpty, !Task.isCancelled else {
            streaming = ""
            adventure = snapshot
            return
        }
        a.transcript.append(StoryTurn(role: .gm, text: reply))
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
            memoryJob = Task { await self.remember(exchange) }
        }
    }

    /// Strips things small models sometimes add: headings, "GM:" prefixes, trailing option lists.
    static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"(?m)^\s*(#+ .*|\*\*?(Game Master|GM|Narrator)\*?\*?:?\s*)$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^(Game Master|GM|Narrator):\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[GAME MASTER BRIEFING[\s\S]*?END OF BRIEFING\]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
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
        s += "\n\n## STORY BIBLE\n" + a.bible
        if !a.chapters.isEmpty { s += "\n\n## STORY SO FAR\n" + a.chapters.suffix(6).map { "- " + $0 }.joined(separator: "\n") }
        if !a.secrets.isEmpty { s += "\n\n## PRIVATE NOTES (never reveal outright; seed clues)\n" + a.secrets.map { "- " + $0 }.joined(separator: "\n") }
        s += "\n\n## HOW EACH TURN ARRIVES\nThe latest message starts with a private briefing for this reply only, then the player's action. Follow the briefing, never mention it, and reply to the action."
        return s
    }

    private func hiddenPeople(_ a: Adventure) -> [CastMember] {
        let told = a.transcript.filter { $0.role == .gm }.map(\.text).joined(separator: " ")
        return a.cast.filter { c in
            guard !c.known else { return false }
            let first = c.name.split(separator: " ").first.map(String.init) ?? c.name
            return !(told.contains(c.name) || (first.count > 2 && told.contains(first)))
        }
    }

    private func briefingText(_ a: Adventure, playerNarrates: Bool) -> String {
        var lines: [String] = []
        lines.append("Location: " + (a.location.isEmpty ? "unknown" : a.location))
        if a.setup.simulator {
            lines.append("Player's goal: " + (a.setup.goal.isEmpty ? "(open: follow their lead)" : a.setup.goal))
            if !a.goalProgress.isEmpty { lines.append("Progress: " + a.goalProgress) }
        } else if !a.beats.isEmpty {
            let next = a.beats.first { !$0.done }
            lines.append("Story steps: " + a.beats.map { ($0.done ? "[done] " : $0 == next ? "[now] " : "[later] ") + $0.text }.joined(separator: "; "))
        }
        if !a.events.isEmpty { lines.append("Recent events: " + a.events.suffix(6).joined(separator: "; ")) }
        let people = a.cast.map { "\($0.name) (\($0.role)): \($0.desc)" }
        if !people.isEmpty { lines.append("People: " + people.joined(separator: " | ")) }
        let hidden = hiddenPeople(a)
        if !hidden.isEmpty {
            lines.append("Not yet introduced by name (call them by role until the story reveals it): " + hidden.map { "\"\($0.role)\" is \($0.name)" }.joined(separator: "; "))
        }
        lines.append("")
        lines.append("DIRECTOR NOTES FOR THIS REPLY")
        lines.append(contentsOf: directorNotes(a, playerNarrates: playerNarrates).map { "- " + $0 })
        return lines.joined(separator: "\n")
    }

    private func directorNotes(_ a: Adventure, playerNarrates: Bool) -> [String] {
        let turn = a.playerTurns + 1
        let feeling = a.setup.feeling.isEmpty ? "the feeling the player came for" : a.setup.feeling
        let final = a.left == 0
        let wrap = (a.left ?? 99) <= 3
        let happy = (a.mood.feeling ?? 0) >= 7 || !a.mood.enjoying.isEmpty
        let roaming = !a.setup.simulator && a.mood.leavingPlot
        let calm = a.setup.simulator || happy || roaming
        var notes = ["FEELING TO ACHIEVE: \(feeling). Make this reply deliver it."
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
                !((calm || wrap) && Prompts.disruptive.contains(k)) && turn - (a.lastDirector[k] ?? -99) >= 3
            }
            pool.shuffle()
            if let k = pool.first {
                notes.append(Prompts.director[k]!)
                adventure?.lastDirector[k] = turn
            }
        }

        if !a.setup.simulator, !a.roadmap.isEmpty {
            let act = a.roadmap.first { played >= $0.from && played <= $0.to } ?? a.roadmap.first { played < $0.to } ?? a.roadmap.last!
            notes.append(calm
                ? "SECRET ROADMAP (on hold while the player is happy where they are; offer it again only if they reach for it): " + act.goal
                : "SECRET ROADMAP (minute \(Int(played)) of \(a.minutes)): steer gently toward this without revealing it: " + act.goal)
        }
        if let left = a.left {
            notes.append("TIME: about \(max(1, Int(secsLeft(a, live: false) / 60))) of \(a.minutes) minutes left (roughly \(left) more player replies after this one).")
        }
        if final {
            notes.append("THIS IS THE FINAL REPLY. Bring it to a definitive storybook ending that lands the feeling (\(feeling)), paying off what the player actually cared about. Do not ask what they do next; end on a closing image.")
        } else if a.left == 1 {
            notes.append("One reply left after this: start bringing it home.")
        } else if wrap {
            notes.append("WRAP-UP: the session is nearly over. Steer toward a payoff and an ending. No new threads.")
        }
        if !final && !playerNarrates { notes.append(Prompts.endings.randomElement()!) }
        let repeats = repeatedPhrases(a)
        if !repeats.isEmpty { notes.append("Avoid repeating these phrases from recent replies: " + repeats.joined(separator: ", ")) }
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
        let known = start.cast.map { "\($0.name) (\($0.role))" }.joined(separator: ", ")
        let steps = start.beats.filter { !$0.done }.map(\.text).joined(separator: "; ")
        let prompt = Prompts.memory + "\n\nFEELING TO ACHIEVE: " + start.setup.feeling
            + "\nKNOWN PEOPLE: " + (known.isEmpty ? "(none)" : known)
            + "\nOPEN STORY STEPS: " + (steps.isEmpty ? "(none)" : steps)
            + "\n\nLATEST EXCHANGE\n" + exchange
        guard let reply = try? await llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: 350, temperature: 0.3)),
              let m = JSONExtract.object(reply), var a = adventure, a.id == start.id
        else { return }

        a.events.append(contentsOf: ((m["events"] as? [String]) ?? []).prefix(2))
        a.events = Array(a.events.suffix(30))
        if let loc = m["location"] as? String, !loc.isEmpty { a.location = loc }
        if let gp = m["goal_progress"] as? String, !gp.isEmpty { a.goalProgress = gp }
        for p in (m["people"] as? [[String: Any]]) ?? [] {
            guard let name = (p["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let role = p["role"] as? String ?? "", desc = p["desc"] as? String ?? ""
            if let i = a.cast.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || (!role.isEmpty && $0.role.caseInsensitiveCompare(role) == .orderedSame) }) {
                if !desc.isEmpty { a.cast[i].desc = desc }
            } else if a.cast.count < 12, name.caseInsensitiveCompare(a.playerName) != .orderedSame {
                a.cast.append(CastMember(name: name, role: role, known: exchange.contains(name), desc: desc))
            }
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
        }
        adventure = a
        library.save(a)
        refreshVocabulary()
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
