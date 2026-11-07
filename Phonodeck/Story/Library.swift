import Foundation
import Observation

/// Saved adventures, imported experiences and the chat history of the open space
/// (your own, or the demo). Everything is plain JSON in that space's folder.
@Observable
@MainActor
final class Library {
    private(set) var space: Vault.Space = .mine
    private(set) var adventures: [Adventure] = []
    private(set) var imported: [Experience] = []
    var chat: [ChatTurn] = [] { didSet { if !quiet { saveChat() } } }
    private var quiet = false

    private var folder: URL { Vault.folder(space) }
    private var adventuresFolder: URL { dir("Adventures") }
    private var experiencesFolder: URL { dir("Experiences") }

    private func dir(_ name: String) -> URL {
        let u = folder.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func open(_ space: Vault.Space) {
        self.space = space
        reload()
    }

    func reload() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        adventures = files(in: adventuresFolder).compactMap { try? dec.decode(Adventure.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
        imported = files(in: experiencesFolder).compactMap { try? dec.decode(Experience.self, from: Data(contentsOf: $0)) }
            .sorted { $0.title < $1.title }
        quiet = true
        if let d = try? Data(contentsOf: folder.appending(path: "chat.json")),
           let c = try? dec.decode([ChatTurn].self, from: d) {
            chat = c
        } else {
            chat = []
        }
        quiet = false
    }

    /// Forgets everything in memory (the files stay) while the app is locked.
    func unload() {
        quiet = true
        adventures = []
        imported = []
        chat = []
        quiet = false
    }

    private func files(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
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
            try? d.write(to: adventuresFolder.appending(path: a.id.uuidString + ".json"), options: .atomic)
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
            try? d.write(to: experiencesFolder.appending(path: e.id.uuidString + ".json"), options: .atomic)
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

    private func saveChat() {
        if let d = try? Self.encoder.encode(chat) {
            try? d.write(to: folder.appending(path: "chat.json"), options: .atomic)
        }
    }
}
