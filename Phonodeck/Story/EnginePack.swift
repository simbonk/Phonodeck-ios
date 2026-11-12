import Foundation
import JavaScriptCore
import SwiftUI

/// The engine file: a JavaScript file the app downloads (by default from
/// phonodeck.vercel.app/engine) only when the player asks, and runs in JavaScriptCore, the phone's built-in JavaScript, so
/// the engine can change without a rebuild. Each download that differs from the last is kept as a
/// new version (V1, V2, ...), and any version, or the engine built into the app, can be put back.
///
/// The file defines one object:
///     var PhonodeckEngine = { version: "2", build: "...", notes: "...",
///                             prompts: { planQuestion: `...`, ... }, testScripts: `...` }
/// A prompt the file leaves out keeps the app's built-in text, so a file can hold only what is
/// being tuned. The script sees nothing but this context: no network, no files.
/// For now the prompts and test scripts come from the file; the turn itself moves over in stages.
final class EnginePack: @unchecked Sendable {
    static let shared = EnginePack()
    static let defaultURL = "https://phonodeck.vercel.app/engine"

    private let lock = NSLock()
    private var texts: [String: String] = [:]
    private var tests: String?
    private var label = "built-in"

    /// The text in use for `key`: the active file's prompt, or the built-in text.
    static func text(_ key: String, _ builtIn: String) -> String {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.texts[key] ?? builtIn
    }

    /// The test scripts in use.
    static var testScripts: String {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.tests ?? PlayScripts.starterText
    }

    /// "engine V3 (file 2)", or "engine built-in", for the build line and digests.
    static var label: String {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return "engine " + shared.label
    }

    // MARK: Reading a file

    struct Parsed {
        var version = "?"
        var build = ""
        var notes = ""
        var prompts: [String: String] = [:]
        var testScripts: String?
        var error: String?
    }

    /// Files that ran too long once are never run again (by their text).
    private static var stuck = Set<Int>()
    private static let stuckLock = NSLock()

    /// Runs the file in a fresh JavaScriptCore context and reads `PhonodeckEngine` from it. A file
    /// that doesn't finish within a few seconds (an endless loop) is given up on instead of freezing
    /// the app, and never run again.
    static func parse(_ source: String) -> Parsed {
        let key = source.hashValue
        stuckLock.lock(); let known = stuck.contains(key); stuckLock.unlock()
        if known { var p = Parsed(); p.error = "it ran too long and was stopped."; return p }
        var result: Parsed?
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            result = evaluate(source)
            done.signal()
        }
        worker.stackSize = 4 << 20
        worker.start()
        if done.wait(timeout: .now() + 4) == .timedOut {
            stuckLock.lock(); stuck.insert(key); stuckLock.unlock()
            var p = Parsed(); p.error = "it ran too long and was stopped."; return p
        }
        return result ?? Parsed()
    }

    private static func evaluate(_ source: String) -> Parsed {
        var p = Parsed()
        guard let ctx = JSContext() else { p.error = "JavaScript isn't available."; return p }
        var thrown: String?
        ctx.exceptionHandler = { _, e in
            let line = e?.objectForKeyedSubscript("line").map { $0.isUndefined ? "" : "line " + $0.toString() + ": " } ?? ""
            thrown = line + (e?.toString() ?? "error")
        }
        ctx.evaluateScript(source)
        if let thrown { p.error = thrown; return p }
        guard let eng = ctx.objectForKeyedSubscript("PhonodeckEngine"), eng.isObject else { p.error = "The file doesn't define PhonodeckEngine."; return p }
        func str(_ k: String) -> String? {
            guard let v = eng.objectForKeyedSubscript(k), v.isString || v.isNumber else { return nil }
            return v.toString()
        }
        p.version = str("version") ?? "?"
        p.build = str("build") ?? ""
        p.notes = str("notes") ?? ""
        if let t = eng.objectForKeyedSubscript("testScripts"), t.isString { p.testScripts = t.toString() }
        if let d = eng.objectForKeyedSubscript("prompts")?.toDictionary() {
            for (k, v) in d {
                if let k = k as? String, let v = v as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    p.prompts[k] = v.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return p
    }

    static var knownPrompts: Set<String> { Set(Prompts.builtIns.map(\.0)) }

    /// A string as a JavaScript template literal.
    private static func literal(_ s: String) -> String {
        "`" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "${", with: "\\${") + "`"
    }

    /// The whole built-in engine as a file, to start a new one from.
    @MainActor static func builtInFile() -> String {
        var s = "// Phonodeck engine, as built into " + StoryEngine.build + ".\n"
        s += "// A prompt left out keeps the app's built-in text. Bump the version when you change something.\n"
        s += "var PhonodeckEngine = {\n  version: \"0\",\n  build: \"" + StoryEngine.build + "\",\n  notes: \"The engine built into the app.\",\n  prompts: {\n"
        for (k, v) in Prompts.builtIns { s += "    " + k + ": " + literal(v.trimmingCharacters(in: .whitespacesAndNewlines)) + ",\n\n" }
        s += "  },\n  testScripts: " + literal(PlayScripts.starterText.trimmingCharacters(in: .whitespacesAndNewlines)) + ",\n};\n"
        return s
    }

    // MARK: Versions on the phone

    struct Version: Identifiable, Equatable {
        let number: Int
        let url: URL
        let fileVersion: String
        let notes: String
        /// The address it was downloaded from.
        let source: String
        let prompts: Int
        let changed: Int
        let saved: Date
        var id: Int { number }
    }

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let f = base.appendingPathComponent("Engine", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    private static func file(_ n: Int) -> URL { folder.appendingPathComponent("V\(n).js") }
    private static func sourceFile(_ n: Int) -> URL { folder.appendingPathComponent("V\(n).source") }

    static func versions() -> [Version] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let nums = names.compactMap { n -> Int? in
            guard n.hasPrefix("V"), n.hasSuffix(".js") else { return nil }
            return Int(n.dropFirst().dropLast(3))
        }.sorted(by: >)
        let builtIn = Dictionary(Prompts.builtIns, uniquingKeysWith: { a, _ in a })
        return nums.compactMap { n in
            let u = file(n)
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
            let p = parse(text)
            var changed = p.prompts.filter { k, v in builtIn[k].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) != v } ?? false }.count
            if let t = p.testScripts, t.trimmingCharacters(in: .whitespacesAndNewlines) != PlayScripts.starterText.trimmingCharacters(in: .whitespacesAndNewlines) { changed += 1 }
            let saved = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? Date()
            let from = (try? String(contentsOf: sourceFile(n), encoding: .utf8)) ?? ""
            return Version(number: n, url: u, fileVersion: p.version, notes: p.error.map { "Doesn't run: " + $0 } ?? p.notes, source: from,
                           prompts: p.prompts.count + (p.testScripts == nil ? 0 : 1), changed: changed, saved: saved)
        }
    }

    /// Removes a downloaded version from the phone. If it was in use, the built-in engine takes over.
    static func delete(_ n: Int) {
        try? FileManager.default.removeItem(at: file(n))
        try? FileManager.default.removeItem(at: sourceFile(n))
        if active == n { active = 0 }
    }

    /// The version in use: 0 is the engine built into the app.
    static var active: Int {
        get { UserDefaults.standard.integer(forKey: "engineActive") }
        set { UserDefaults.standard.set(newValue, forKey: "engineActive"); shared.load() }
    }

    static var sourceURL: String {
        get { UserDefaults.standard.string(forKey: "engineURL") ?? defaultURL }
        set { UserDefaults.standard.set(newValue, forKey: "engineURL") }
    }

    /// Loads the active version (called at launch and on every switch). A file that no longer
    /// runs leaves the built-in engine in use.
    func load() {
        let n = Self.active
        var t: [String: String] = [:]
        var tests: String?
        var l = "built-in"
        if n > 0, let source = try? String(contentsOf: Self.file(n), encoding: .utf8) {
            let p = Self.parse(source)
            if p.error == nil {
                let known = Self.knownPrompts
                t = p.prompts.filter { known.contains($0.key) }
                tests = p.testScripts
                l = "V\(n) (file " + p.version + ")"
            } else {
                l = "built-in (V\(n) doesn't run)"
            }
        }
        lock.lock(); texts = t; self.tests = tests; label = l; lock.unlock()
    }

    /// Downloads the file at `sourceURL`, only when the player asks. If it runs and differs from the
    /// newest version on the phone, it is saved as the next version; the one in use stays in use
    /// until the player picks another. Returns what happened, in a sentence.
    static func check() async -> String {
        guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            return "That address doesn't look right."
        }
        // Only https, so nobody between the phone and the server can swap the file on the way.
        guard url.scheme?.lowercased() == "https" else { return "The address has to start with https://." }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { return "Couldn't reach " + (url.host ?? "that address") + "." }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { return "The address answered \(h.statusCode)." }
        guard let text = String(data: data, encoding: .utf8) else { return "That file isn't text." }
        let p = parse(text)
        if let e = p.error { return "That engine doesn't run, so it wasn't saved: " + e }
        let unknown = p.prompts.keys.filter { !knownPrompts.contains($0) }.sorted()
        let newest = versions().first
        if let newest, let old = try? String(contentsOf: newest.url, encoding: .utf8), old == text {
            if active != newest.number { return "No new version. V\(newest.number) is the newest, but it isn't in use right now." }
            return "Already up to date (V\(newest.number))."
        }
        let n = (newest?.number ?? 0) + 1
        do { try text.write(to: file(n), atomically: true, encoding: .utf8) } catch { return "Couldn't save it: " + error.localizedDescription }
        try? url.absoluteString.write(to: sourceFile(n), atomically: true, encoding: .utf8)
        return "Saved as V\(n) (file version " + p.version + "). Tap it below to use it."
            + (unknown.isEmpty ? "" : " Not used, names this app doesn't know: " + unknown.joined(separator: ", ") + ".")
    }

    /// At launch: load the version in use. The app never downloads on its own: a new engine
    /// comes only when the player asks for one, and goes in use only when they pick it.
    static func start() {
        shared.load()
    }
}

/// Settings → Game Master → Engine file.
struct EnginePackView: View {
    @State private var versions: [EnginePack.Version] = []
    @State private var active = EnginePack.active
    @State private var address = EnginePack.sourceURL
    @State private var status = ""
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { EnginePack.sourceURL = address }
                Button(checking ? "Checking..." : "Check for a new version") {
                    EnginePack.sourceURL = address
                    checking = true
                    Task {
                        status = await EnginePack.check()
                        checking = false
                        refresh()
                    }
                }
                .disabled(checking)
                if address != EnginePack.defaultURL {
                    Button("Use Phonodeck's address") { address = EnginePack.defaultURL; EnginePack.sourceURL = address }
                }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Get the engine")
            } footer: {
                Text("The app only downloads when you tap this, and a download never changes the engine you're using. Tap a version below to use it.")
            }
            Section {
                row(title: "Built into the app", detail: StoryEngine.build, number: 0)
                ForEach(versions) { v in
                    row(title: "V\(v.number)  ·  file version \(v.fileVersion)",
                        detail: (v.source.isEmpty ? "" : "From " + v.source.replacingOccurrences(of: "https://", with: "") + "\n") + "\(v.changed) of \(v.prompts) parts differ from built-in · " + v.saved.formatted(date: .abbreviated, time: .shortened)
                            + (v.notes.isEmpty ? "" : "\n" + v.notes),
                        number: v.number)
                    .swipeActions {
                        Button(role: .destructive) {
                            EnginePack.delete(v.number)
                            refresh()
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } header: {
                Text("Versions")
            } footer: {
                Text("Swipe left on a version to delete it.")
            }
            Section {
                ShareLink(item: EnginePack.builtInFile()) { Label("Share the built-in engine file", systemImage: "square.and.arrow.up") }
                if active > 0, let v = versions.first(where: { $0.number == active }), let text = try? String(contentsOf: v.url, encoding: .utf8) {
                    ShareLink(item: text) { Label("Share V\(v.number)", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                Text("Edit the file and put it at the address above to make a new version. For now the prompts and test scripts come from the file; more of the engine moves into it in later builds.")
            }
        }
        .navigationTitle("Engine file")
        .onAppear(perform: refresh)
    }

    private func row(title: String, detail: String, number: Int) -> some View {
        Button {
            EnginePack.active = number
            active = number
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if active == number { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    private func refresh() {
        versions = EnginePack.versions()
        active = EnginePack.active
    }
}
