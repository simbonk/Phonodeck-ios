import SwiftUI

/// Plain conversation with the on-device model, for trying it out: several chats you can
/// start, reopen and delete, and hands-free talk in the narrator voice from Settings.
struct ChatView: View {
    @Environment(AppModel.self) private var app
    @State private var input = ""
    @State private var showChats = false
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
            .navigationTitle(chat.current.turns.isEmpty ? "Chat" : chat.current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showChats = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Chats")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { input = ""; chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .disabled(chat.current.turns.isEmpty && !chat.generating)
                }
            }
            .sheet(isPresented: $showChats) { ChatList { input = "" } }
        }
        .onChange(of: dictation.text) { _, t in if dictation.listening, app.tab == .chat { input = t } }
        .onChange(of: chat.handsFree) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .onDisappear {
            // Leaving the tab hands the microphone and the narrator back to the story.
            if chat.handsFree { chat.setHandsFree(false) }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.current.turns.isEmpty && !chat.generating {
                            VStack(spacing: 6) {
                                Text("Ask anything. Everything stays on this phone.")
                                if let m = app.store.language { Text(m.name).font(.caption) }
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        }
                        ForEach(Array(chat.current.turns.enumerated()), id: \.offset) { _, turn in
                            bubble(turn.text, mine: turn.role == .user)
                        }
                        if chat.generating {
                            if chat.reply.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(app.llm.phase == .loading ? "Loading the model…" : "Thinking…").foregroundStyle(.secondary)
                                }
                            } else {
                                bubble(chat.reply, mine: false)
                            }
                        }
                        if let error = chat.error { Text(error).foregroundStyle(.red).font(.footnote) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .onChange(of: chat.reply) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: chat.current.turns.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            composer
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if chat.handsFree { handsFreeStatus }
            if let e = dictation.error { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
            TextField(chat.handsFree ? "Say \"\(Dictation.sendPhrase)\" to send" : "Message", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .focused($typing)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 8) {
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
                        if dictation.listening { dictation.stop(send: true) } else { chat.send(input) }
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
        .background(Theme.bg.overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) })
    }

    @ViewBuilder
    private var handsFreeStatus: some View {
        Group {
            if chat.generating {
                Text("Hands-free ON: thinking…")
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

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(LocalizedStringKey(text))
                .textSelection(.enabled)
                .padding(12)
                .background(mine ? Theme.accent.opacity(0.25) : Theme.card, in: RoundedRectangle(cornerRadius: 16))
            if !mine { Spacer(minLength: 40) }
        }
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
