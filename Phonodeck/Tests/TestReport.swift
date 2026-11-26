import Foundation

/// The morning report: failures grouped by the check and the model question behind them, with
/// counts, a few one-line examples and one or two full traces each, and the pass rates compared
/// with the run before, so a fix (or a big change) shows at once what got better or worse.
@MainActor
enum TestReport {
    struct Summary: Codable {
        var date: Date
        var blocks: Int
        var turns: Int
        /// Check name → [passed, total].
        var checks: [String: [Int]]
    }

    @discardableResult
    static func write(folder: URL, began: Date, blocks: Int, turns: Int) -> URL? {
        guard let data = try? String(contentsOf: folder.appending(path: "results.jsonl"), encoding: .utf8) else { return nil }
        let dec = JSONDecoder()
        let results: [TestRunner.Result] = data.split(separator: "\n").compactMap { try? dec.decode(TestRunner.Result.self, from: Data($0.utf8)) }
        let fails = results.filter { !$0.pass }

        var checks: [String: [Int]] = [:]
        for r in results {
            var c = checks[r.check, default: [0, 0]]
            if r.pass { c[0] += 1 }
            c[1] += 1
            checks[r.check] = c
        }
        let summary = Summary(date: Date(), blocks: blocks, turns: turns, checks: checks)
        let previous = previousSummary(before: folder)

        var out: [String] = []
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        let hours = Date().timeIntervalSince(began) / 3600
        out.append("# Phonodeck overnight tests")
        out.append("")
        out.append("\(df.string(from: began)), \(String(format: "%.1f", hours)) hours. \(blocks) blocks, \(turns) turns, \(results.count) checks: \(results.count - fails.count) passed, \(fails.count) failed (\(pct(results.count - fails.count, results.count))).")
        if turns > 0 { out.append(String(format: "About %.0f seconds a turn.", Date().timeIntervalSince(began) / Double(turns))) }
        out.append("")

        // The checks that should always pass (the reply is there, no metres, you're on the map...)
        // are counted apart, so they don't make the pass rate look better than the play was.
        let scenarioResults = results.filter { !alwaysPass.contains($0.check) && !$0.check.hasPrefix("build-") }
        let coreResults = results.filter { alwaysPass.contains($0.check) || $0.check.hasPrefix("build-") }
        out.append("**Scenario checks: \(pct(scenarioResults.filter(\.pass).count, scenarioResults.count)) passed** (\(scenarioResults.filter(\.pass).count) of \(scenarioResults.count)). These are the ones that matter.")
        out.append("")
        var bySet: [String: [Int]] = [:]
        for r in scenarioResults {
            var c = bySet[TestScenarios.set(of: r.scenario), default: [0, 0]]
            if r.pass { c[0] += 1 }
            c[1] += 1
            bySet[TestScenarios.set(of: r.scenario)] = c
        }
        out.append("By set: " + bySet.sorted { $0.key < $1.key }.map { "\($0.key) \(pct($0.value[0], $0.value[1])) of \($0.value[1])" }.joined(separator: ", "))
        let coreFails = coreResults.filter { !$0.pass }.count
        out.append("Always-pass checks: \(coreResults.count - coreFails) of \(coreResults.count)" + (coreFails == 0 ? ", all passed." : ", \(coreFails) failed (listed below)."))
        let inputs = results.compactMap(\.input).filter { !$0.isEmpty }
        var seenTurns = Set<String>()
        var turnsPlayed = 0
        for r in results where r.check == "replied" { turnsPlayed += 1; if let i = r.input { seenTurns.insert(i) } }
        if !inputs.isEmpty { out.append("Variety: \(seenTurns.count) different turns out of \(turnsPlayed) played.") }
        // Code alone, no model: how answers written every which way are read, and what the player
        // picks up. Run fresh here, so a run on a release build reports them too.
        PickUpChecks.run()
        ReadChecks.run()
        let codeFails = PickUpChecks.failures + ReadChecks.failures
        out.append("Code checks (no model): " + (codeFails.isEmpty ? "all \(ReadChecks.count) reading checks and the pick-up checks passed." : "**\(codeFails.count) failed.**"))
        for f in codeFails { out.append("- " + f) }
        out.append("")

        // What broke, by cause.
        var groups: [String: [TestRunner.Result]] = [:]
        for f in fails { groups[f.check + "|" + f.step, default: []].append(f) }
        let ordered = groups.sorted { $0.value.count > $1.value.count }
        out.append("## Failures by cause")
        out.append("")
        if ordered.isEmpty { out.append("None.") }
        for (i, (key, list)) in ordered.enumerated() {
            let parts = key.components(separatedBy: "|")
            let total = checks[parts[0]]?[1] ?? list.count
            out.append("### \(i + 1). \(parts[0]): \(list.count) of \(total) failed" + (parts.count > 1 && !parts[1].isEmpty ? " (question: \(parts[1]))" : ""))
            out.append("")
            out.append("Wanted: " + (list.first?.expected ?? ""))
            var byStory: [String: Int] = [:]
            for r in list { byStory[r.story, default: 0] += 1 }
            out.append("By story: " + byStory.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            var byScenario: [String: Int] = [:]
            for r in list { byScenario[r.scenario, default: 0] += 1 }
            out.append("By scenario: " + byScenario.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            out.append("")
            out.append("```")
            for r in list.prefix(4) { out.append(r.line) }
            out.append("```")
            out.append("")
        }

        // Every check's pass rate, against the last run.
        out.append("## Pass rates" + (previous == nil ? "" : " (last run in brackets)"))
        out.append("")
        out.append("| Check | Passed | Rate |" + (previous == nil ? "" : " Last run | Change |"))
        out.append("|---|---|---|" + (previous == nil ? "" : "---|---|"))
        var worse: [String] = []
        for (name, c) in checks.sorted(by: { rate($0.value) < rate($1.value) }) {
            var row = "| \(name) | \(c[0]) of \(c[1]) | \(pct(c[0], c[1])) |"
            if let p = previous?.checks[name], p[1] > 0 {
                let d = (rate(c) - rate(p)) * 100
                row += " \(pct(p[0], p[1])) | " + (abs(d) < 3 ? "same" : String(format: "%+.0f pts", d)) + " |"
                if d <= -5 && c[1] >= 10 { worse.append(name + String(format: " (%+.0f pts)", d)) }
            } else if previous != nil { row += " new | |" }
            out.append(row)
        }
        out.append("")
        if previous != nil {
            out.append(worse.isEmpty ? "Nothing got worse than the last run by 5 points or more." : "**Worse than the last run:** " + worse.joined(separator: ", "))
            out.append("")
        }

        // The full traces kept for each cause.
        let traceDir = folder.appending(path: "traces")
        let files = ((try? FileManager.default.contentsOfDirectory(at: traceDir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !files.isEmpty {
            out.append("## Full traces (one or two for each cause)")
            out.append("")
            for (key, _) in ordered {
                let prefix = safe(key)
                for f in files where f.lastPathComponent.hasPrefix(prefix + "-") {
                    guard let t = try? String(contentsOf: f, encoding: .utf8) else { continue }
                    out.append("````")
                    out.append(t.count > 7000 ? String(t.prefix(7000)) + "\n…(cut)" : t)
                    out.append("````")
                    out.append("")
                }
            }
        }

        let url = folder.appending(path: "report.md")
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(summary) { try? d.write(to: folder.appending(path: "summary.json")) }
        // The one-line results, as plain text too.
        try? results.map(\.line).joined(separator: "\n").write(to: folder.appending(path: "results.txt"), atomically: true, encoding: .utf8)
        return url
    }

    /// The summary of the newest earlier run that has one.
    static func previousSummary(before folder: URL) -> Summary? {
        let all = (try? FileManager.default.contentsOfDirectory(at: TestRunner.testsFolder, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        for f in all.filter({ $0.lastPathComponent < folder.lastPathComponent }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            if let d = try? Data(contentsOf: f.appending(path: "summary.json")), let s = try? dec.decode(Summary.self, from: d), s.turns >= 10 { return s }
        }
        return nil
    }

    /// Checks that should pass every time: counted apart from the scenario checks.
    static let alwaysPass: Set<String> = ["replied", "no-metres", "no-prompt-echo", "player-on-map", "map-people-have-cards",
                                          "clock-forward", "clock-sane", "full-sentence"]

    static func rate(_ c: [Int]) -> Double { c[1] == 0 ? 0 : Double(c[0]) / Double(c[1]) }
    static func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", Double(a) / Double(b) * 100) }
    static func safe(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(60))
    }
}
