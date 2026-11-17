import SwiftUI

/// Plain conversation with the on-device model: several chats you can start, reopen and delete,
/// replies read aloud (tap one to hear it again, tap again to stop), and hands-free talk.
/// Text size and reading aloud are shared with the Phonodeck.
struct ChatView: View {
    @Environment(AppModel.self) private var app
    @State private var input = ""
    @State private var showChats = false
    @State private var editingInstructions = false
    /// Keep the newest text in view. Off once you scroll up to read, back on when you return to the bottom.
    @State private var follow = true
    @State private var nearBottom = true
    @AppStorage(Reading.textSizeKey) private var textSize: Double = Reading.defaultTextSize
    @FocusState private var typing: Bool

    private var chat: ChatEngine { app.chat }
    private var dictation: Dictation { app.dictation }

    var body: some View {
        NavigationStack {
            Group {
                if !app.store.hasLanguageModel {
                    NeedsModelBanner()
                } else {
                    conversation
                }
            }
            .background(Theme.bg)
            .navigationTitle(chat.current.turns.isEmpty ? "Chat" : chat.current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showChats = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Chats")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { input = ""; chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .disabled(chat.current.turns.isEmpty && !chat.generating)
                    menu
                }
            }
            .sheet(isPresented: $showChats) { ChatList { input = "" } }
            .sheet(isPresented: $editingInstructions) { ChatInstructions() }
        }
        .onChange(of: dictation.text) { _, t in if dictation.listening, app.tab == .chat { input = t } }
        .onChange(of: dictation.sent) { if app.tab == .chat { input = "" } }
        .onDisappear {
            // Leaving the tab hands the microphone and the narrator back to the story.
            if chat.handsFree { chat.setHandsFree(false) }
            chat.stopReading()
        }
    }

    // MARK: The ... menu

    private var menu: some View {
        Menu {
            Toggle(isOn: Binding(get: { app.engine.narrate }, set: { on in
                app.engine.narrate = on
                if !on { chat.stopReading() }
            })) {
                Label("Read replies aloud", systemImage: "speaker.wave.2")
            }
            if chat.reading {
                Button { chat.stopReading() } label: { Label("Stop reading", systemImage: "speaker.slash") }
            }
            ControlGroup {
                Button { textSize = max(Reading.minTextSize, textSize - 1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                    .disabled(textSize <= Reading.minTextSize)
                Button { textSize = min(Reading.maxTextSize, textSize + 1) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
                    .disabled(textSize >= Reading.maxTextSize)
            }
            Section {
                Button { editingInstructions = true } label: { Label("Instructions for the assistant", systemImage: "text.badge.star") }
                Button { UIPasteboard.general.string = transcriptText } label: { Label("Copy chat", systemImage: "doc.on.doc") }
                    .disabled(chat.current.turns.isEmpty)
                Button(role: .destructive) { input = ""; chat.delete(chat.current) } label: { Label("Delete this chat", systemImage: "trash") }
                    .disabled(chat.current.turns.isEmpty)
            }
            Section {
                Button { app.openModels(.thinking) } label: {
                    Label("Model: \(app.store.language?.name ?? "none")", systemImage: "brain")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Chat options")
    }

    private var transcriptText: String {
        chat.current.turns.map { ($0.role == .user ? "You: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.current.turns.isEmpty && !chat.generating {
                            emptyState
                        }
                        ForEach(Array(chat.current.turns.enumerated()), id: \.offset) { _, turn in
                            bubble(turn.text, mine: turn.role == .user)
                        }
                        if chat.generating {
                            if chat.reply.isEmpty {
                                HStack(spacing: 10) {
                                    HoloCore(size: 34)
                                    Text(app.llm.phase == .loading ? "Loading the model…" : "Thinking…").foregroundStyle(Theme.dim)
                                }
                            } else {
                                bubble(chat.reply, mine: false, live: true)
                            }
                        }
                        if let error = chat.error { Text(error).foregroundStyle(Theme.warn).font(.footnote) }
                        if let e = app.narrator.lastError, chat.reading || chat.handsFree {
                            Text(e).foregroundStyle(Theme.warn).font(.footnote)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 60
                } action: { _, atBottom in
                    nearBottom = atBottom
                }
                // Only your own scrolling changes whether the chat follows: new text growing the page must not.
                .onScrollPhaseChange { old, new in
                    if new == .interacting { follow = false }
                    if new == .idle, old == .interacting || old == .decelerating { follow = nearBottom }
                }
                .onChange(of: chat.reply) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: chat.current.turns.count) {
                    if chat.current.turns.last?.role == .user { follow = true }   // you just sent: show the answer
                    if follow { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                }
                .onChange(of: chat.current.id) { follow = true; proxy.scrollTo("end", anchor: .bottom) }
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
            composer
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Ask anything. Everything stays on this \(DeviceFit.deviceWord).")
            if let m = app.store.language { Text(m.name).font(.caption) }
            Text(app.engine.narrate ? "Replies are read aloud. Tap a reply to stop or hear it again." : "Tap a reply to hear it read aloud.")
                .font(.caption)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.dim)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if chat.handsFree { handsFreeStatus }
            if let e = dictation.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
            TextField(chat.handsFree ? "Say \"\(Dictation.sendPhrase)\" to send" : "Message", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .focused($typing)
                .padding(10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            HStack(spacing: 8) {
                if chat.reading && !chat.generating {
                    Button { chat.stopReading() } label: {
                        Image(systemName: "speaker.slash.fill").frame(width: 44, height: 40)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop reading")
                }
                HandsFreeButton(on: chat.handsFree, listening: dictation.listening) {
                    typing = false
                    if !chat.handsFree { app.engine.setHandsFree(false) }
                    chat.setHandsFree(!chat.handsFree)
                }
                if chat.generating {
                    Button { chat.stopAll() } label: {
                        Text("Stop").bold().frame(minWidth: 70, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        typing = false
                        if dictation.listening { dictation.stop(send: true) } else { ComputerSounds.shared.play(.sent); chat.send(input) }
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

    @ViewBuilder
    private var handsFreeStatus: some View {
        Group {
            if chat.generating {
                HStack(spacing: 8) { HoloCore(size: 22); Text("Hands-free ON: thinking…") }
            } else if (app.narrator.preparing || app.narrator.speaking) && !app.narrator.playing {
                HStack(spacing: 8) { HoloCore(size: 22); Text("Hands-free ON: getting the voice ready…") }
            } else if app.narrator.speaking || app.narrator.preparing {
                Text("Hands-free ON: speaking (mic paused).")
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

    /// A message. Tapping a reply reads it aloud; tapping while it is being read stops it.
    private func bubble(_ text: String, mine: Bool, live: Bool = false) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(LocalizedStringKey(text))
                .font(.system(size: textSize))
                .foregroundStyle(Theme.fg)
                .textSelection(.enabled)
                .padding(12)
                .background(mine ? Theme.you : Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay { if !mine { RoundedRectangle(cornerRadius: 14).stroke(Theme.line) } }
                .onTapGesture { if !mine && !live { chat.toggleReading(text) } }
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// Standing instructions for the Chat tab's assistant (a system prompt), e.g. a persona or a language.
private struct ChatInstructions: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Reading.chatInstructionsKey) private var instructions = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("For example: answer in French, or be a patient tutor", text: $instructions, axis: .vertical)
                        .lineLimit(4...12)
                } footer: {
                    Text("Used in every chat in place of the default (\"a helpful, friendly assistant… be concise\"). Leave it empty for the default.")
                }
                if !instructions.isEmpty {
                    Button("Clear", role: .destructive) { instructions = "" }
                }
            }
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Past chats: tap one to open it, swipe to delete, or start a new one.
private struct ChatList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Called when the open chat changes, so the half-typed message is cleared.
    let switched: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    app.chat.newChat()
                    switched()
                    dismiss()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                if app.library.chats.isEmpty {
                    Text("No saved chats yet.").foregroundStyle(.secondary)
                }
                ForEach(app.library.chats) { c in
                    Button {
                        if c.id != app.chat.current.id { app.chat.open(c); switched() }
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).foregroundStyle(Theme.fg).lineLimit(2)
                            Text("\(c.turns.count) messages · \(c.updated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(c.id == app.chat.current.id ? Theme.accent.opacity(0.15) : nil)
                    .swipeActions {
                        Button(role: .destructive) { app.chat.delete(c) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button(role: .destructive) { app.chat.delete(c) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
