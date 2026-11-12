import SwiftUI
import UIKit

/// Plays the same three ordinary stories on several storytellers, one model after another, and
/// keeps only the dialogue, so the models can be compared side by side.
@Observable
@MainActor
final class ModelBenchmark {
    /// One story as played by one model.
    struct Play {
        var story: String
        var model: String
        var lines: [String] = []
        var minutes = 0.0
        var replySeconds: [Double] = []
        var problems: [String] = []
    }

    private let engine: StoryEngine
    private let store: ModelStore
    private let llm: LLMService
    private(set) var running = false
    private(set) var status = ""
    private(set) var log: [String] = []
    /// The dialogue of the last run, ready to copy.
    private(set) var report = ""
    private(set) var file: URL?
    private var plays: [Play] = []
    private var stamp = ""
    private var job: Task<Void, Never>?

    /// Storytellers to compare, by id.
    var chosen: Set<String> { didSet { UserDefaults.standard.set(Array(chosen), forKey: "benchModels") } }
    /// Stories switched off, by title.
    var skipped: Set<String> { didSet { UserDefaults.standard.set(Array(skipped), forKey: "benchSkipped") } }
    /// Player lines per story.
    var steps: Int { didSet { UserDefaults.standard.set(steps, forKey: "benchSteps") } }

    init(engine: StoryEngine, store: ModelStore, llm: LLMService) {
        self.engine = engine
        self.store = store
        self.llm = llm
        let d = UserDefaults.standard
        skipped = Set(d.stringArray(forKey: "benchSkipped") ?? [])
        let s = d.integer(forKey: "benchSteps")
        steps = s == 0 ? 20 : min(20, max(1, s))
        if let saved = d.stringArray(forKey: "benchModels") {
            chosen = Set(saved)
        } else {
            // Gemma 4 (E4B where it fits comfortably, otherwise E2B), Qwen3.5 4B and an uncensored
            // Qwen GGUF, if they are on this device.
            let installed = store.installed
            func comfy(_ id: String) -> Bool {
                guard installed.contains(id), let e = ModelCatalog.entry(id) else { return false }
                return store.report(for: e).verdict == .comfortable
            }
            let e4b = "mlx-community/gemma-4-e4b-it-4bit", e2b = "mlx-community/gemma-4-e2b-it-4bit"
            var pick = Set(["mlx-community/Qwen3.5-4B-MLX-4bit"].filter(comfy))
            if comfy(e4b) { pick.insert(e4b) } else if comfy(e2b) { pick.insert(e2b) }
            if let gguf = store.customModels.first(where: { $0.isGGUF && comfy($0.id) && $0.name.lowercased().contains("uncensored") }) {
                pick.insert(gguf.id)
            }
            chosen = pick
        }
        if let url = Self.lastFile, let text = try? String(contentsOf: url, encoding: .utf8) {
            report = text
            file = url
        }
    }

    /// Downloaded storytellers that fit this device, in the order the Models tab lists them.
    /// One over the memory limit would close the app partway through the run.
    var models: [ModelEntry] {
        (ModelCatalog.language + store.customModels).filter {
            $0.kind == .language && store.installed.contains($0.id) && store.report(for: $0).verdict != .tooBig
        }
    }

    /// Downloaded storytellers left out because they are too big for this device.
    var tooBig: [ModelEntry] {
        (ModelCatalog.language + store.customModels).filter {
            $0.kind == .language && store.installed.contains($0.id) && store.report(for: $0).verdict == .tooBig
        }
    }

    var queueModels: [ModelEntry] { models.filter { chosen.contains($0.id) } }
    var queueStories: [PlayScript] { Self.stories.filter { !skipped.contains($0.title) } }

    /// A rough guess at the whole run in minutes: building each world plus about a minute and a half a turn.
    var estimate: Int {
        let turns = queueModels.count * queueStories.count * (min(steps, 20) + 3)
        return Int((Double(turns) * 1.5).rounded())
    }

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Benchmark")
    }

    private static var lastFile: URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    func start() {
        let models = queueModels
        let stories = queueStories
        let count = min(20, max(1, steps))
        guard !running, !models.isEmpty, !stories.isEmpty else { return }
        running = true
        log = []
        plays = []
        report = ""
        file = nil
        stamp = Self.makeStamp()
        let original = store.languageID
        let narrated = engine.narrate
        engine.setHandsFree(false)
        engine.narrate = false
        UIApplication.shared.isIdleTimerDisabled = true
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        job = Task {
            outer: for (m, model) in models.enumerated() {
                self.engine.stopAll()
                self.engine.close()
                self.store.languageID = model.id
                self.llm.unload()
                for (s, story) in stories.enumerated() {
                    if Task.isCancelled { break outer }
                    let label = "\(model.name) (\(m + 1) of \(models.count)) · \(story.title) (\(s + 1) of \(stories.count))"
                    let play = await self.play(story, model: model, steps: count, label: label)
                    self.plays.append(play)
                    let avg = play.replySeconds.isEmpty ? 0 : play.replySeconds.reduce(0, +) / Double(play.replySeconds.count)
                    self.log.append(model.name + " · " + story.title + ": \(play.replySeconds.count) of \(count) replies, "
                                    + String(format: "%.1f min, %.0f s a reply", play.minutes, avg)
                                    + (play.problems.isEmpty ? "" : ", \(play.problems.count) " + (play.problems.count == 1 ? "problem" : "problems")))
                    self.write(models: models, stories: stories, steps: count)
                }
            }
            self.engine.stopAll()
            self.engine.close()
            self.store.languageID = original
            self.llm.unload()
            self.engine.narrate = narrated
            UIApplication.shared.isIdleTimerDisabled = false
            self.status = Task.isCancelled ? "Stopped. What was played is below." : "Finished \(self.plays.count) " + (self.plays.count == 1 ? "play." : "plays.")
            self.running = false
        }
    }

    func stop() {
        guard running else { return }
        status = "Stopping after saving what was played"
        job?.cancel()
        engine.stopAll()
    }

    func clear() {
        guard !running else { return }
        try? FileManager.default.removeItem(at: Self.folder)
        report = ""
        file = nil
        log = []
        status = ""
    }

    /// Plays one story on the model that is selected now, keeping only what was said.
    private func play(_ script: PlayScript, model: ModelEntry, steps: Int, label: String) async -> Play {
        var out = Play(story: script.title, model: model.name)
        let began = Date()
        engine.stopAll()
        engine.close()
        engine.error = nil
        status = label + " · building the world"
        var story = script.story
        // The play clock runs on real time, so a slower model would be pushed to its ending sooner.
        // A long session keeps every model in the middle of the story for the whole run.
        story.minutes = 90
        engine.create(story, player: PlayerDetails.saved)
        let built = await engine.waitUntilIdle(limit: 900)
        let buildSecs = Date().timeIntervalSince(began)
        if !built || engine.adventure?.transcript.isEmpty != false {
            let why: String = engine.error ?? (Task.isCancelled ? "stopped" : built ? "no opening was written" : "it took more than 15 minutes")
            out.problems.append("The world did not build: " + why)
            engine.stopAll()
        } else {
            let opening = engine.adventure?.transcript.filter { $0.role == .gm }.map(\.text).joined(separator: "\n\n") ?? ""
            out.lines.append("OPENING  [world built in " + Self.secs(buildSecs) + "]")
            out.lines.append(Self.clean(opening))
            for (i, line) in script.lines.prefix(steps).enumerated() {
                guard !Task.isCancelled, let a = engine.adventure, !a.ended else { break }
                status = label + " · turn \(i + 1) of \(steps)"
                let before = a.transcript.count
                engine.error = nil
                let sent = Date()
                engine.send(line)
                // The reply lands in the transcript first; questions about the world run after it.
                var reply: Double?
                var waited = 0.0
                while !Task.isCancelled, waited < 480 {
                    if (engine.adventure?.transcript.count ?? 0) > before + 1 || ((engine.adventure?.transcript.count ?? 0) > before && !engine.busy) {
                        reply = Date().timeIntervalSince(sent)
                        break
                    }
                    if !engine.busy && !engine.building { break }
                    try? await Task.sleep(for: .milliseconds(250))
                    waited += 0.25
                }
                let done = await engine.waitUntilIdle(limit: max(30, 480 - waited))
                let total = Date().timeIntervalSince(sent)
                out.lines.append("")
                out.lines.append("YOU: " + line)
                if !done {
                    if !Task.isCancelled { out.problems.append("Turn \(i + 1) took more than 8 minutes and was stopped") }
                    out.lines.append("GM: (stopped after " + Self.secs(total) + ")")
                    engine.stopAll()
                    break
                }
                let after = engine.adventure?.transcript ?? []
                let replies = after.count > before ? after[before...].filter { $0.role == .gm }.map(\.text) : []
                if let e = engine.error { out.problems.append("Turn \(i + 1) error: " + e) }
                guard !replies.isEmpty else {
                    out.lines.append("GM: (no reply)")
                    if Task.isCancelled { break }
                    continue
                }
                let text = Self.clean(replies.joined(separator: "\n\n"))
                let r = reply ?? total
                out.replySeconds.append(r)
                let words = text.split { $0 == " " || $0 == "\n" }.count
                out.lines.append("GM: " + text)
                out.lines.append("   [reply " + Self.secs(r) + " · turn done " + Self.secs(total) + " · \(words) words]")
            }
            if engine.adventure?.ended == true { out.lines.append(""); out.lines.append("(the story ended here)") }
        }
        out.minutes = Date().timeIntervalSince(began) / 60
        engine.discard()
        return out
    }

    /// Writes the dialogue so far, grouped by story and then model, to the text box and a file.
    private func write(models: [ModelEntry], stories: [PlayScript], steps: Int) {
        let reasoning = engine.deepThinking && engine.gmPlans ? "reasoning on for MLX models (GGUF never reasons)" : "reasoning off"
        let engineLine = engine.grounded ? "grounded engine" : "Game Master planning " + (engine.gmPlans ? "on" : "off")
        var out = ["PHONODECK MODEL BENCHMARK · " + StoryEngine.build + " · " + stamp,
                   "Models: " + models.map(\.name).joined(separator: ", "),
                   "\(steps) player lines per story · " + engineLine + ", " + reasoning + " · voice off",
                   "Each reply shows how long it took to appear, how long until the turn's follow-up questions finished, and its length."]
        out.append("")
        out.append("SUMMARY")
        for p in plays {
            let avg = p.replySeconds.isEmpty ? 0 : p.replySeconds.reduce(0, +) / Double(p.replySeconds.count)
            out.append("- " + p.story + " · " + p.model + String(format: ": %d replies, %.1f min, average reply %.0f s", p.replySeconds.count, p.minutes, avg)
                       + (p.problems.isEmpty ? "" : " · " + p.problems.joined(separator: "; ")))
        }
        for story in stories {
            let mine = plays.filter { $0.story == story.title }
            guard !mine.isEmpty else { continue }
            out += ["", "", "##########  " + story.title.uppercased() + "  ##########"]
            for p in mine {
                out += ["", "=====  " + p.model + "  =====", ""]
                out += p.problems.map { "PROBLEM: " + $0 }
                out += p.lines
            }
        }
        report = out.joined(separator: "\n")
        let url = Self.folder.appending(path: "Phonodeck benchmark " + stamp + ".txt")
        if (try? report.write(to: url, atomically: true, encoding: .utf8)) != nil { file = url }
    }

    private static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func secs(_ t: Double) -> String {
        t >= 90 ? String(format: "%.1f min", t / 60) : String(format: "%.0f s", t)
    }

    private static func makeStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f.string(from: Date())
    }

    /// Three ordinary evenings: no tricks, just the kind of things a person would say.
    static let stories: [PlayScript] = PlayScripts.parse(storyText)

    static let storyText = """
    # Speakeasy
    story: speakeasy
    I shake the rain off my coat and take a stool at the bar.
    I ask the bartender what he would recommend on a night like this.
    I tell him my name is Sam, and ask his.
    I turn to the woman beside me and say hello.
    I ask her what brings her out in this weather.
    I ask her what she is working on these days.
    I ask the bartender how long he has worked here.
    I ask him what he would do if he did not tend bar.
    I ask the woman what her big break would look like.
    I ask what song is playing on the gramophone.
    I order another drink and offer to buy her one too.
    I tell them I am new in town and do not know anyone yet.
    I ask them what Los Angeles is like for someone starting out.
    I ask the bartender if he has family here.
    I ask the woman where she grew up.
    I tell them a little about the small town I come from.
    I ask if the rain is letting up.
    I ask them what they hope this city looks like in ten years.
    I raise my glass to their dreams.
    I ask if I can come back tomorrow night.

    # Washed Ashore
    story: ashore
    I sit up on the sand and look around.
    I follow the footprints along the beach.
    I call out hello.
    I tell the stranger I washed up from the cruise ship last night.
    I ask their name.
    I ask how long they have lived here.
    I ask if there is fresh water I can drink.
    I offer to help with whatever they are doing.
    I ask what this island is called.
    I ask what they eat out here.
    I help gather coconuts.
    I ask what they miss about the mainland, if anything.
    I tell them what I did for work before the ship sank.
    I ask them to show me their favourite spot on the island.
    We sit and watch the lagoon. I ask what fish live in it.
    I ask how they know when the tide is coming in.
    I ask if they ever get lonely out here.
    As the sun sets, I ask them to teach me the name of a star.
    I tell them I am glad it was this island I washed up on.
    I ask if I can stay and help for a while.

    # Lighthouse
    story: lighthouse
    I check the lamp. What is wrong with it?
    I call Morag on the radio and ask how the weather looks from the village.
    I ask her if the fishing boat has come back yet.
    I ask who is out on the boat.
    I look out to sea through the glass. What can I see?
    I check the clockwork that turns the lens.
    I wind the clockwork by hand.
    I clean the soot from the lamp glass.
    I ask Morag if she can raise the boat on the radio.
    I tell Morag to tell him to come in by the light.
    I trim the wick and relight the lamp.
    I watch the beam sweep across the water.
    I ask Morag how she is holding up in the village.
    I make a cup of tea and keep watch.
    I look for the boat's lights again.
    I flash the lamp toward the boat as a signal.
    I ask Morag if the harbour lights are on.
    I keep winding until my arms ache.
    I ask Morag if there is any word.
    I tell Morag this is why the light still needs a keeper.
    """
}

/// The benchmark screen: pick models and stories, run them, copy the dialogue.
struct BenchmarkView: View {
    @Environment(AppModel.self) private var app
    @State private var copied = false

    var body: some View {
        @Bindable var bench = app.benchmark
        Form {
            Section {
                if bench.running {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(bench.status).font(.subheadline)
                    }
                    Button("Stop", role: .destructive) { bench.stop() }
                } else {
                    let plays = bench.queueModels.count * bench.queueStories.count
                    Button {
                        bench.start()
                    } label: {
                        Label("Run \(plays) " + (plays == 1 ? "play" : "plays"), systemImage: "play.fill")
                    }
                    .disabled(plays == 0 || app.engine.busy || app.autoPlay.running)
                    if !bench.status.isEmpty { Text(bench.status).font(.subheadline).foregroundStyle(.secondary) }
                }
                ForEach(Array(bench.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Plays each story on each model in turn, with the voice off, and keeps only the dialogue. About \(bench.estimate >= 120 ? String(format: "%.1f hours", Double(bench.estimate) / 60) : "\(bench.estimate) minutes") for this set. Keep Phonodeck open and the phone plugged in: the screen stays on while it runs. The storyteller you had selected comes back when it finishes. Every model uses the same Game Master settings.")
            }

            if !bench.report.isEmpty {
                Section {
                    Button {
                        UIPasteboard.general.string = bench.report
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy all the dialogue", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    if let url = bench.file {
                        ShareLink(item: url) { Label("Share as a file", systemImage: "square.and.arrow.up") }
                    }
                    ScrollView {
                        Text(bench.report)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 320)
                    if !bench.running {
                        Button("Delete the results", role: .destructive) { bench.clear() }
                    }
                } header: {
                    Text("Dialogue")
                } footer: {
                    Text("Grouped by story, then model. Paste it to Claude to compare the models.")
                }
                .onChange(of: bench.report) { copied = false }
            }

            Section {
                if bench.models.isEmpty {
                    Text("No storytellers are downloaded yet. Get some in the Models tab.").foregroundStyle(.secondary)
                }
                ForEach(bench.models) { m in
                    Toggle(m.name, isOn: Binding(get: { bench.chosen.contains(m.id) },
                                                 set: { on in if on { bench.chosen.insert(m.id) } else { bench.chosen.remove(m.id) } }))
                }
            } header: {
                Text("Models (\(bench.queueModels.count) on)")
            } footer: {
                let left = bench.tooBig.map(\.name)
                Text("Only downloaded storytellers that fit this \(DeviceFit.deviceWord) are listed."
                     + (left.isEmpty ? "" : " Left out as too big: " + left.joined(separator: ", ") + "."))
            }
            .disabled(bench.running)

            Section {
                ForEach(ModelBenchmark.stories) { s in
                    Toggle(isOn: Binding(get: { !bench.skipped.contains(s.title) },
                                         set: { on in if on { bench.skipped.remove(s.title) } else { bench.skipped.insert(s.title) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title)
                            Text(s.story.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Stepper("\(bench.steps) " + (bench.steps == 1 ? "line" : "lines") + " a story", value: $bench.steps, in: 1...20)
            } header: {
                Text("Stories")
            } footer: {
                Text("The same player lines are said to every model, one per turn.")
            }
            .disabled(bench.running)
        }
        .navigationTitle("Model benchmark")
        .navigationBarTitleDisplayMode(.inline)
    }
}
