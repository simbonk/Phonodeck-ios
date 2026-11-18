import Foundation
import Observation
import UIKit

/// The overnight tests: plays the six sample stories by itself on the on-device model, checks the
/// world in code after every turn, and writes one short line per check and a morning report that
/// groups the failures by the model question behind them.
///
/// A run builds each story's opening once (its "baseline room"), then plays blocks: each block
/// opens a fresh copy of one baseline, plays `turnsPerBlock` turns from the scenario bank (with a
/// few improvised turns from a simulated player in between) and throws the copy away, so a block
/// never drifts far from where the story starts. Blocks go round the six stories until the stop time.
@Observable
@MainActor
final class TestRunner {
    static let shared = TestRunner()
    /// True while a run is going: the app then stays "in front" on a Mac even when its window
    /// isn't, and doesn't lock itself.
    nonisolated(unsafe) static var running = false

    var turnsPerBlock = 25
    var stopAt: Date = TestRunner.nextMorning()
    /// Improvised turns from the simulated player between scenarios (0 to 2 each time).
    var improvise = true
    /// One extra yes/no question per turn: did the reply answer what the player did and said?
    var judge = true

    private(set) var isRunning = false
    private(set) var status = ""
    private(set) var blocks = 0
    private(set) var turns = 0
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var recent: [String] = []
    private(set) var runFolder: URL?
    private(set) var lastReport: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    struct Result: Codable {
        var block: Int
        var turn: Int
        var story: String
        var scenario: String
        var check: String
        var step: String
        var expected: String
        var got: String
        var evidence: String
        var pass: Bool
        /// What the player did and said this turn (nil in older runs).
        var input: String? = nil
        var line: String {
            (pass ? "PASS" : "FAIL") + "  b\(block) t\(turn)  \(story)  \(scenario)  \(check)  want: \(expected)  got: \(got)"
                + (pass || step.isEmpty ? "" : "  step: \(step)" + (evidence.isEmpty ? "" : " → \(evidence)"))
        }
    }

    static func nextMorning() -> Date {
        let cal = Calendar.current
        var d = cal.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date().addingTimeInterval(8 * 3600)
        if d < Date().addingTimeInterval(1800) { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }

    nonisolated static var testsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appending(path: "OvernightTests", directoryHint: .isDirectory)
    }

    func start(app: AppModel) {
        guard !isRunning else { return }
        isRunning = true
        Self.running = true
        blocks = 0; turns = 0; passed = 0; failed = 0; recent = []; lastReport = nil
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let folder = Self.testsFolder.appending(path: f.string(from: Date()), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder.appending(path: "traces"), withIntermediateDirectories: true)
        runFolder = folder
        task = Task { await run(app: app, folder: folder) }
    }

    func stop() {
        status = "Stopping after this turn…"
        task?.cancel()
    }

    // MARK: The run

    @ObservationIgnored private var engine: StoryEngine!
    @ObservationIgnored private var llm: LLMService!
    @ObservationIgnored private var file: FileHandle?
    @ObservationIgnored private var tracesKept: [String: Int] = [:]

    private func run(app: AppModel, folder: URL) async {
        engine = app.engine
        llm = app.llm
        tracesKept = [:]
        let wasNarrating = engine.narrate
        engine.narrate = false
        engine.close()
        UIApplication.shared.isIdleTimerDisabled = true
        AppActivity.shared.set(foreground: true)
        FileManager.default.createFile(atPath: folder.appending(path: "results.jsonl").path, contents: nil)
        file = try? FileHandle(forWritingTo: folder.appending(path: "results.jsonl"))
        defer {
            try? file?.close()
            if let a = engine.adventure { engine.close(); app.library.delete(a) }
            engine.narrate = wasNarrating
            isRunning = false
            Self.running = false
        }
        let began = Date()

        // 1. The baseline rooms: each sample story built once.
        var baselines: [Adventure] = []
        for (i, e) in CuratedExperiences.all.enumerated() {
            guard !Task.isCancelled, Date() < stopAt else { break }
            status = "Building baseline \(i + 1) of \(CuratedExperiences.all.count): \(e.title)"
            if let old = engine.adventure { engine.close(); app.library.delete(old) }
            engine.create(e, player: PlayerDetails(name: "", age: 0, gender: "", interest: ""))
            let ok = await waitIdle(limit: 1200)
            await engine.settle()
            guard ok, let a = engine.adventure, a.transcript.contains(where: { $0.role == .gm }) else {
                record(Result(block: 0, turn: 0, story: short(e.title), scenario: "build", check: "build-finished", step: "Build the world",
                              expected: "the opening is told", got: engine.error ?? "it did not finish", evidence: "", pass: false))
                engine.stopAll()
                if let a = engine.adventure { app.library.delete(a) }
                continue
            }
            buildChecks(a)
            baselines.append(a)
            app.library.delete(a)
            if let d = try? JSONEncoder().encode(a) { try? d.write(to: folder.appending(path: "baseline-\(i + 1).json")) }
        }

        // 2. Blocks of turns from fresh copies of the baselines, until the stop time.
        var rng = SystemRandomNumberGenerator()
        var queue: [TestScenarios.Scenario] = []
        while !Task.isCancelled, Date() < stopAt, !baselines.isEmpty {
            blocks += 1
            var base = baselines[(blocks - 1) % baselines.count]
            base.id = UUID()
            status = "Block \(blocks): \(base.setup.title)"
            engine.open(base)
            _ = await waitIdle(limit: 600)
            let ctx = Context(base)
            var played = 0
            while played < turnsPerBlock, !Task.isCancelled, Date() < stopAt {
                if improvise, played > 0, Int.random(in: 0..<3, using: &rng) == 0 {
                    status = "Block \(blocks), turn \(played + 1): the simulated player improvises"
                    let (d, s) = await improvisedTurn()
                    if Task.isCancelled { break }
                    await play(d, s, checks: [], scenario: "improvised", ctx: ctx, block: blocks)
                    played += 1
                    continue
                }
                if queue.isEmpty { queue = TestScenarios.all.shuffled(using: &rng) }
                let sc = queue.removeFirst()
                guard let lines = ctx.fill(sc) else { continue }   // this room hasn't what it needs
                for l in lines {
                    guard played < turnsPerBlock, !Task.isCancelled, Date() < stopAt else { break }
                    status = "Block \(blocks), turn \(played + 1): \(sc.title)"
                    await play(l.did, l.said, checks: l.checks, scenario: sc.id, ctx: ctx, block: blocks)
                    played += 1
                }
            }
            if let a = engine.adventure { engine.close(); app.library.delete(a) }
            writeReport(folder: folder, began: began)
        }
        status = "Writing the report"
        writeReport(folder: folder, began: began)
        status = Task.isCancelled ? "Stopped. The report is ready." : "Finished. The report is ready."
    }

    /// Waits until the engine is free (or `limit` seconds pass, when it is stopped).
    private func waitIdle(limit: Double) async -> Bool {
        let t0 = Date()
        while engine.busy || engine.building {
            if Task.isCancelled { engine.stopAll(); return false }
            if Date().timeIntervalSince(t0) > limit { engine.stopAll(); return false }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return true
    }

    // MARK: One turn

    private func play(_ did: String, _ said: String, checks: [String], scenario: String, ctx: Context, block: Int) async {
        guard let before = engine.adventure else { return }
        let d = did.trimmingCharacters(in: .whitespaces), s = said.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty || !s.isEmpty else { return }
        turns += 1
        let turnNo = before.playerTurns + 1
        let traceFrom = engine.traceCount
        let asksFrom = engine.questionsAsked.count
        let t0 = Date()
        engine.error = nil
        // Typed turns come in two steps, as in the app: what you do, then what you say.
        engine.part(d.isEmpty ? "nothing" : d)
        engine.part(s.isEmpty ? "nothing" : s)
        let finished = await waitIdle(limit: 600)
        await engine.settle()
        let secs = Date().timeIntervalSince(t0)
        guard let after = engine.adventure else { return }
        let reply = after.transcript.last.map { $0.role == .gm ? $0.text : "" } ?? ""
        let gotReply = after.transcript.count > before.transcript.count && !reply.isEmpty
        let asked = Array(engine.questionsAsked.dropFirst(asksFrom))
        let story = short(after.setup.title)
        let input = [d.isEmpty ? "" : d, s.isEmpty ? "" : "\"" + s + "\""].filter { !$0.isEmpty }.joined(separator: " ")
        var results: [Result] = []
        func add(_ check: String, _ step: String, _ want: String, _ got: String, _ pass: Bool) {
            let ev = pass ? "" : evidence(step, in: asked)
            results.append(Result(block: block, turn: turnNo, story: story, scenario: scenario, check: check, step: step,
                                  expected: want, got: got, evidence: ev, pass: pass, input: input))
        }

        add("replied", "The reply", "a reply within 10 minutes", gotReply ? String(format: "replied in %.0fs", secs) : (engine.error ?? (finished ? "no reply" : "timed out")), gotReply)
        if gotReply {
            for r in universal(before: before, after: after, reply: reply, scenarioChecks: checks) { add(r.0, r.1, r.2, r.3, r.4) }
            for c in checks where c != "long-turn" {
                let r = expect(c, before: before, after: after, reply: reply, ctx: ctx)
                add(r.0, r.1, r.2, r.3, r.4)
            }
            if judge, !Task.isCancelled {
                let ok = await judgeAnswered(input: input, reply: reply)
                if let ok { add("answers-the-player", "The reply", "the reply responds to what you did and said", ok ? "yes" : "the judge said no", ok) }
            }
        }
        for r in results { record(r) }
        // One or two full traces for each kind of failure, for the report.
        for r in results where !r.pass {
            let key = r.check + "|" + r.step
            let n = tracesKept[key, default: 0]
            guard n < 2, let folder = runFolder else { continue }
            tracesKept[key] = n + 1
            var text = "# \(r.check), block \(block) turn \(turnNo), \(story), scenario \(scenario)\n\n"
            text += "PLAYER: " + input + "\n\nREPLY: " + reply + "\n\nQUESTIONS THIS TURN:\n" + asked.joined(separator: "\n")
            text += "\n\nTRACE:\n" + engine.traceEntries(from: traceFrom).joined(separator: "\n")
            try? text.write(to: folder.appending(path: "traces/" + safe(key) + "-\(n + 1).txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Checks every turn

    private func universal(before: Adventure, after: Adventure, reply: String, scenarioChecks: [String]) -> [(String, String, String, String, Bool)] {
        var out: [(String, String, String, String, Bool)] = []
        let metres = #"(?i)\b\d+(\.\d+)?\s*(m|metres?|meters?|cm|km)\b|\b(metres?|meters?|centimetres?|centimeters?|kilometres?|kilometers?)\b"#
        if let r = reply.range(of: metres, options: .regularExpression) {
            out.append(("no-metres", "The reply", "no measurements in the prose", "said \"" + String(reply[r]) + "\"", false))
        } else { out.append(("no-metres", "The reply", "no measurements in the prose", "none", true)) }

        let last = reply.trimmingCharacters(in: .whitespacesAndNewlines).last.map(String.init) ?? ""
        let ends = ".!?\"”’…)*".contains(last)
        out.append(("full-sentence", "The reply", "ends on a full sentence", ends ? "yes" : "ends \"…" + String(reply.suffix(30)) + "\"", ends))
        let echo = StoryEngine.echoesPrompt(reply)
        out.append(("no-prompt-echo", "The reply", "no prompt text in the reply", echo ? "echoes the prompt" : "none", !echo))
        let prev = before.transcript.last { $0.role == .gm }?.text ?? ""
        let same = !prev.isEmpty && StoryEngine.similar(prev, reply)
        out.append(("not-a-repeat", "The reply", "a new reply", same ? "nearly the same as the last one" : "new", !same))

        if let c0 = before.clock, let c1 = after.clock {
            let dt = c1 - c0
            out.append(("clock-forward", "How long did that take?", "the clock never runs backwards", "moved \(dt) min", dt >= 0))
            if !scenarioChecks.contains("long-turn") {
                out.append(("clock-sane", "How long did that take?", "an ordinary turn takes under 2 hours", "moved \(dt) min", dt <= 120))
            }
        } else if before.clock != nil {
            out.append(("clock-forward", "How long did that take?", "the clock is kept", "the clock was lost", false))
        }

        let room = after.room
        let onMap = room?.player != nil
        out.append(("player-on-map", "Where are you now?", "you are on the map", onMap ? "yes, in " + (room?.name ?? "") : "not on the map", onMap))

        // Only a copy that appears this turn counts, so one slip isn't counted again every turn after.
        func doubled(_ a: Adventure) -> Set<String> {
            var seen: [String: Int] = [:]
            for r in a.rooms { for p in r.people where p.kind == .person { seen[p.name.lowercased(), default: 0] += 1 } }
            return Set(seen.filter { $0.value > 1 }.map(\.key))
        }
        let twice = doubled(after).subtracting(doubled(before)).sorted()
        out.append(("new-duplicate", "Where are you now?", "nobody copied onto a second map this turn", twice.isEmpty ? "none" : "twice: " + twice.joined(separator: ", "), twice.isEmpty))

        if let room {
            let cards = after.cast.map { $0.name.lowercased() }
            let loose = room.people.filter { $0.kind == .person && !cards.contains($0.name.lowercased()) }.map(\.name)
            out.append(("map-people-have-cards", "Is anyone new here?", "everyone on the map has a card", loose.isEmpty ? "yes" : "no card: " + loose.joined(separator: ", "), loose.isEmpty))
        }

        // Pronouns: the reply's he or she for each person matches their card.
        let firsts = after.cast.map { Cards.first($0.name) }
        for c in after.cast {
            guard let want = after.facts.first(where: { $0.hasPrefix(c.name + " uses ") }) else { continue }
            guard let got = StoryEngine.pronouns(in: reply, for: c.name, others: firsts) else { continue }
            let ok = want.contains(String(got.prefix(3)))
            out.append(("pronouns", "The reply", c.name + ": " + want.replacingOccurrences(of: c.name + " uses ", with: ""), got, ok))
        }
        return out
    }

    /// Checks on a newly built story.
    private func buildChecks(_ a: Adventure) {
        let story = short(a.setup.title)
        func add(_ check: String, _ step: String, _ want: String, _ got: String, _ pass: Bool) {
            record(Result(block: 0, turn: 0, story: story, scenario: "build", check: check, step: step, expected: want, got: got, evidence: "", pass: pass))
        }
        add("build-player-on-map", "Build the room", "you are on the map", a.room?.player != nil ? "yes" : "no", a.room?.player != nil)
        let mapped = Set(a.rooms.flatMap(\.people).map { $0.name.lowercased() })
        let missing = a.cast.filter { !mapped.contains($0.name.lowercased()) }.map(\.name)
        add("build-cast-on-map", "Build the room", "everyone with a card is on the map", missing.isEmpty ? "yes" : "missing: " + missing.joined(separator: ", "), missing.isEmpty)
        add("build-has-clock", "What time does the story open?", "an opening time", a.clock.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "none", a.clock != nil)
        add("build-two-people", "Build the world (the architect)", "at least two people", "\(a.cast.count)", a.cast.count >= 2)
    }

    // MARK: Scenario checks

    private func expect(_ c: String, before: Adventure, after: Adventure, reply: String, ctx: Context) -> (String, String, String, String, Bool) {
        let parts = c.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        let room = after.room
        let player = room?.player
        let people = room?.people.filter { $0.kind == .person } ?? []
        let peopleList = people.isEmpty ? "nobody" : people.map(\.name).joined(separator: ", ")
        let have = (after.carrying + (player?.holding ?? [])).map { $0.lowercased() }
        switch name {
        case "newcomer":
            let words = ctx.words(arg)
            let baseNames = Set(ctx.base.cast.map { $0.name.lowercased() })
            let newCards = after.cast.filter { !baseNames.contains($0.name.lowercased()) }
            let match = newCards.first { card in
                let text = (card.name + " " + card.role + " " + card.desc + " " + card.looks + " " + card.wears).lowercased()
                return words.contains { text.contains($0) }
            }
            guard let card = match else {
                return ("newcomer-card", "Is anyone new here?", "a card for the " + words.joined(separator: "/"), newCards.isEmpty ? "no new card" : "new cards: " + newCards.map(\.name).joined(separator: ", "), false)
            }
            let there = people.contains { $0.name.lowercased() == card.name.lowercased() }
            return ("newcomer-on-map", "Is anyone new here?", card.name + " on the map with you", there ? "there" : "not on the map (with you: " + peopleList + ")", there)
        case "here", "gone":
            let found = ctx.person(arg, in: people, cast: after.cast)
            if name == "here" {
                return ("still-here", "Everyone now?", ctx.label(arg) + " in the room with you", found != nil ? "there" : "not there (with you: " + peopleList + ")", found != nil)
            }
            return ("left-the-room", "Everyone now?", ctx.label(arg) + " gone from the room", found == nil ? "gone" : "still on the map", found == nil)
        case "moved":
            let moved = after.roomID != ctx.base.roomID
            return ("left-for-another-place", "Where are you now?", "you are somewhere else", moved ? "in " + (room?.name ?? "?") : "still in " + (room?.name ?? "?"), moved)
        case "back":
            let back = after.roomID == ctx.base.roomID
            return ("back-in-the-first-room", "Where are you now?", "back in " + (ctx.base.room?.name ?? "the first room"), back ? "back" : "in " + (room?.name ?? "?"), back)
        case "holding", "not-holding":
            let words = ctx.words(arg)
            let has = have.contains { h in words.contains { h.contains($0) || $0.contains(h) } }
            let got = have.isEmpty ? "empty-handed" : "has " + have.joined(separator: ", ")
            return name == "holding"
                ? ("picked-up", "What do you have?", "you have " + arg, got, has)
                : ("put-down", "What do you have?", "you no longer have " + arg, got, !has)
        case "seated", "standing":
            let sitting = player?.on.flatMap { room?.thing($0) }
            if name == "seated" { return ("sat-down", "Do you sit down?", "you are sitting", sitting.map { "on " + $0.name } ?? "standing", sitting != nil) }
            return ("stood-up", "Did you get up?", "you are standing", sitting.map { "still on " + $0.name } ?? "standing", sitting == nil)
        case "near", "facing":
            guard let p = player, let o = ctx.person(arg, in: people, cast: after.cast) else {
                return (name == "near" ? "walked-over" : "turned-to", name == "near" ? "Did you walk somewhere just now?" : "Did you turn to someone else?",
                        ctx.label(arg) + " in the room", "not in the room (with you: " + peopleList + ")", false)
            }
            if name == "near" {
                let dist = RoomGrid.distance(p, o)
                return ("walked-over", "Did you walk somewhere just now?", "next to " + o.name, String(format: "%.1f squares away", dist), dist <= 1.6)
            }
            let ok = RoomGrid.faces(p, o)
            return ("turned-to", "Did you turn to someone else?", "facing " + o.name, ok ? "facing them" : "facing " + p.facing.word, ok)
        case "clock":
            let nums = arg.split(separator: " ").compactMap { Int($0) }
            guard nums.count == 2 else { return ("clock", "", arg, "bad check", false) }
            guard let c0 = before.clock, let c1 = after.clock else { return ("time-passed", "How long did that take?", "\(nums[0])-\(nums[1]) min", "no clock", false) }
            let dt = c1 - c0
            return ("time-passed", "How long did that take?", "\(nums[0])-\(nums[1]) min", "\(dt) min", dt >= nums[0] && dt <= nums[1])
        case "player-named":
            let ok = after.playerName.caseInsensitiveCompare(arg) == .orderedSame
            return ("your-name-kept", "Did anyone give their name?", "your name is " + arg, after.playerName.isEmpty ? "no name" : after.playerName, ok)
        case "known":
            let card = ctx.card(arg, in: after.cast)
            let ok = card?.known == true
            return ("their-name-learned", "Did anyone give their name?", ctx.label(arg) + "'s name is known", card.map { $0.known ? "known: " + $0.name : "still unknown" } ?? "no card", ok)
        case "mentions":
            let words = ctx.words(arg, in: after.cast)
            let low = reply.lowercased()
            let ok = words.contains { low.contains($0) }
            return ("reply-mentions", "The reply", "mentions " + words.joined(separator: "/"), ok ? "yes" : "no", ok)
        case "mentions-present":
            let low = reply.lowercased()
            // The person answering needn't name themselves ("He and I"), and anyone may go by
            // a word of their role or looks ("the boy with the violin").
            let speaking = Set(after.whereabouts.filter { $0.engaged == true }.map { $0.name.lowercased() })
            let missing = people.filter { p in
                if speaking.contains(p.name.lowercased()) { return false }
                let card = after.cast.first { $0.name.lowercased() == p.name.lowercased() }
                var words = card.map { ctx.refWords($0) } ?? [Cards.first(p.name).lowercased()]
                if let c = card { words += Cards.keywords(c.role + " " + c.desc).map { $0.lowercased() } }
                return !words.contains { low.contains($0) }
            }.map(\.name)
            return ("names-who-is-here", "The reply", "mentions everyone with you (" + peopleList + ")", missing.isEmpty ? "yes" : "left out " + missing.joined(separator: ", "), missing.isEmpty)
        default:
            return (name, "", c, "unknown check", false)
        }
    }

    /// The model's own answer to the question a check blames, from this turn's questions.
    private func evidence(_ step: String, in asked: [String]) -> String {
        guard !step.isEmpty, step != "The reply" else { return "" }
        let key = step.lowercased().prefix(18)
        guard let line = asked.last(where: { $0.lowercased().contains(key) }) else {
            // Not asked: the look decided it wasn't needed, so its reading is the evidence.
            guard let look = asked.first(where: { $0.contains("(the look)") }), let r = look.range(of: " → ") else { return "(not asked this turn)" }
            return "not asked; the look said " + String(look[r.upperBound...].prefix(220))
        }
        guard let r = line.range(of: " → ") else { return String(line.prefix(200)) }
        return String(line[r.upperBound...].prefix(200))
    }

    // MARK: The simulated player and the judge

    private func improvisedTurn() async -> (String, String) {
        guard let a = engine.adventure else { return ("I look around.", "") }
        let last = a.transcript.last { $0.role == .gm }?.text ?? ""
        let prompt = """
        You are playing a character in an audio story. You are \(a.setup.who). The story is set in \(a.setup.world).
        Your goal: \(a.setup.goal)

        THE STORY SO FAR (the latest moment):
        \(String(last.suffix(900)))

        Write your next turn, like a real player would: "do" is what you do, one short plain sentence starting with "I" (or "" for nothing), and "say" is what you say aloud, one sentence (or ""). Mix it up: ask someone about their life, move somewhere in the room, pick something up, or react to what just happened.
        Output ONLY one JSON object: {"do":"...","say":"..."}
        """
        let raw = (try? await llm.complete(system: nil, prompt: prompt,
                                                          options: .init(maxTokens: 120, temperature: 0.9, grammar: JSONGrammar.pair("do", 140, "say", 160)))) ?? ""
        let o = JSONExtract.object(raw) ?? [:]
        let d = (o["do"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let s = (o["say"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if d.isEmpty && s.isEmpty { return ("I look around the room.", "") }
        return (d, s)
    }

    private func judgeAnswered(input: String, reply: String) async -> Bool? {
        let prompt = """
        A player in an audio story did and said this: \(input)
        The story replied: \(reply)
        Does the reply respond to what the player did and said (it shows the action happening, and if the player spoke to someone, that person answers or reacts)? Output ONLY one JSON object: {"answer":"yes"} or {"answer":"no"}
        """
        guard let raw = try? await llm.complete(system: nil, prompt: prompt,
                                                               options: .init(maxTokens: 20, temperature: 0.1, grammar: JSONGrammar.one("answer", from: ["yes", "no"]))) else { return nil }
        let ans = ((JSONExtract.object(raw)?["answer"] as? String) ?? raw).lowercased()
        if ans.contains("yes") { return true }
        if ans.contains("no") { return false }
        return nil
    }

    // MARK: Writing

    private func record(_ r: Result) {
        if r.pass { passed += 1 } else { failed += 1 }
        if !r.pass {
            recent.insert(r.line, at: 0)
            if recent.count > 40 { recent.removeLast() }
        }
        if let d = try? JSONEncoder().encode(r) { file?.write(d + Data("\n".utf8)) }
    }

    private func short(_ title: String) -> String {
        title.lowercased().split(whereSeparator: { !$0.isLetter }).prefix(3).joined(separator: "-")
    }
    private func safe(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(60))
    }

    func writeReport(folder: URL, began: Date) {
        let url = TestReport.write(folder: folder, began: began, blocks: blocks, turns: turns)
        lastReport = url
    }
}

// MARK: - What a block knows about its opening room

extension TestRunner {
    /// The baseline room a block starts from, and the words that fill a scenario's braces.
    @MainActor
    final class Context {
        let base: Adventure
        var host: LoreEntry?
        var other: LoreEntry?
        var fills: [String: String] = [:]
        /// What a scenario can be filled from: the people in the opening room, its seats, the
        /// small things in it, and where its door leads. Each scenario picks afresh, so the same
        /// scenario plays a little differently every time.
        let people: [LoreEntry]
        let seats: [String]
        let things: [String]
        let outside: String

        init(_ a: Adventure) {
            base = a
            let inRoom = Set(a.room?.people.map { $0.name.lowercased() } ?? [])
            let here = a.cast.filter { inRoom.contains($0.name.lowercased()) }
            people = here.count >= 2 ? here : a.cast
            let objects = a.room?.objects ?? []
            seats = objects.filter { Rules.seats.contains($0.icon) }.map { Self.the($0.name) }
            things = objects.filter { Rules.rule($0.icon).small && $0.name.count <= 28 }.map { Self.the($0.name) }
            outside = Self.the(a.room?.doors.first { !$0.leadsTo.isEmpty }?.leadsTo ?? "outside")
            roll()
        }

        /// Picks who is who and which seat and thing, for the next scenario.
        func roll() {
            fills = [:]
            let order = people.shuffled()
            host = order.first
            other = order.dropFirst().first
            func she(_ c: LoreEntry) -> Bool { base.facts.first { $0.hasPrefix(c.name + " uses ") }?.contains("she") == true }
            if let h = host {
                fills["{host}"] = Self.ref(h)
                fills["{hostobj}"] = she(h) ? "her" : "him"
                fills["{hostposs}"] = she(h) ? "her" : "his"
            }
            if let o = other {
                fills["{other}"] = Self.ref(o)
                fills["{otherobj}"] = she(o) ? "her" : "him"
                fills["{otherposs}"] = she(o) ? "her" : "his"
            }
            if let seat = seats.randomElement() { fills["{seat}"] = seat }
            if let t = things.randomElement() { fills["{thing}"] = t }
            fills["{outside}"] = outside
        }

        static func the(_ s: String) -> String {
            let l = s.lowercased()
            return l.hasPrefix("the ") || l.hasPrefix("a ") || l.hasPrefix("an ") || l == "outside" ? s : "the " + s
        }
        /// How the player would refer to someone: by first name once known, by role before that.
        static func ref(_ c: LoreEntry) -> String {
            if c.known { return Cards.first(c.name) }
            return c.role.isEmpty ? Cards.first(c.name) : the(c.role)
        }
        /// The words a reply would use for someone.
        func refWords(_ c: LoreEntry) -> [String] {
            var w = [Cards.first(c.name).lowercased()]
            let role = c.role.lowercased().split(separator: " ").filter { !["the", "a", "an", "of"].contains($0) }
            if let last = role.last { w.append(String(last)) }
            return w
        }

        /// The scenario's lines with the braces filled, or nil when this room lacks something it needs.
        /// In checks, a person in braces becomes "@Name" so the check finds them by their card.
        func fill(_ s: TestScenarios.Scenario) -> [TestScenarios.Line]? {
            roll()
            var out: [TestScenarios.Line] = []
            // One pick for the whole scenario: every <<a|b|c>> takes its option at the same
            // place, so a check can follow the line it belongs to ("a violin case" ↔ "violin").
            let pick = Int.random(in: 0..<840)
            // Some turns are said the way people really talk: a filler word, no capital, no stop.
            let fillers = ["um, ", "so, uh, ", "okay so ", "hmm. ", "uh, ", "right, ", "oh, "]
            let casual = Double.random(in: 0..<1) < 0.3
            func choose(_ t: String) -> String {
                var t = t
                while let open = t.range(of: "<<"), let close = t.range(of: ">>", range: open.upperBound..<t.endIndex) {
                    let opts = t[open.upperBound..<close.lowerBound].components(separatedBy: "|")
                    t.replaceSubrange(open.lowerBound..<close.upperBound, with: opts[pick % max(1, opts.count)])
                }
                return t
            }
            func sub(_ t: String, check: Bool) -> String? {
                var t = choose(t)
                for (k, v) in fills {
                    if check, k == "{host}", let h = host { t = t.replacingOccurrences(of: k, with: "@" + h.name); continue }
                    if check, k == "{other}", let o = other { t = t.replacingOccurrences(of: k, with: "@" + o.name); continue }
                    t = t.replacingOccurrences(of: k, with: v)
                }
                if t.contains("{") { return nil }
                return check ? t : t.prefix(1).uppercased() + t.dropFirst()
            }
            for l in s.lines {
                guard var d = sub(l.did, check: false), var w = sub(l.said, check: false) else { return nil }
                if casual, Bool.random() {
                    func loose(_ x: String) -> String {
                        guard !x.isEmpty else { return x }
                        let keepCap = x.hasPrefix("I ") || x.hasPrefix("I'")
                        var y = fillers.randomElement()! + (keepCap ? x : x.prefix(1).lowercased() + x.dropFirst())
                        if Bool.random(), let last = y.last, ".".contains(last) { y.removeLast() }
                        return y
                    }
                    if !w.isEmpty, Bool.random() { w = loose(w) } else { d = loose(d) }
                }
                var checks: [String] = []
                for c in l.checks { guard let x = sub(c, check: true) else { return nil }; checks.append(x) }
                out.append(TestScenarios.Line(did: d, said: w, checks: checks))
            }
            return out
        }

        func card(_ arg: String, in cast: [LoreEntry]) -> LoreEntry? {
            guard arg.hasPrefix("@") else { return nil }
            let n = String(arg.dropFirst()).lowercased()
            return cast.first { $0.name.lowercased() == n }
        }
        func label(_ arg: String) -> String { arg.hasPrefix("@") ? String(arg.dropFirst()) : arg }
        func words(_ arg: String, in cast: [LoreEntry] = []) -> [String] {
            if arg.hasPrefix("@") {
                if let c = card(arg, in: cast) { return refWords(c) }
                return [Cards.first(String(arg.dropFirst())).lowercased()]
            }
            return arg.lowercased().components(separatedBy: "|").map {
                var w = $0.trimmingCharacters(in: .whitespaces)
                for p in ["the ", "a ", "an "] where w.hasPrefix(p) { w = String(w.dropFirst(p.count)) }
                return w
            }.filter { !$0.isEmpty }
        }
        /// The person a check means, among those on the map with you.
        func person(_ arg: String, in people: [Thing], cast: [LoreEntry]) -> Thing? {
            if arg.hasPrefix("@") {
                let n = String(arg.dropFirst()).lowercased()
                return people.first { $0.name.lowercased() == n }
            }
            let ws = words(arg)
            return people.first { p in
                let card = cast.first { $0.name.lowercased() == p.name.lowercased() }
                let text = (p.name + " " + (card.map { $0.role + " " + $0.desc + " " + $0.looks + " " + $0.wears } ?? "")).lowercased()
                return ws.contains { text.contains($0) }
            }
        }
    }
}
