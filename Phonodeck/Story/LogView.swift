import SwiftUI

/// The full trace, live, like a terminal: every model question and answer, what code worked out,
/// what was saved to cards and the map, and exactly what the storyteller was sent, each in its
/// own colour. Copy takes the whole log; Clear empties it and it starts again from now, while the
/// story keeps going.
struct LogView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var follow = true
    /// How many lines there were when you stopped following, so the live button shows what's new.
    @State private var seenCount = 0
    @State private var copied = false
    @State private var confirmClear = false
    /// Shown as a tab inside the story: copy and clear sit in a slim bar on top, no Done button.
    var embedded = false

    var body: some View {
        if embedded {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Text("live log").font(.system(.subheadline, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    copyButton
                    clearButton
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                feed
            }
            .background(Self.term)
            .confirmationDialog("Clear the log? The story keeps going; the log starts again from now.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear the log", role: .destructive) { app.engine.clearLog() }
            }
        } else {
            NavigationStack {
                feed
                    .navigationTitle("log")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(Self.term, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                        ToolbarItemGroup(placement: .primaryAction) { copyButton; clearButton }
                    }
                    .confirmationDialog("Clear the log? The story keeps going; the log starts again from now.", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear the log", role: .destructive) { app.engine.clearLog() }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = app.engine.storyText(prompts: true)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: { Text(copied ? "copied" : "copy").font(.system(.body, design: .monospaced)) }
    }

    private var clearButton: some View {
        Button(role: .destructive) { confirmClear = true } label: {
            Text("clear").font(.system(.body, design: .monospaced)).foregroundStyle(.red)
        }
    }

    private var feed: some View {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let lines = app.engine.liveLog()
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Self.colour(line.head))
                                    .fontWeight(Self.bold(line.text) ? .bold : .regular)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(8)
                    }
                    .background(Self.term)
                    // Touching the log to read it stops it following; it keeps filling in below.
                    .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in if follow { follow = false } })
                    .onChange(of: lines.count) { _, _ in
                        if follow { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .overlay(alignment: .bottom) {
                        if !follow {
                            Button {
                                follow = true
                                withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) }
                            } label: {
                                Text("▼ live  +\(max(0, lines.count - seenCount)) lines")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Color(red: 0.45, green: 0.95, blue: 0.45), in: Capsule())
                            }
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .onChange(of: follow) { _, on in if !on { seenCount = lines.count } }
                }
            }
            .background(Self.term)
    }

    static let term = Color(red: 0.05, green: 0.06, blue: 0.07)

    /// Terminal colours by what the line is.
    static func colour(_ line: String) -> Color {
        let l = line.trimmingCharacters(in: .whitespaces)
        func has(_ s: String) -> Bool { l.contains(s) }
        if l.hasPrefix("#") || l.hasPrefix("##") { return Color(red: 1.0, green: 0.62, blue: 0.2) }           // what you / the story said
        if l.hasPrefix("┌") || l.hasPrefix("└") { return .white }                                           // phases
        if has("🚩") { return Color(red: 1.0, green: 0.35, blue: 0.35) }                                      // flagged
        if has("🤖 MODEL ASKED") { return Color(red: 0.35, green: 0.85, blue: 1.0) }                          // model question
        if has("◀ ANSWER") { return Color(red: 0.45, green: 0.95, blue: 0.45) }                               // model answer
        if has("⚙") { return Color(red: 0.95, green: 0.9, blue: 0.35) }                                       // code
        if has("💾") { return Color(red: 0.95, green: 0.45, blue: 0.95) }                                     // saved to card
        if has("📍") { return Color(red: 0.45, green: 0.6, blue: 1.0) }                                       // map
        if has("📝") { return Color(red: 0.75, green: 0.75, blue: 0.75) }                                     // prompt sent
        if has("ℹ") { return Color(red: 0.6, green: 0.7, blue: 0.75) }                                        // notes
        return Color(red: 0.7, green: 0.72, blue: 0.7)
    }

    static func bold(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces)
        return l.hasPrefix("#") || l.hasPrefix("┌") || l.hasPrefix("└") || l.contains("🚩")
    }
}
