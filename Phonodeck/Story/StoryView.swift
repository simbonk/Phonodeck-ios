import SwiftUI
import UIKit

/// The story as it is told, with typing and hands-free play, laid out like the web app:
/// a timer pill, the World button, the transcript, and the composer with Hands-free.
struct StoryView: View {
    @Environment(AppModel.self) private var app
    @State private var input = ""
    @State private var actionInput = ""
    @State private var sayInput = ""
    /// Settings > Hands-free > Do, then say: keeps action and spoken dialogue cleanly separated.
    @AppStorage("doThenSay") private var doThenSay = true
    /// The story (the Phonodeck mark), the world (globe) and the live log, as three icons along the top.
    enum Tab: String, CaseIterable { case story, world, log }
    enum ComposerField: Hashable { case single, action, say }
    @State private var tab: Tab = .story
    /// The finished story the next part (Continue) is being set up from.
    @State private var continuing: Adventure?
    /// Keep the newest text in view. Off once the player scrolls up to read, back on when they return to the bottom.
    @State private var follow = true
    @State private var nearBottom = true
    /// Story text size in points. Defaults a little under body size so more of a passage fits on an iPhone.
    @AppStorage("storyTextSize") private var textSize: Double = 15
    @FocusState private var focused: ComposerField?

    private var engine: StoryEngine { app.engine }
    private var dictation: Dictation { app.dictation }

    var body: some View {
        if let a = engine.adventure {
            VStack(spacing: 0) {
                header(a)
                tabBar
                switch tab {
                case .story:
                    transcript(a)
                    if engine.resuming {
                        resumingBar
                    } else if a.ended {
                        endedBar(a)
                    } else {
                        composer(a)
                    }
                case .world:
                    WorldView(embedded: true)
                case .log:
                    LogView(embedded: true)
                }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .sheet(item: $continuing) { src in
                ContinueSheet(source: src) { link, hook, minutes in
                    continuing = nil
                    engine.continueStory(from: src, link: link, hook: hook, minutes: minutes)
                }
            }
            .sheet(isPresented: Binding(get: { engine.showSupport }, set: { engine.showSupport = $0 })) {
                SupportCard { engine.showSupport = false }
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: dictation.text) { _, t in if dictation.listening { input = t } }
            // The send phrase sent what was said: empty the box for the next turn.
            .onChange(of: dictation.sent) { input = "" }
        }
    }

    // MARK: Header: title, World and the menu

    private func header(_ a: Adventure) -> some View {
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
            menu(a)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Tabs: the story, the world, the live log

    /// SF Symbols for the world and the log; the story's tab is the Phonodeck mark itself.
    private func icon(_ t: Tab) -> String {
        switch t {
        case .story: return ""
        case .world: return "globe.americas"
        case .log: return "list.bullet.rectangle.portrait"
        }
    }
    private func title(_ t: Tab) -> String {
        switch t {
        case .story: return "Story"
        case .world: return "World"
        case .log: return "Live log"
        }
    }

    @Namespace private var tabMark

    /// Three icons along the top, the chosen one lit in the accent with a thin bar under it.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tab = t }
                    focused = nil
                } label: {
                    VStack(spacing: 5) {
                        Group {
                            if t == .story {
                                CoreMark(size: 22, color: tab == t ? Theme.accent : Theme.dim, lit: tab == t)
                                    .shadow(color: Theme.accent.opacity(tab == t ? 0.6 : 0), radius: 4)
                            } else {
                                Image(systemName: icon(t))
                                    .font(.system(size: 19, weight: tab == t ? .semibold : .regular))
                                    .symbolVariant(tab == t ? .fill : .none)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .frame(height: 24)
                        .foregroundStyle(tab == t ? Theme.accent : Theme.dim)
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 2.5)
                            if tab == t {
                                Capsule().fill(Theme.accent).frame(height: 2.5)
                                    .matchedGeometryEffect(id: "mark", in: tabMark)
                            }
                        }
                        .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(t))
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private func menu(_ a: Adventure) -> some View {
        Menu {
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
            Button { UIPasteboard.general.string = engine.dialogueText() } label: {
                Label("Copy story text", systemImage: "doc.on.doc")
            }
            .disabled(a.transcript.isEmpty)
            Button { engine.undo() } label: { Label("Undo last turn", systemImage: "arrow.uturn.backward") }
                .disabled(!engine.canUndo)
            if !a.ended {
                Button { engine.endNow() } label: { Label("Finish the experience now", systemImage: "flag.checkered") }
            }
            if a.ended {
                Button { continuing = a } label: { Label("Continue the story", systemImage: "arrow.right.circle") }
                    .disabled(engine.busy)
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
                    // Before the opening: the map is drawn first, and you watch it go up, piece by
                    // piece, with each question and answer under it.
                    // (The opening's room goes up on the build screen; the story itself stays clear of it.)
                    if engine.busy && engine.forge == nil && engine.stage.hasPrefix("Drawing") {
                        RoomMapView().id("opening-map")
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
                    if a.ended {
                        Button { continuing = a } label: {
                            Text("The adventure is complete. Tap Continue for the next part.").italic()
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
            .overlay(alignment: .bottom) {
                if !follow {
                    LatestButton {
                        follow = true
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    }
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

    // MARK: Composer: unified Action / Say card, Undo, Hands-free and Send

    private func composer(_ a: Adventure) -> some View {
        VStack(spacing: 8) {
            if engine.handsFree { handsFreeStatus }
            if let e = dictation.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
            if splitTyping {
                targetStrip(a)
                unifiedInputCard
            } else {
                TextField(engine.handsFree ? "Say \"\(Dictation.sendPhrase)\" to send" : "What do you do or say?", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused, equals: .single)
                    .submitLabel(.send)
                    .padding(12)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused == .single ? Theme.accent.opacity(0.6) : Theme.line))
                    .onChange(of: input) { _, v in
                        guard !engine.handsFree, v.contains("\n") else { return }
                        input = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                        sendSingle()
                    }
            }
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
                        if splitTyping {
                            sendSplit()
                        } else {
                            sendSingle()
                        }
                    } label: {
                        Text("Send").bold().frame(minWidth: 70, minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(splitTyping ? !hasSplitText : input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Theme.bg.overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) })
    }

    /// Subtle live strip above the composer showing who you're facing and letting you turn to
    /// anyone else in the room with a single tap.
    @ViewBuilder
    private func targetStrip(_ a: Adventure) -> some View {
        let here = a.whereabouts.filter { $0.here != false }
        if !here.isEmpty {
            let active = here.first { $0.engaged == true }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(here, id: \.name) { w in
                        let isActive = w.name == active?.name
                        let label: String = {
                            let shown = a.nameless ? Continuity.unnamed(w.name, in: a) : w.name
                            return shown.caseInsensitiveCompare(w.name) == .orderedSame ? Cards.first(w.name) : shown
                        }()
                        Button {
                            if !isActive {
                                let target = label.hasPrefix("The ") ? "the " + String(label.dropFirst(4)) : label
                                actionInput = "I turn to " + target
                            }
                            focused = .say
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(isActive ? Theme.accent : Theme.dim.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(isActive ? "With " + label : "Turn to " + label)
                                    .font(.caption.weight(isActive ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .foregroundStyle(isActive ? Theme.fg : Theme.dim)
                            .background(isActive ? Theme.accent.opacity(0.14) : Theme.panel, in: Capsule())
                            .overlay(Capsule().stroke(isActive ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                        .disabled(engine.busy)
                    }
                }
            }
        }
    }

    /// Calm, unified single-card composer with an optional Action line above the primary Say line:
    /// keeps physical action and spoken words cleanly separated for the on-device model while letting
    /// everyday conversation send in one tap with zero modal steps or distracting animations.
    private var unifiedInputCard: some View {
        let activeBorder = focused == .action || focused == .say
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(focused == .action || !actionInput.isEmpty ? Theme.accent : Theme.dim)
                    .frame(width: 16)
                TextField("Action, look, or movement (optional)", text: $actionInput, axis: .vertical)
                    .font(.subheadline)
                    .italic(!actionInput.isEmpty)
                    .lineLimit(1...3)
                    .focused($focused, equals: .action)
                    .submitLabel(.next)
                    .onChange(of: actionInput) { _, v in
                        guard v.contains("\n") else { return }
                        actionInput = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                        focused = .say
                    }
                if !actionInput.isEmpty {
                    Button { actionInput = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear action")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle()
                .fill(Theme.line.opacity(0.65))
                .frame(height: 0.5)
                .padding(.horizontal, 10)

            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(focused == .say || !sayInput.isEmpty ? Theme.accent : Theme.dim)
                    .frame(width: 16)
                TextField("Say something…", text: $sayInput, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...4)
                    .focused($focused, equals: .say)
                    .submitLabel(.send)
                    .onChange(of: sayInput) { _, v in
                        guard v.contains("\n") else { return }
                        sayInput = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                        sendSplit()
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(activeBorder ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: activeBorder ? 1.2 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: activeBorder)
    }

    /// Typed mode with Action + Say cleanly separated in one card (hands-free keeps its own voice chirps).
    private var splitTyping: Bool { doThenSay && !engine.handsFree }

    private var hasSplitText: Bool {
        !actionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !sayInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendSplit() {
        guard hasSplitText, !engine.busy else { return }
        ComputerSounds.shared.play(.sent)
        focused = nil
        let act = actionInput
        let words = sayInput
        actionInput = ""
        sayInput = ""
        engine.send(did: act, said: words)
    }

    private func sendSingle() {
        focused = nil
        if dictation.listening {
            dictation.stop(send: true)
        } else {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !engine.busy else { return }
            ComputerSounds.shared.play(.sent)
            engine.send(trimmed)
        }
        input = ""
    }

    private var handsFreeButton: some View {
        HandsFreeButton(on: engine.handsFree, listening: dictation.listening) {
            focused = nil
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
                        if StoryEngine.doThenSay {
                            Text(engine.saying ? "Now what you say. Then" : "What you do. Then")
                        } else {
                            Text("Hands-free ON: listening. Say")
                        }
                        MagicPhrase(phrase: Dictation.sendPhrase)
                        Text(StoryEngine.doThenSay ? "(or \"nothing\")." : "to send.")
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
        // One button: Continue sets up the next part, linked to this one, at whatever length you pick.
        Button { continuing = a } label: {
            Label("Continue", systemImage: "arrow.right")
                .bold().lineLimit(1).frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .foregroundStyle(Theme.onAccent)
        .disabled(engine.busy)
        .accessibilityHint("Starts the next part of the story with the same cast and world")
        .padding(12)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Theme.bg.overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) })
    }
}

/// Shown when the player writes something that sounds like they may want to hurt themselves.
/// Gentle and brief: the crisis line, a way to the support page, and back to the story.
private struct SupportCard: View {
    var done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Something you wrote sounded like it might be about you, not just the story. If you're having thoughts of hurting yourself, you don't have to handle them alone.")
                    CrisisLine()
                } header: {
                    Text("Are you okay?")
                }
                Section {
                    NavigationLink("Take a break and find support") { SupportView() }
                    Button("I'm okay, back to the story") { done() }
                }
            }
            .navigationTitle("A quick check-in")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
