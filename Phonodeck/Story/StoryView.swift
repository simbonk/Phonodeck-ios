import SwiftUI
import UIKit

/// The story as it is told, with typing and hands-free play, laid out like the web app:
/// a timer pill with +10, the World button, the transcript, and the composer with Hands-free.
struct StoryView: View {
    @Environment(AppModel.self) private var app
    @State private var input = ""
    @State private var showWorld = false
    @State private var showReport = false
    /// Keep the newest text in view. Off once the player scrolls up to read, back on when they return to the bottom.
    @State private var follow = true
    @State private var nearBottom = true
    /// Story text size in points. Defaults a little under body size so more of a passage fits on an iPhone.
    @AppStorage("storyTextSize") private var textSize: Double = 15
    @FocusState private var typing: Bool

    private var engine: StoryEngine { app.engine }
    private var dictation: Dictation { app.dictation }

    var body: some View {
        if let a = engine.adventure {
            VStack(spacing: 0) {
                header(a)
                transcript(a)
                if engine.resuming {
                    resumingBar
                } else if a.ended {
                    endedBar(a)
                } else {
                    composer(a)
                }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .sheet(isPresented: $showWorld) { WorldView() }
            .sheet(isPresented: $showReport) { ReportCardView() }
            .onChange(of: a.report) { _, r in if r != nil { showReport = true } }
            .onChange(of: dictation.text) { _, t in if dictation.listening { input = t } }
            // "Make it so" sent what was said: empty the box for the next turn.
            .onChange(of: dictation.sent) { input = "" }
            .onChange(of: engine.handsFree) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    // MARK: Header: title, the timer pill (+10), World, menu, and a bar that fills as the session runs

    private func header(_ a: Adventure) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            let left = Int((engine.secsLeft(a) / 60).rounded(.up))
            let low = !a.ended && left <= 3
            let color = low ? Theme.warn : Theme.accent
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { engine.close() } label: {
                        Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 32, height: 36)
                    }
                    .accessibilityLabel("Menu")
                    VStack(alignment: .leading, spacing: 0) {
                        Text("PHONODECK").font(.caption.bold()).tracking(1.5).foregroundStyle(Theme.accent)
                        Text(a.title).font(.subheadline).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Image(systemName: a.ended ? "checkmark.circle" : "timer").font(.subheadline.weight(.semibold))
                            Text(a.ended ? "done" : "\(left) min").font(.subheadline.bold().monospacedDigit())
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(a.ended ? "Complete" : "\(left) minutes left")
                        if !a.ended {
                            Button { engine.addTime(10) } label: {
                                Text("+10").font(.subheadline.bold()).lineLimit(1).fixedSize().padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(color.opacity(0.16))
                            }
                            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 1.5) }
                            .accessibilityLabel("Add 10 minutes")
                        }
                    }
                    .foregroundStyle(color)
                    .overlay(Capsule().stroke(color, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .fixedSize()
                    .layoutPriority(1)
                    Button { showWorld = true } label: {
                        Image(systemName: "globe").font(.title3)
                    }
                    .accessibilityLabel("World")
                    menu(a)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                GeometryReader { g in
                    let f = a.ended ? 1 : max(0, min(1, 1 - Double(left) / Double(max(1, a.minutes))))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.line)
                        Rectangle().fill(color).frame(width: g.size.width * f)
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func menu(_ a: Adventure) -> some View {
        Menu {
            Button { showWorld = true } label: { Label("World, story and mission", systemImage: "globe") }
            Toggle(isOn: Binding(get: { engine.narrate }, set: { engine.narrate = $0; if !$0 { app.narrator.stop() } })) {
                Label("Read aloud", systemImage: "speaker.wave.2")
            }
            Button { app.narrator.stop() } label: { Label("Stop reading", systemImage: "speaker.slash") }
            ControlGroup {
                Button { textSize = max(12, textSize - 1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                    .disabled(textSize <= 12)
                Button { textSize = min(24, textSize + 1) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
                    .disabled(textSize >= 24)
            }
            Button { UIPasteboard.general.string = engine.storyText() } label: {
                Label("Copy story text", systemImage: "doc.on.doc")
            }
            .disabled(a.transcript.isEmpty)
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
            Image(systemName: "ellipsis.circle").font(.title3)
        }
    }

    // MARK: Transcript

    private func playerBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: textSize))
            .foregroundStyle(Theme.fg)
            .padding(10)
            .background(Theme.you, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 50)
    }

    private func transcript(_ a: Adventure) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(a.transcript) { t in
                        if t.role == .gm {
                            Text(t.text)
                                .font(storyFont)
                                .lineSpacing(2)
                                .foregroundStyle(Theme.fg)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                                .textSelection(.enabled)
                                .onTapGesture { toggleReading(t.text) }
                        } else {
                            playerBubble(t.text)
                        }
                    }
                    if let p = engine.pendingInput {
                        playerBubble(p).id("pending")
                    }
                    if !engine.streaming.isEmpty {
                        Text(engine.streaming)
                            .font(storyFont).lineSpacing(2).foregroundStyle(Theme.fg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                    } else if let since = engine.thinkingSince {
                        thinking(since)
                    } else if !engine.stage.isEmpty {
                        HStack(spacing: 10) { HoloCore(size: 30); Text(engine.stage).foregroundStyle(Theme.dim) }
                            .frame(maxWidth: .infinity)
                    }
                    if a.transcript.isEmpty && !engine.busy && engine.forge == nil {
                        Text("The story hasn't started yet. Go back and build it again.").foregroundStyle(Theme.dim).italic()
                            .frame(maxWidth: .infinity)
                    }
                    if a.ended && a.report != nil {
                        Button { showReport = true } label: {
                            Text("The adventure is complete. Tap here to see your report card.").italic()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if let e = engine.error {
                        Text(e).foregroundStyle(Theme.warn).font(.footnote)
                    }
                    if let e = app.narrator.lastError {
                        Text(e).foregroundStyle(Theme.warn).font(.footnote)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 60
            } action: { _, atBottom in
                nearBottom = atBottom
            }
            // Only the player's own scrolling changes whether we follow: new text growing the page must not.
            .onScrollPhaseChange { old, new in
                if new == .interacting { follow = false }
                if new == .idle, old == .interacting || old == .decelerating { follow = nearBottom }
            }
            .onChange(of: engine.streaming) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: a.transcript.count) {
                if a.transcript.last?.role != .gm { follow = true }   // the player just spoke: show what comes next
                if follow { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .onChange(of: engine.pendingInput) {
                if engine.pendingInput != nil { follow = true; withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .onChange(of: engine.thinkingSince) { if follow { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button {
                        follow = true
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.footnote.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.panel, in: Capsule())
                            .overlay(Capsule().stroke(Theme.line))
                    }
                    .padding(12)
                    .transition(.opacity)
                }
            }
        }
    }

    private var storyFont: Font { .system(size: textSize, design: .serif) }

    /// Tapping a passage reads it aloud; tapping while the voice is going stops it instead of restarting.
    private func toggleReading(_ text: String) {
        if app.narrator.speaking || app.narrator.preparing {
            app.narrator.stop()
        } else {
            app.narrator.speak(text)
        }
    }

    private func thinking(_ since: Date) -> some View {
        VStack(spacing: 8) {
            HoloCore(size: 64)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                // Names the step underway (the Game Master planning, then the storyteller writing).
                Text((engine.stage.isEmpty ? "The Phonodeck is thinking" : engine.stage) + "… \(Int(ctx.date.timeIntervalSince(since)))s")
                    .font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
            }
            // How far the Game Master's reasoning is toward its room to think.
            if let p = engine.thinkingProgress, engine.stage.hasPrefix("The Game Master") {
                ProgressView(value: p)
                    .tint(Theme.accent)
                    .frame(maxWidth: 220)
                    .animation(.easeOut(duration: 0.3), value: p)
                    .accessibilityLabel("Game Master reasoning")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Shown in place of the reply box while the storyteller is loaded back in for a saved story.
    private var resumingBar: some View {
        VStack(spacing: 8) {
            HoloCore(size: 64)
            Text("Getting caught up on your story…")
                .font(.footnote).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.bg.overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) })
        .accessibilityElement(children: .combine)
    }

    // MARK: Composer: the reply box, then Undo, Hands-free and Send

    private func composer(_ a: Adventure) -> some View {
        VStack(spacing: 8) {
            if engine.handsFree { handsFreeStatus }
            if let e = dictation.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
            TextField(engine.handsFree ? "Say \"\(Dictation.sendPhrase)\" to send" : "What do you do?", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            HStack(spacing: 8) {
                Button { engine.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 40)
                }
                .buttonStyle(.bordered)
                .disabled(!engine.canUndo)
                .accessibilityLabel("Undo last turn")
                handsFreeButton
                if engine.busy {
                    Button { engine.stopAll() } label: {
                        Text("Stop").bold().frame(minWidth: 70, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        typing = false
                        if dictation.listening { dictation.stop(send: true) } else { ComputerSounds.shared.play(.sent); engine.send(input) }
                        input = ""
                    } label: {
                        Text("Send").bold().frame(minWidth: 70, minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Theme.bg.overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) })
    }

    private var handsFreeButton: some View {
        HandsFreeButton(on: engine.handsFree, listening: dictation.listening) {
            typing = false
            engine.setHandsFree(!engine.handsFree)
        }
    }

    @ViewBuilder
    private var handsFreeStatus: some View {
        Group {
            if engine.busy && !app.narrator.playing {
                HStack(spacing: 8) { HoloCore(size: 22); Text("Hands-free ON: the story is being prepared…") }
            } else if (app.narrator.preparing || app.narrator.speaking) && !app.narrator.playing {
                HStack(spacing: 8) { HoloCore(size: 22); Text("Hands-free ON: getting the voice ready…") }
            } else if app.narrator.speaking || app.narrator.preparing {
                Text("Hands-free ON: narrator speaking (mic paused).")
            } else if dictation.listening {
                if dictation.transcribing {
                    Text("Hands-free ON: hearing you…")
                } else {
                    HStack(spacing: 4) {
                        Text("Hands-free ON: listening. Say")
                        MagicPhrase(phrase: Dictation.sendPhrase)
                        Text("to send.")
                    }
                }
            } else {
                Text("Hands-free ON: starting the microphone…")
            }
        }
        .font(.callout)
        .foregroundStyle(Theme.fg)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func endedBar(_ a: Adventure) -> some View {
        HStack {
            Button("Report card") {
                if a.report == nil { Task { await engine.writeReportCard() } } else { showReport = true }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(Theme.onAccent)
            Button("+10 min, keep going") { engine.addTime(10) }
                .buttonStyle(.bordered)
            Spacer()
            Button("Menu") { engine.close() }
        }
        .padding()
    }
}

struct ReportCardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let a = app.engine.adventure, let r = a.report {
                    VStack(alignment: .leading, spacing: 18) {
                        Caps(text: "Adventure complete", color: Theme.dim)
                        Text(r.title).font(.largeTitle.bold()).foregroundStyle(Theme.accent)
                        Text(r.summary).font(Theme.narration).foregroundStyle(Theme.fg)
                        gradeCard("How the Phonodeck did", sub: "The feeling: " + a.setup.feeling, r.storyteller)
                        gradeCard("How you did", sub: nil, r.player)
                        if !r.next.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Caps(text: "Next time")
                                Text(r.next).foregroundStyle(Theme.fg)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                        }
                        HStack {
                            Button("Read it to me") { app.narrator.speak(r.summary + " " + r.player.comment) }
                                .buttonStyle(.bordered)
                            Spacer()
                            Button("Menu") { dismiss(); app.engine.close() }
                                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                        }
                    }
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        HoloCore(size: 60)
                        Text("Writing your report card…").foregroundStyle(Theme.dim)
                    }
                    .padding(40)
                }
            }
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func gradeCard(_ title: String, sub: String?, _ g: Grade) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Caps(text: title)
            if let sub { Text(sub).font(.caption).foregroundStyle(Theme.dim) }
            HStack(alignment: .top, spacing: 16) {
                Text(g.grade)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 8)
                    .frame(minWidth: 70)
                Text(g.comment).font(.callout).foregroundStyle(Theme.fg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
}
