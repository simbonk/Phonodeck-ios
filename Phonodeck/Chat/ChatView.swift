import SwiftUI

/// Plain conversation with the on-device model.
struct ChatView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("chatSystem") private var chatSystem = ""
    @State private var input = ""
    @State private var reply = ""
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    private var generating: Bool { task != nil }

    var body: some View {
        NavigationStack {
            Group {
                if !app.store.hasLanguageModel {
                    NeedsModelBanner()
                } else {
                    conversation
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { stop(); app.library.chat = [] }
                        .disabled(app.library.chat.isEmpty || generating)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let m = app.store.language { Text(m.name).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if app.library.chat.isEmpty && !generating {
                            Text("Ask anything. Everything stays on this phone.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(Array(app.library.chat.enumerated()), id: \.offset) { _, turn in
                            bubble(turn.text, mine: turn.role == .user)
                        }
                        if generating {
                            if reply.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(app.llm.phase == .loading ? "Loading the model…" : "Thinking…").foregroundStyle(.secondary)
                                }
                            } else {
                                bubble(reply, mine: false)
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .onChange(of: reply) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: app.library.chat.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                if generating {
                    Button { stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(10)
        }
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

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        error = nil
        app.library.chat.append(ChatTurn(role: .user, text: text))
        let history = Array(app.library.chat.suffix(16))
        reply = ""
        task = Task {
            do {
                let system = chatSystem.isEmpty ? "You are a helpful, friendly assistant running privately on the user's iPhone. Be concise." : chatSystem
                for try await piece in app.llm.stream(system: system, history: history, options: .init(maxTokens: 900, temperature: 0.7)) {
                    reply += piece
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            let done = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !done.isEmpty { app.library.chat.append(ChatTurn(role: .assistant, text: done)) }
            reply = ""
            task = nil
        }
    }

    private func stop() {
        task?.cancel()
    }
}
