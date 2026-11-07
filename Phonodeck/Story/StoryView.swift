import SwiftUI

struct BuildingView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 20) {
            ProgressView().controlSize(.large)
            Text(app.engine.stage.isEmpty ? "Building your world" : app.engine.stage)
                .font(.title3.bold())
            Text("Your iPhone is writing this world itself, so the first scene takes a minute or so.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let e = app.engine.error {
                Text(e).foregroundStyle(.red).font(.footnote)
            }
            Button("Cancel", role: .cancel) { app.engine.stopAll() }
        }
        .padding(30)
    }
}

/// The story as it is told, with typing, dictation and hands-free play.
struct StoryView: View {
    @Environment(AppModel.self) private var app
    @State private var input = ""
    @State private var showWorld = false
    @State private var showReport = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var engine: StoryEngine { app.engine }
    private var dictation: Dictation { app.dictation }

    var body: some View {
        if let a = engine.adventure {
            VStack(spacing: 0) {
                transcript(a)
                Divider()
                if a.ended {
                    endedBar(a)
                } else {
                    inputBar(a)
                }
            }
            .navigationTitle(a.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(a) }
            .sheet(isPresented: $showWorld) { WorldView() }
            .sheet(isPresented: $showReport) { ReportCardView() }
            .onReceive(tick) { now = $0 }
            .onChange(of: a.report) { _, r in if r != nil { showReport = true } }
            .onChange(of: dictation.text) { _, t in if dictation.listening { input = t } }
        }
    }

    // MARK: Transcript

    private func transcript(_ a: Adventure) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(a.transcript) { t in
                        if t.role == .gm {
                            Text(t.text)
                                .font(Theme.narration)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .onTapGesture(count: 2) { app.narrator.speak(t.text) }
                        } else {
                            Text(t.text)
                                .italic()
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if !engine.streaming.isEmpty {
                        Text(engine.streaming).font(Theme.narration).lineSpacing(4)
                    }
                    if !engine.stage.isEmpty {
                        HStack(spacing: 8) { ProgressView(); Text(engine.stage).foregroundStyle(.secondary) }
                    }
                    if let e = engine.error {
                        Text(e).foregroundStyle(.red).font(.footnote)
                    }
                    if let e = app.narrator.lastError {
                        Text(e).foregroundStyle(.orange).font(.footnote)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .onChange(of: engine.streaming) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: a.transcript.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: Input

    private func inputBar(_ a: Adventure) -> some View {
        VStack(spacing: 8) {
            if dictation.listening {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(dictation.transcribing ? "Hearing you…" : "Listening. Say ")
                    + Text(Dictation.sendPhrase).bold().foregroundColor(Theme.accent)
                    + Text(" to send.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let e = dictation.error { Text(e).font(.footnote).foregroundStyle(.orange) }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    if dictation.listening { dictation.stop() } else {
                        app.narrator.stop()
                        Task { await dictation.start() }
                    }
                } label: {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(dictation.listening ? Theme.accent : .primary)
                        .frame(width: 36, height: 36)
                }
                TextField("What do you do?", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                if engine.busy {
                    Button { engine.stopAll() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                } else {
                    Button {
                        if dictation.listening { dictation.stop(send: true) } else { engine.send(input) }
                        input = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(10)
    }

    private func endedBar(_ a: Adventure) -> some View {
        HStack {
            Button("Report card") {
                if a.report == nil { Task { await engine.writeReportCard() } } else { showReport = true }
            }
            .buttonStyle(.borderedProminent)
            Button("+10 min, keep going") { engine.addTime(10) }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ a: Adventure) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { engine.close() } label: { Image(systemName: "chevron.left") }
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(a.title).font(.subheadline.bold()).lineLimit(1)
                let left = Int((engine.secsLeft(a) / 60).rounded(.up))
                Text(a.ended ? "The end" : "\(left) min left")
                    .font(.caption2)
                    .foregroundStyle(left <= 3 && !a.ended ? Theme.accent : .secondary)
                    .id(now)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showWorld = true } label: { Label("World", systemImage: "globe") }
                Button { engine.addTime(10) } label: { Label("+10 minutes", systemImage: "plus.circle") }
                Toggle(isOn: Binding(get: { engine.narrate }, set: { engine.narrate = $0; if !$0 { app.narrator.stop() } })) {
                    Label("Read aloud", systemImage: "speaker.wave.2")
                }
                Toggle(isOn: Binding(get: { engine.handsFree }, set: { engine.handsFree = $0 })) {
                    Label("Hands-free", systemImage: "ear")
                }
                Button { app.narrator.stop() } label: { Label("Stop reading", systemImage: "speaker.slash") }
                Button { engine.undo() } label: { Label("Undo last turn", systemImage: "arrow.uturn.backward") }
                    .disabled(!engine.canUndo)
                if !a.ended {
                    Button { engine.endNow() } label: { Label("End the story now", systemImage: "flag.checkered") }
                }
                if a.report != nil {
                    Button { showReport = true } label: { Label("Report card", systemImage: "rosette") }
                }
                if let url = app.library.exportFile(a.setup) {
                    ShareLink(item: url) { Label("Share this experience", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

struct WorldView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var bible = ""

    var body: some View {
        NavigationStack {
            if let a = app.engine.adventure {
                Form {
                    Section {
                        TextEditor(text: $bible).frame(minHeight: 200).font(.callout)
                    } header: {
                        Text("Story bible")
                    } footer: {
                        Text("Edit it to change the world; the Game Master follows your version.")
                    }
                    Section("Feeling") { Text(a.setup.feeling.isEmpty ? "Not set" : a.setup.feeling) }
                    if !a.location.isEmpty { Section("Where you are") { Text(a.location) } }
                    if !a.cast.isEmpty {
                        Section("People") {
                            ForEach(a.cast) { c in
                                let met = c.known || a.transcript.contains { $0.role == .gm && $0.text.contains(c.name.split(separator: " ").first.map(String.init) ?? c.name) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(met ? c.name : c.role.capitalized).font(.headline)
                                    if met && !c.role.isEmpty { Text(c.role).font(.caption).foregroundStyle(.secondary) }
                                    if met { Text(c.desc).font(.caption) }
                                }
                            }
                        }
                    }
                    if !a.setup.simulator && !a.beats.isEmpty {
                        Section("Story steps") {
                            ForEach(Array(a.beats.enumerated()), id: \.offset) { _, b in
                                Label(b.text, systemImage: b.done ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    if !a.chapters.isEmpty {
                        Section("Chapters") { ForEach(Array(a.chapters.enumerated()), id: \.offset) { _, c in Text(c).font(.callout) } }
                    }
                    if !a.events.isEmpty {
                        Section("What happened") { ForEach(Array(a.events.suffix(12).enumerated()), id: \.offset) { _, e in Text(e).font(.callout) } }
                    }
                }
                .navigationTitle("World")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if bible != a.bible { app.engine.editBible(bible) }
                            dismiss()
                        }
                    }
                }
                .onAppear { bible = a.bible }
            }
        }
    }
}

struct ReportCardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let a = app.engine.adventure, let r = a.report {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(r.title).font(.largeTitle.bold())
                        Text(r.summary).font(Theme.narration)
                        gradeCard("How the Phonodeck did", r.storyteller)
                        gradeCard("How you did", r.player)
                        if !r.next.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Next time").font(.headline)
                                Text(r.next)
                            }
                        }
                        Button("Read it to me") { app.narrator.speak(r.summary + " " + r.player.comment) }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    ProgressView("Writing your report card…").padding(40)
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func gradeCard(_ title: String, _ g: Grade) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(g.grade)
                .font(.system(size: 40, weight: .bold, design: .serif))
                .foregroundStyle(Theme.accent)
                .frame(width: 70)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(g.comment).font(.callout)
            }
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
