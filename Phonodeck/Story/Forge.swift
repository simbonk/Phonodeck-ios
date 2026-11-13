import Foundation
import Observation
import SwiftUI

/// The build screen between "Build my world" and the opening scene, as in the web app.
///
/// The architect's reply is one JSON object written in a fixed order (see `Prompts.architect`)
/// and it is streamed, so each stage lights up when the model really starts writing that part.
/// The screen shows each stage for at least a couple of seconds, catching up on stages already
/// reached, and never runs ahead of the real progress.
@Observable
@MainActor
final class Forge {
    struct Stage {
        let title: String
        let keys: [String]
        let why: String
    }

    /// The build: no hidden plot, no paced roadmap, a short premise. The world
    /// is built as you go.
    static let stages: [Stage] = [
        Stage(title: "Reading your wishes", keys: [], why: ""),
        Stage(title: "Building the story", keys: ["title", "bible"], why: "What this story is, in a few lines."),
        Stage(title: "Mapping the world", keys: ["location", "places"], why: "Where you begin."),
        Stage(title: "Establishing characters and lore", keys: ["player", "lore"], why: "A world that remembers everyone you meet."),
        Stage(title: "Setting the scene", keys: ["facts", "time", "timeline", "people", "scene", "things"], why: "Who is where, and what is around you."),
        Stage(title: "Raising the curtain", keys: [], why: "Your opening scene is being written."),
    ]

    var stages: [Stage] { Self.stages }
    /// An experience lives in one place: the map shows only that, whatever else the model listed.
    private let onePlace: Bool

    /// The long first wait cycles through these.
    static let waitingLines = [
        "Waking the storyteller on this device.", "Your feeling becomes the goal of everything that follows.",
        "Every answer you gave is shaping this world.", "No two worlds are ever the same.",
        "Somewhere, a stranger is getting a name.", "Choosing where your story begins.",
        "Every character will want something.", "Hiding a few surprises for later.",
        "Picking the sounds and smells of this place.", "Making room for you to wander off the path.",
        "Planning an ending worth reaching.", "Everything happens on this device. Nothing leaves it.",
    ]

    let name: String
    let started = Date()
    private(set) var at = 0
    private(set) var finds: [Int: String] = [:]
    private(set) var finished = false
    private var target = 0
    private var shownAt = Date()
    private var stepper: Task<Void, Never>?
    private var closing = false
    private var raw = ""
    private let lines: [String]

    init(name: String, curated: Bool, onePlace: Bool = false) {
        self.name = name
        self.onePlace = onePlace
        var l = Self.waitingLines
        if curated { l.insert("This world was curated for you. Next time, try building one yourself.", at: 3) }
        lines = l
    }

    var fraction: Double { (Double(at) + 0.5) / Double(self.stages.count) }

    func line(at date: Date) -> String {
        if at == 0 {
            let i = Int(date.timeIntervalSince(started) / 4) % lines.count
            return lines[i]
        }
        return self.stages[at].why
    }

    /// A piece of the architect's streamed reply.
    func feed(_ piece: String) {
        raw += piece
        var reached = 1
        for (i, s) in self.stages.enumerated() where !s.keys.isEmpty {
            if s.keys.contains(where: { raw.contains("\"\($0)\"") }) { reached = max(reached, i) }
        }
        reach(reached)
        updateFinds()
    }

    func reach(_ k: Int) {
        guard k > target else { return }
        target = min(k, self.stages.count - 1)
        step()
    }

    /// The story is ready: walk the remaining stages quickly, then fade.
    func close() {
        closing = true
        target = self.stages.count - 1
        step()
    }

    /// Gone at once (after an error or a cancel).
    func abort() {
        stepper?.cancel()
        finished = true
    }

    private func step() {
        guard stepper == nil else { return }
        stepper = Task { [weak self] in
            while let self, self.at < self.target, !Task.isCancelled {
                let dwell = self.closing ? 0.65 : 2.0
                let wait = dwell - Date().timeIntervalSince(self.shownAt)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                withAnimation(.easeInOut(duration: 0.4)) { self.at += 1 }
                self.shownAt = Date()
            }
            guard let self else { return }
            self.stepper = nil
            if self.closing && self.at == self.stages.count - 1 {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.6)) { self.finished = true }
            }
        }
    }

    /// What has been made so far: counts and the opening place, never the secrets themselves.
    private func updateFinds() {
        func section(_ key: String) -> String? {
            guard let r = raw.range(of: "\"\(key)\"") else { return nil }
            let rest = raw[r.upperBound...]
            let allKeys = self.stages.flatMap(\.keys)
            var end = rest.endIndex
            for k in allKeys where k != key {
                if let n = rest.range(of: "\"\(k)\""), n.lowerBound < end { end = n.lowerBound }
            }
            return String(rest[..<end])
        }
        func count(_ key: String, _ field: String) -> Int {
            (section(key)?.components(separatedBy: "\"\(field)\"").count ?? 1) - 1
        }
        func firstString(_ key: String) -> String? {
            guard let s = section(key), let m = s.range(of: #":\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) else { return nil }
            let inner = s[m].drop { $0 != "\"" }.dropFirst().dropLast()
            return inner.isEmpty ? nil : String(inner)
        }
        func plural(_ n: Int, _ one: String, _ many: String) -> String? { n > 0 ? "\(n) " + (n == 1 ? one : many) : nil }
        let people = section("lore")?.components(separatedBy: "\"person\"").count ?? 1
        finds[2] = [firstString("location").map { "You begin at " + $0 }, onePlace ? nil : plural(count("places", "name"), "place on the map", "places on the map")]
            .compactMap { $0 }.joined(separator: " · ")
        finds[3] = [firstString("player").map { "You are " + $0 }, plural(people - 1, "character with a life of their own", "characters with lives of their own")]
            .compactMap { $0 }.joined(separator: " · ")
        finds[4] = firstString("time") ?? ""
    }
}

struct ForgeView: View {
    let forge: Forge
    var onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HoloCore(size: 120).padding(.top, 30)
                Caps(text: "Building your world", color: Theme.dim).tracking(3).padding(.top, 22)
                Materialize(text: forge.name, font: .system(size: 26, weight: .semibold), color: Theme.fg)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                ShimmerBar(fraction: forge.fraction).padding(.vertical, 20)
                steps
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("\(Int(ctx.date.timeIntervalSince(forge.started)))s")
                        .font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
                }
                .padding(.top, 6)
                Button("Cancel", role: .cancel, action: onCancel)
                    .font(.footnote).foregroundStyle(Theme.dim).padding(.top, 20)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .opacity(forge.finished ? 0 : 1)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(forge.stages.enumerated()), id: \.offset) { i, s in
                let done = i < forge.at, now = i == forge.at
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(done ? Theme.accent : Color.clear)
                            .overlay(Circle().stroke(done || now ? Theme.accent : Theme.line, lineWidth: 2))
                            .frame(width: 14, height: 14)
                            .padding(.top, 5)
                            .modifier(Ping(active: now))
                        if i < forge.stages.count - 1 {
                            Rectangle().fill(done ? Theme.accent.opacity(0.55) : Theme.line).frame(width: 2).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        if now {
                            Materialize(text: s.title, font: .title3.weight(.semibold), color: Theme.accent)
                                .shadow(color: Theme.accent.opacity(0.5), radius: 8)
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Materialize(text: forge.line(at: ctx.date), font: .subheadline, color: Theme.fg.opacity(0.85))
                            }
                        } else {
                            Text(s.title).font(.body.weight(done ? .regular : .semibold)).foregroundStyle(done ? Theme.fg : Theme.dim)
                        }
                        if let f = forge.finds[i], !f.isEmpty, i <= forge.at {
                            Materialize(text: f, font: .footnote, color: Theme.accent)
                        }
                    }
                    .padding(.bottom, 16)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// The ring that pings out from the current stage's dot.
private struct Ping: ViewModifier {
    var active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content.overlay {
                TimelineView(.animation) { ctx in
                    let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Circle().stroke(Theme.accent.opacity(0.7 * (1 - p)), lineWidth: 2).scaleEffect(1 + p * 1.7)
                }
            }
        } else {
            content
        }
    }
}
