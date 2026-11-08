import Foundation

/// Recall: finds the memories that matter for what the player just said, from lore, older turns
/// and older chapter summaries, the way the web app's recall does (figure 3 of How the Phonodeck
/// Works). The web version merges a keyword search with a meaning search; on the phone only the
/// keyword search (BM25) runs, because a meaning search would need a second model loaded beside
/// the storyteller, and that memory isn't there. It is plain Swift on a few hundred short texts,
/// so it takes a few milliseconds and no GPU.
enum Recall {
    struct Doc {
        /// "L" lore, "T" an older turn, "C" an older chapter.
        var kind: Character
        var text: String
        var terms: [String]
    }

    private static let stop: Set<String> = Set("the and you was for that with this are his her they them have has had not but your from what who how into then there will would".split(separator: " ").map(String.init))

    static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { $0.count > 2 && !stop.contains($0) }
    }

    /// The `k` best documents for `query`, best first.
    static func bm25(_ docs: [Doc], query: String, k: Int) -> [Doc] {
        let q = Array(Set(tokens(query)))
        guard !docs.isEmpty, !q.isEmpty else { return [] }
        let avg = max(1, Double(docs.reduce(0) { $0 + $1.terms.count }) / Double(docs.count))
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d.terms) { df[t, default: 0] += 1 } }
        let n = Double(docs.count)
        var scored: [(Doc, Double)] = []
        for d in docs {
            var tf: [String: Int] = [:]
            for t in d.terms { tf[t, default: 0] += 1 }
            var s = 0.0
            for t in q {
                guard let f = tf[t].map(Double.init) else { continue }
                let dft = Double(df[t] ?? 0)
                let idf = log(1 + (n - dft + 0.5) / (dft + 0.5))
                s += idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * Double(d.terms.count) / avg))
            }
            if s > 0 { scored.append((d, s)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(k).map(\.0)
    }

    /// An old turn is recalled as its most relevant sentence or two, not the whole reply.
    static func brief(_ d: Doc, queryTerms: Set<String>) -> String {
        guard d.kind == "T", let colon = d.text.range(of: ": ") else { return d.text }
        let head = String(d.text[..<colon.lowerBound]) + ":"
        let body = String(d.text[colon.upperBound...])
        guard body.split(separator: " ").count > 60 else { return d.text }
        let sents = body.replacingOccurrences(of: #"([.!?…])\s+"#, with: "$1\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}").map(String.init)
        guard !sents.isEmpty else { return d.text }
        func hits(_ s: String) -> Int { tokens(s).filter { queryTerms.contains($0) }.count }
        var best = 0
        for (i, s) in sents.enumerated() where hits(s) > hits(sents[best]) { best = i }
        var pick = [sents[best]]
        if best + 1 < sents.count, (sents[best] + " " + sents[best + 1]).split(separator: " ").count <= 70 { pick.append(sents[best + 1]) }
        return head + " ..." + pick.joined(separator: " ") + "..."
    }

    /// Relevant memories for this turn, as briefing lines, within `budget` characters.
    /// `olderTurns` are the turns not already in the conversation the model sees, with their numbers.
    static func memories(for a: Adventure, input: String, olderTurns: [(Int, StoryTurn)], chaptersInPrompt: Int, budget: Int) -> [String] {
        guard budget > 200 else { return [] }
        func loreLine(_ e: LoreEntry) -> String {
            let label = e.kind == .person && !e.known && !e.role.isEmpty ? "\(e.name), known to the player only as \"\(e.role)\"" : e.name
            return "\(label) (\(e.kind.rawValue)): \(e.desc)" + (e.wants.isEmpty ? "" : " Wants: \(e.wants)")
        }
        let lore = a.lore.filter { !$0.isPlayer && !$0.byPlayer && !$0.desc.isEmpty }   // pinned entries are in the prompt already
        let said = input.lowercased()
        let named = lore.filter { e in
            let first = e.name.split(separator: " ").first.map { $0.lowercased() } ?? ""
            return said.contains(e.name.lowercased()) || (first.count > 3 && said.contains(first))
        }.map(loreLine)

        var docs: [Doc] = []
        for e in lore { docs.append(Doc(kind: "L", text: loreLine(e), terms: tokens(e.name + " " + e.role + " " + e.desc))) }
        for (n, t) in olderTurns {
            docs.append(Doc(kind: "T", text: "Turn \(n) " + (t.role == .player ? "player" : "story") + ": " + t.text, terms: tokens(t.text)))
        }
        for (i, c) in a.chapters.dropLast(chaptersInPrompt).enumerated() {
            docs.append(Doc(kind: "C", text: "Chapter \(i + 1): " + c, terms: tokens(c)))
        }
        // Short replies ("yes", "open it") need the end of the last reply to find the right memories.
        let lastGM = a.transcript.last { $0.role == .gm }?.text ?? ""
        let query = input + " " + String(lastGM.suffix(300))
        let qt = Set(tokens(query))
        let top = bm25(docs, query: query, k: 12).map { brief($0, queryTerms: qt) }.filter { !named.contains($0) }

        var out: [String] = []
        var room = budget
        for x in named + top {
            if !out.isEmpty && x.count > room { break }
            out.append(String(x.prefix(room)))
            room -= x.count
            if room <= 0 { break }
        }
        return out
    }
}
