import CryptoKit
import Foundation
import Observation

/// Saved adventures, imported experiences and chats. Each is a JSON file sealed with the vault's
/// key (AES-GCM), so the files can't be read without unlocking Phonodeck.
@Observable
@MainActor
final class Library {
    private var key: SymmetricKey?
    private(set) var adventures: [Adventure] = []
    private(set) var imported: [Experience] = []
    /// Chats with the model, newest first.
    private(set) var chats: [Conversation] = []

    private var folder: URL { Vault.folder }
    private var adventuresFolder: URL { dir("Adventures") }
    private var experiencesFolder: URL { dir("Experiences") }
    private var chatsFolder: URL { dir("Chats") }

    private func dir(_ name: String) -> URL {
        let u = folder.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func open(key: SymmetricKey) {
        self.key = key
        reload()
    }

    func reload() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        adventures = files(in: adventuresFolder).compactMap { load($0).flatMap { try? dec.decode(Adventure.self, from: $0) } }
            .sorted { $0.updated > $1.updated }
        imported = files(in: experiencesFolder).compactMap { load($0).flatMap { try? dec.decode(Experience.self, from: $0) } }
            .sorted { $0.title < $1.title }
        chats = files(in: chatsFolder).compactMap { load($0).flatMap { try? dec.decode(Conversation.self, from: $0) } }
            .sorted { $0.updated > $1.updated }
        // The single chat from before there could be several becomes the first saved chat.
        let old = folder.appending(path: "chat.json")
        if let d = load(old), let turns = try? dec.decode([ChatTurn].self, from: d) {
            if !turns.isEmpty { save(Conversation(turns: turns)) }
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Forgets everything in memory, key included (the files stay), while the app is locked.
    func unload() {
        key = nil
        adventures = []
        imported = []
        chats = []
    }

    private func files(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    /// Opens a sealed file. A plain JSON file from an older version is read as is and sealed in place.
    private func load(_ url: URL) -> Data? {
        guard let key, let d = try? Data(contentsOf: url) else { return nil }
        if let box = try? AES.GCM.SealedBox(combined: d), let plain = try? AES.GCM.open(box, using: key) { return plain }
        guard (try? JSONSerialization.jsonObject(with: d)) != nil else { return nil }
        store(d, to: url)
        return d
    }

    /// Seals and writes a file. iOS also keeps it locked whenever the phone is locked.
    private func store(_ d: Data, to url: URL) {
        guard let key, let sealed = try? AES.GCM.seal(d, using: key).combined else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: Adventures

    func save(_ a: Adventure) {
        var a = a
        a.updated = Date()
        if let d = try? Self.encoder.encode(a) {
            store(d, to: adventuresFolder.appending(path: a.id.uuidString + ".json"))
        }
        adventures.removeAll { $0.id == a.id }
        adventures.insert(a, at: 0)
    }

    func delete(_ a: Adventure) {
        try? FileManager.default.removeItem(at: adventuresFolder.appending(path: a.id.uuidString + ".json"))
        adventures.removeAll { $0.id == a.id }
    }

    // MARK: Shared experiences

    /// Writes an experience as a .phonodeck file to share.
    func exportFile(_ e: Experience) -> URL? {
        let safe = e.title.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appending(path: (safe.isEmpty ? "Experience" : safe) + ".phonodeck")
        guard let d = try? Self.encoder.encode(e), (try? d.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "That file isn't a Phonodeck experience." }
    }

    /// Imports a .phonodeck file someone shared.
    @discardableResult
    func importExperience(from url: URL) throws -> Experience {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard var e = try? JSONDecoder().decode(Experience.self, from: data), !e.title.isEmpty || !e.describe.isEmpty else {
            throw ImportError.unreadable
        }
        if e.title.isEmpty { e.title = "Shared experience" }
        e.minutes = max(5, min(120, e.minutes))
        if let d = try? Self.encoder.encode(e) {
            store(d, to: experiencesFolder.appending(path: e.id.uuidString + ".json"))
        }
        imported.removeAll { $0.id == e.id }
        imported.append(e)
        imported.sort { $0.title < $1.title }
        return e
    }

    func deleteImported(_ e: Experience) {
        try? FileManager.default.removeItem(at: experiencesFolder.appending(path: e.id.uuidString + ".json"))
        imported.removeAll { $0.id == e.id }
    }

    // MARK: Chat

    func save(_ c: Conversation) {
        var c = c
        c.updated = Date()
        if let d = try? Self.encoder.encode(c) {
            store(d, to: chatsFolder.appending(path: c.id.uuidString + ".json"))
        }
        chats.removeAll { $0.id == c.id }
        chats.insert(c, at: 0)
    }

    func delete(_ c: Conversation) {
        try? FileManager.default.removeItem(at: chatsFolder.appending(path: c.id.uuidString + ".json"))
        chats.removeAll { $0.id == c.id }
    }
}

/// One chat with the model in the Chat tab.
struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var turns: [ChatTurn] = []
    var updated = Date()

    /// The first thing you said, shortened.
    var title: String {
        let first = turns.first { $0.role == .user }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty else { return "New chat" }
        return first.count > 50 ? String(first.prefix(50)) + "…" : first
    }
}
