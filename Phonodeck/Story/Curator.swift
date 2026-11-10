import SwiftUI

/// One question of the set-up wizard (the web app's Experience Curator).
struct CuratorQuestion: Equatable {
    enum Kind { case chips, me, pick, mode, romance }
    var id: String
    var kind: Kind = .chips
    var q: String
    var h: String
    var c: [String] = []
    /// Options for children (under 13).
    var ck: [String]? = nil
    /// Options for short stories (15 minutes or less): grounded, on Earth.
    var cs: [String]? = nil
    var single = false
    var ph = "Type your own answer, or tap the options"
}

enum CuratorQuestions {
    static let time = CuratorQuestion(id: "time", q: "How much time do you have?", h: "You play by the clock, not by turns. The Game Master keeps an eye on the time and lands a proper ending before it runs out, then you get a report card. 10 to 15 minutes makes a quick short story.",
                                      c: ["10 minutes (a quick story)", "20 minutes", "30 minutes", "45 minutes", "1 hour", "2 hours (an epic)"], single: true, ph: "Or type your own, e.g. 25 minutes")
    static let me = CuratorQuestion(id: "me", kind: .me, q: "About you in the game", h: "These can be made up: play as anyone you like. Your name, age and gender shape the whole story (a 10-year-old and a 70-year-old get very different experiences). They're saved in Settings for next time.")
    static let pick = CuratorQuestion(id: "pick", kind: .pick, q: "Choose an experience", h: "Curated experiences are hand-made worlds, each built around a feeling. Tap one to read it, or build your own world.")
    static let feeling = CuratorQuestion(id: "feeling", q: "What feeling do you want to come away with?", h: "The Phonodeck is a mirror: it gives back what you bring to it. Delivering this feeling is the Game Master's main goal, and the whole story bends toward it. The more specific, the better. Stuck? Tap More ideas.", ph: "e.g. the cosy feeling of a snow day with nowhere to be")
    static let mode = CuratorQuestion(id: "mode", kind: .mode, q: "How do you want to play?", h: "A curated story has a hidden plot with a beginning, middle and end, which bends (or waits) when you're happy elsewhere. The experience simulator has no plot at all: just a richly painted world, your own goal and the feeling.",
                                      c: ["Curated story (a plot that bends to you)", "Experience simulator (no plot, just the world and the feeling)"], single: true)
    static let goal = CuratorQuestion(id: "goal", q: "What do you want to do there?", h: "Your goal for this experience. The Game Master helps you do it, with no plot getting in the way. You can change your mind once you're there.",
                                      c: ["Explore every corner", "Spend time with someone special", "Learn a craft from a local", "Eat my way through the place", "Do absolutely nothing", "Throw a party"],
                                      ck: ["Explore every corner", "Make friends with the animals", "Build something amazing", "Find all the secret places", "Have a feast", "Learn some magic"], ph: "e.g. Spend an evening swapping stories with the locals")
    static let world = CuratorQuestion(id: "world", q: "What kind of world do you want to step into?", h: "Pick an era or a world you find fascinating. The more specific the time and place, the richer the story.",
                                       c: ["The American Civil War, 1863", "France during World War II", "Los Angeles in the 1920s", "Miami in 1985", "Victorian London in the 1880s", "The Caribbean in the age of pirates, 1715", "Tokyo in 2077"],
                                       ck: ["Dragons and castles", "Space adventure", "Magic school", "Pirate treasure hunt", "Dinosaur island", "Superheroes", "Underwater kingdom", "Talking animals", "A friendly haunted house", "Jungle explorer", "Toys come alive"],
                                       ph: "Or name your own, e.g. Ancient Rome in 44 BC")
    static let vibe = CuratorQuestion(id: "vibe", q: "What vibe should it have?", h: "Pick a mood; more than one is fine.",
                                      c: ["Gritty", "Whimsical", "Epic", "Cozy", "Tense", "Funny", "Melancholic", "Romantic", "Mysterious", "Wholesome"],
                                      ck: ["Funny", "Exciting", "Magical", "Cozy", "Silly", "Mysterious (not too scary)", "Brave", "Wholesome"])
    static let who = CuratorQuestion(id: "who", q: "Who are you in this story?", h: "Name, role, background. A sentence is enough.",
                                     c: ["A weary detective", "A rookie adventurer", "A smuggler", "A scholar", "A soldier turned outcast", "A stranger with amnesia"],
                                     ck: ["A young wizard", "A brave knight", "A space cadet", "A kid detective", "A dragon rider", "A pirate captain", "A superhero in training", "A talking animal"],
                                     cs: ["A small-town reporter", "A retired detective", "A ship's cook", "A wedding photographer", "A taxi driver", "A schoolteacher"])
    static let traits = CuratorQuestion(id: "traits", q: "What are your character's strengths and flaws?", h: "These will matter in the story.",
                                        c: ["Clever but reckless", "Strong but stubborn", "Charming but dishonest", "Brave but haunted", "Lucky but broke"],
                                        ck: ["Clever but impatient", "Brave but clumsy", "Kind but shy", "Fast but forgetful", "Funny but a bit loud"])
    static let place = CuratorQuestion(id: "where", q: "Where and when does it begin?", h: "Place, era, weather, atmosphere.",
                                       c: ["A rainy harbour town", "A remote space station", "A royal capital on a festival night", "A desert outpost", "A train in motion", "A city that never sleeps"],
                                       ck: ["A castle on a cloud", "A secret treehouse", "A spaceship", "A magical forest", "A pirate ship", "An underwater city"],
                                       cs: ["A small coastal town", "A busy train station", "A family wedding", "A hotel during a storm", "A coffee farm in the hills", "A city at night"])
    static let hook = CuratorQuestion(id: "hook", q: "What is pulling you into the story?", h: "The hook or central goal.",
                                      c: ["Find someone missing", "Solve a crime", "Survive and escape", "Recover a lost treasure", "Uncover a conspiracy", "Protect someone", "Settle a score", "Build something new"],
                                      ck: ["Find a lost pet", "Find hidden treasure", "Rescue a friend", "Win a big contest", "Solve a mystery", "Save the kingdom", "Make a new friend"])
    static let allies = CuratorQuestion(id: "allies", q: "Who is by your side?", h: "Allies, companions, or none.",
                                        c: ["Lone wolf", "A loyal sidekick", "A rival turned ally", "A small crew", "A mysterious mentor", "A talking animal"],
                                        ck: ["A loyal dog", "A baby dragon", "A robot friend", "My best friend", "A wise owl", "A friendly ghost"])
    static let threat = CuratorQuestion(id: "threat", q: "What stands in your way?", h: "The main threat or antagonist.",
                                        c: ["A shadowy organisation", "A single cunning villain", "Nature itself", "A ticking clock", "My own past", "Something supernatural", "Betrayal from within"],
                                        ck: ["A grumpy troll", "A sneaky thief", "A big storm", "A mischievous wizard", "A ticking clock", "A runaway robot"],
                                        cs: ["A clever con artist", "A storm", "A rival", "A ticking clock", "A family secret", "A misunderstanding"])
    static let play = CuratorQuestion(id: "play", q: "How do you like to play?", h: "Style of play and difficulty.",
                                      c: ["Lots of dialogue", "Action heavy", "Exploration", "Puzzles and clues", "Forgiving", "Dangerous, with real consequences", "Short punchy replies", "Rich, detailed prose"])
    static let avoid = CuratorQuestion(id: "avoid", q: "Anything to avoid, or anything else to know?", h: "Content boundaries, favourite books or films to echo, special requests.",
                                       c: ["Keep it PG-13", "No gore", "No romance", "In the style of a classic novel", "Nothing off limits within reason"],
                                       ck: ["Nothing too scary", "No spiders", "Lots of jokes", "In the style of a fairy tale"])
    static let romance = CuratorQuestion(id: "romance", kind: .romance, q: "Any romance in this story?", h: "Something you said suggests romance. Tell the story who you are and who you're drawn to. It stays in the background unless you take it further.")

    static let story = [world, vibe, who, traits, place, hook, allies, threat, play, avoid]
    static let simulator = [world, place, goal, who, allies, avoid]
}

/// The set-up wizard: how long you have, about you, then a curated experience or a world you build
/// yourself, one question at a time, with option chips and suggestions from the on-device model.
struct CuratorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// An experience to start from (a shared file that was opened).
    var start: Experience?

    @State private var i = 0
    @State private var answers: [String: String] = [:]
    @State private var preset: Experience?
    @State private var describe = ""
    @State private var buildOwn = false
    @State private var extra: [String: [String]] = [:]
    @State private var rounds: [String: Int] = [:]
    @State private var thinking = false
    @State private var message = ""
    @State private var idle: Task<Void, Never>?
    @State private var feelingChips = Array(Prompts.feelingIdeas.shuffled().prefix(6))

    // About you
    @State private var first = ""
    @State private var last = ""
    @State private var gender = ""
    // Romance
    @State private var romGender = ""
    @State private var romInterest = ""
    @State private var romNone = false

    @State private var naming = false
    @State private var name = ""

    /// Phonodeck is for adults only, so there is no age question and no children's mode.
    private var ageNow: Int { 0 }
    private var kid: Bool { ageNow > 0 && ageNow < 13 }
    private var minor: Bool { ageNow > 0 && ageNow < 18 }
    private var minutes: Int { Self.minutes(from: answers["time"] ?? "") }
    private var short: Bool { minutes <= 15 }
    private var simulator: Bool { (answers["mode"] ?? "").localizedCaseInsensitiveContains("simulator") }

    private var questions: [CuratorQuestion] {
        var qs = [CuratorQuestions.time, CuratorQuestions.pick]
        if buildOwn {
            qs += [CuratorQuestions.feeling, CuratorQuestions.mode]
            qs += simulator ? CuratorQuestions.simulator : CuratorQuestions.story
            if !minor && romanceHinted { qs.append(CuratorQuestions.romance) }
        }
        return qs
    }

    private var q: CuratorQuestion { questions[min(i, questions.count - 1)] }
    private var isLast: Bool { i >= questions.count - 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Caps(text: "Experience curator", color: Theme.dim)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.panel)
                            Capsule().fill(Theme.accent).frame(width: g.size.width * Double(i) / Double(max(1, questions.count)))
                        }
                    }
                    .frame(height: 6)
                    .animation(.easeOut(duration: 0.25), value: i)
                    Text(q.kind == .pick || !buildOwn && i < 2 ? "Step \(i + 1)" : "Question \(i + 1) of \(questions.count)")
                        .font(.footnote).foregroundStyle(Theme.dim)
                    Text(q.q).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.fg)
                    Text(hint).font(.subheadline).foregroundStyle(Theme.dim)
                    content
                    if !message.isEmpty { Text(message).font(.callout).foregroundStyle(Theme.fg) }
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom) { navBar }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear(perform: setUp)
        .onChange(of: i) { _, _ in message = ""; armIdle() }
        .alert("Name this experience", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Build my world") { build() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var hint: String {
        if q.kind == .pick, let p = preset {
            return "\(p.title): every detail is filled in (feeling: \(p.feeling)). Edit the description if you like, then tap Build my world."
        }
        return q.h
    }

    // MARK: The step's content

    @ViewBuilder
    private var content: some View {
        switch q.kind {
        case .me: aboutYou
        case .pick: picker
        case .mode: modes
        case .romance: romanceStep
        case .chips: chipsStep
        }
    }

    private var chipsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(q.ph, text: binding(q.id), axis: .vertical)
                .lineLimit(2...6)
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                .onChange(of: answers[q.id] ?? "") { _, _ in armIdle() }
            FlowLayout(spacing: 8) {
                ForEach(chips(q), id: \.self) { c in
                    Chip(text: c, selected: parts(q.id).contains(c), suggested: (extra[q.id] ?? []).contains(c)) { toggle(c) }
                }
            }
            if q.id != "time" {
                HStack(spacing: 10) {
                    Button {
                        Task { await suggest(asked: true) }
                    } label: {
                        Label(q.id == "feeling" ? "Make some suggestions" : "More ideas", systemImage: "sparkles")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .disabled(thinking)
                    if thinking {
                        HoloCore(size: 22)
                        Text("Thinking of more options…").font(.footnote).foregroundStyle(Theme.dim)
                    }
                }
            }
        }
    }

    private var aboutYou: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("First name", $first)
            field("Last name (so characters can say \"Captain Chiu\")", $last)
            field("Gender, in your own words", $gender)
        }
    }

    private var romanceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("You are… (e.g. a man)", $romGender)
            field("Interested in… (e.g. women)", $romInterest)
            Toggle("No romance this time", isOn: $romNone).tint(Theme.accent)
        }
    }

    private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private var modes: some View {
        VStack(spacing: 12) {
            ForEach(Array(q.c.enumerated()), id: \.offset) { n, c in
                let parts = c.components(separatedBy: " (")
                let selected = (answers["mode"] ?? "") == c
                BigCard(primary: selected, glow: true) {
                    answers["mode"] = c
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(parts[0]).font(n == 0 ? .title3.bold() : .headline)
                        if parts.count > 1 {
                            Text(String(parts[1].dropLast())).font(.subheadline).opacity(0.8)
                        }
                    }
                    .padding(.vertical, n == 0 ? 4 : 0)
                }
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            BigCard(primary: buildOwn && preset == nil, glow: true) {
                preset = nil
                buildOwn = true
                advance()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("✦ Build the world myself").font(.title3.bold())
                    Text("Start from a blank slate: the feeling you want, how you want to play, then a few questions with suggestions tailored to you.")
                        .font(.subheadline).opacity(0.8)
                }
            }
            if !kid {
                Caps(text: "Curated experiences", color: Theme.dim).padding(.top, 8)
                presetGrid(CuratedExperiences.all)
                if !app.library.imported.isEmpty {
                    Caps(text: "Shared with you", color: Theme.dim).padding(.top, 8)
                    presetGrid(app.library.imported)
                }
            }
            if preset != nil {
                Text("What you're looking for").font(.footnote).foregroundStyle(Theme.dim).padding(.top, 6)
                TextField("Describe it", text: $describe, axis: .vertical)
                    .lineLimit(3...10)
                    .padding(12)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }
        }
    }

    private func presetGrid(_ list: [Experience]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
            ForEach(list) { p in
                let sel = preset?.id == p.id
                Button {
                    if sel { preset = nil } else { preset = p; describe = p.describe; buildOwn = false }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).font(.subheadline.weight(.semibold))
                        Text(p.feeling).font(.caption).opacity(0.75)
                        Text("\(p.simulator ? "Experience" : "Story")\(p.author.isEmpty ? "" : " · by \(p.author)")").font(.caption2).opacity(0.6)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding(12)
                    .foregroundStyle(sel ? Theme.onAccent : Theme.fg)
                    .background(sel ? Theme.accent : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(sel ? Theme.accent : Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Navigation

    private var navBar: some View {
        HStack(spacing: 10) {
            Button("Back") { if i > 0 { i -= 1 } }
                .disabled(i == 0)
            Spacer()
            Button("Cancel", role: .cancel) { idle?.cancel(); dismiss() }
            if !(q.kind == .pick && preset == nil) {
                Button {
                    next()
                } label: {
                    Text(nextLabel).bold().padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.onAccent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var nextLabel: String {
        if q.kind == .pick { return "Build my world →" }
        return isLast ? "Create my experience" : "Next"
    }

    private func next() {
        if q.kind == .pick, preset != nil { askName(); return }
        if isLast { askName(); return }
        advance()
    }

    private func advance() {
        idle?.cancel()
        if i < questions.count - 1 { i += 1 } else { askName() }
    }

    private func askName() {
        idle?.cancel()
        if let p = preset { name = p.title }
        else {
            let w = (answers["world"] ?? "").components(separatedBy: ",").first ?? ""
            let base = w.trimmingCharacters(in: .whitespaces).isEmpty ? (answers["feeling"] ?? "") : w
            name = base.isEmpty ? "My adventure" : String(base.prefix(32)).trimmingCharacters(in: .whitespaces)
        }
        naming = true
    }

    // MARK: Building the experience

    private func build() {
        let full = [first, last].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        // Remember the details for next time (never overwriting what Settings already has).
        let d = UserDefaults.standard
        if (d.string(forKey: "playerGender") ?? "").isEmpty, !gender.isEmpty { d.set(gender, forKey: "playerGender") }
        if !romNone, !romInterest.isEmpty, (d.string(forKey: "playerInterest") ?? "").isEmpty { d.set(romInterest, forKey: "playerInterest") }

        var e = preset ?? Experience()
        if preset == nil {
            e.id = UUID()
            e.feeling = value("feeling")
            e.simulator = simulator
            e.world = value("world"); e.vibe = value("vibe"); e.who = value("who"); e.traits = value("traits")
            e.place = value("where"); e.goal = value("goal"); e.hook = value("hook"); e.allies = value("allies")
            e.threat = value("threat"); e.play = value("play"); e.avoid = value("avoid")
        } else {
            e.describe = describe
        }
        e.title = name.trimmingCharacters(in: .whitespaces).isEmpty ? (preset?.title ?? "My adventure") : name.trimmingCharacters(in: .whitespaces)
        e.minutes = minutes
        if questions.contains(CuratorQuestions.romance) {
            e.romance = romNone || (romGender.isEmpty && romInterest.isEmpty) ? "No romance" : "I am \(romGender.isEmpty ? "someone" : romGender), interested in \(romInterest.isEmpty ? "anyone who catches my eye" : romInterest)"
        }
        let saved = PlayerDetails.saved
        let mine = first.isEmpty || saved.name.isEmpty || saved.name.lowercased().hasPrefix(first.lowercased())
        let player = PlayerDetails(name: full, age: ageNow, gender: gender,
                                   interest: minor ? "" : (romNone ? "" : !romInterest.isEmpty ? romInterest : mine ? saved.interest : ""))
        app.engine.create(e, player: player)
        dismiss()
    }

    private func value(_ id: String) -> String {
        (answers[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Chips

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    private func chips(_ q: CuratorQuestion) -> [String] {
        let base = baseChips(q)
        return base + (extra[q.id] ?? []).filter { !base.contains($0) }
    }

    /// The hand-written options for a question, before any the model suggested.
    private func baseChips(_ q: CuratorQuestion) -> [String] {
        var base = q.id == "feeling" ? feelingChips : kid && q.ck != nil ? q.ck! : short && q.cs != nil ? q.cs! : q.c
        if minor { base = base.filter { $0.range(of: "roman|love", options: [.regularExpression, .caseInsensitive]) == nil } }
        return base
    }

    private func parts(_ id: String) -> [String] {
        (answers[id] ?? "").components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func toggle(_ c: String) {
        var p = parts(q.id)
        if let k = p.firstIndex(of: c) { p.remove(at: k) } else if q.single { p = [c] } else { p.append(c) }
        answers[q.id] = p.joined(separator: ", ")
    }

    // MARK: Suggestions from the on-device model

    /// If the player lingers on a question, the model suggests a few more options (once per question).
    private func armIdle() {
        idle?.cancel()
        guard q.kind == .chips, q.id != "time", (rounds[q.id] ?? 0) < 1, app.store.hasLanguageModel else { return }
        let id = q.id
        idle = Task {
            try? await Task.sleep(for: .seconds(id == "feeling" ? 4 : 8))
            guard !Task.isCancelled, self.q.id == id else { return }
            await suggest(asked: false)
        }
    }

    private func suggest(asked: Bool) async {
        let question = q
        guard !thinking, question.kind == .chips else { return }
        guard app.store.hasLanguageModel else { message = "Download a storyteller in the Models tab to get suggestions."; return }
        thinking = true
        defer { thinking = false }
        rounds[question.id, default: 0] += 1
        let earlier = questions.prefix(i).compactMap { x -> String? in
            switch x.kind {
            case .me: return "- About the player: " + [first, ageNow > 0 ? "age \(ageNow)" : "", gender].filter { !$0.isEmpty }.joined(separator: ", ")
            case .pick, .romance: return nil
            default: return (answers[x.id] ?? "").isEmpty ? nil : "- \(x.q) \(answers[x.id]!)"
            }
        }.joined(separator: "\n")
        let prompt = Prompts.suggestions(question: question.q, hint: question.h, examples: baseChips(question), avoid: chips(question),
                                         earlier: earlier, world: answers["world"] ?? "",
                                         typed: answers[question.id] ?? "", id: question.id, age: ageNow, short: short)
        do {
            let reply = try await app.llm.complete(system: nil, prompt: prompt, options: .init(maxTokens: 260, temperature: 0.8))
            let raw = (JSONExtract.object(reply)?["options"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count < 80 }
            let opts = Prompts.cleanSuggestions(raw, existing: chips(question), earlierSuggestions: extra[question.id] ?? [])
            guard self.q.id == question.id else { return }
            if opts.isEmpty { if asked { message = "Couldn't think of more options just now. Try again?" } ; return }
            withAnimation { extra[question.id, default: []] += opts.prefix(8).filter { !(extra[question.id] ?? []).contains($0) } }
            message = ""
        } catch {
            if asked { message = "Couldn't think of more options: \(error.localizedDescription)" }
        }
    }

    // MARK: Helpers

    private func setUp() {
        let p = PlayerDetails.saved
        let names = p.name.split(separator: " ").map(String.init)
        first = names.first ?? ""
        last = names.dropFirst().joined(separator: " ")
        gender = p.gender
        romGender = p.gender
        romInterest = p.interest
        if answers["time"] == nil { answers["time"] = "20 minutes" }
        if let s = start {
            preset = s
            describe = s.describe
            answers["time"] = "\(s.minutes) minutes"
            i = 2
        }
    }

    private static let romanceHint = #"\b(roman\w*|love|lovers?|crush|flirt\w*|dating|date night|kiss\w*|sweetheart|passion\w*|wedding|marr(y|ied|iage)|seduc\w*|courtship|affair|soulmate)\b"#
    private var romanceHinted: Bool {
        answers.contains { k, v in
            !["time", "mode", "romance"].contains(k)
                && v.replacingOccurrences(of: #"\b(no|without|avoid|skip)( the)? romance\b"#, with: "", options: [.regularExpression, .caseInsensitive])
                    .range(of: Self.romanceHint, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static func minutes(from s: String) -> Int {
        let n = Double(s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).first { !$0.isEmpty } ?? "") ?? 20
        let m = s.localizedCaseInsensitiveContains("hour") ? n * 60 : n
        return max(5, min(240, Int(m.rounded())))
    }
}
