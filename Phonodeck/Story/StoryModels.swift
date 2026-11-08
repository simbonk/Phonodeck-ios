import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A shareable Phonodeck experience (a small JSON file, "*.phonodeck").
    static let phonodeckExperience = UTType(exportedAs: "com.phonodeck.experience", conformingTo: .json)
}

/// The set-up for an experience: everything the player chooses before the world is built.
/// This is also the shareable file format: export it, send it to a friend, and they import it.
struct Experience: Codable, Identifiable, Hashable {
    var format = 1
    var id = UUID()
    var title = ""
    var author = ""
    /// true = experience (no plot, the player's own goal); false = a curated story with a hidden roadmap.
    var simulator = false
    var feeling = ""
    var describe = ""
    var world = ""
    var vibe = ""
    var who = ""
    var traits = ""
    var place = ""
    var goal = ""
    var hook = ""
    var allies = ""
    var threat = ""
    var play = ""
    var avoid = ""
    /// Who the player is drawn to, if anyone ("No romance" or empty for none).
    var romance = ""
    /// A guide for a good series of events, for the Game Master only.
    var beats = ""
    var minutes = 20

    enum CodingKeys: String, CodingKey {
        case format, id, title, author, simulator, feeling, describe, world, vibe, who, traits, place, goal, hook, allies, threat, play, avoid, romance, beats, minutes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        format = (try? c.decodeIfPresent(Int.self, forKey: .format)) ?? 1
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = s(.title); author = s(.author); feeling = s(.feeling); describe = s(.describe); world = s(.world)
        vibe = s(.vibe); who = s(.who); traits = s(.traits); place = s(.place); goal = s(.goal); hook = s(.hook)
        allies = s(.allies); threat = s(.threat); play = s(.play); avoid = s(.avoid); romance = s(.romance); beats = s(.beats)
        simulator = (try? c.decodeIfPresent(Bool.self, forKey: .simulator)) ?? false
        minutes = (try? c.decodeIfPresent(Int.self, forKey: .minutes)) ?? 20
    }

    /// The questionnaire as the architect model sees it.
    func answers(player: PlayerDetails) -> String {
        var lines: [String] = []
        func add(_ label: String, _ v: String) { if !v.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(label + ": " + v) } }
        add("Description", describe)
        add("World and era", world)
        add("Where it begins", place)
        add("Who the player is", who)
        add("Strengths and flaws", traits)
        add(simulator ? "Player's goal" : "The hook", simulator ? goal : (hook.isEmpty ? goal : hook))
        add("Companions", allies)
        add("What stands in the way", threat)
        add("Mood", vibe)
        add("Style of play", play)
        add("Content boundaries", avoid)
        add("Story guide for the Game Master", beats)
        add("Player's name", player.name)
        if player.age > 0 { lines.append("Player's age: \(player.age)") }
        add("Player's gender", player.gender)
        if player.age == 0 || player.age >= 18 {
            if !romance.isEmpty { add("Romance", romance) }
            else if !player.interest.isEmpty { lines.append("About the real player (background only; romance only if the player starts it): interested in " + player.interest) }
        }
        return lines.joined(separator: "\n")
    }
}

struct PlayerDetails {
    var name: String
    var age: Int
    var gender: String
    var interest: String

    static var saved: PlayerDetails {
        let d = UserDefaults.standard
        return PlayerDetails(
            name: d.string(forKey: "playerName") ?? "", age: 0,
            gender: d.string(forKey: "playerGender") ?? "", interest: d.string(forKey: "playerInterest") ?? "")
    }
}

/// Something the world knows about: a person, a place, an item or a faction. The World panel
/// lists these, the Game Master is reminded of them, and the memory pass adds to them as you play.
struct LoreEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case person, place, item, faction, other }

    var id = UUID()
    var name: String
    var kind: Kind = .other
    var desc = ""
    /// How the player first knows a person ("the old fisherman"), until the story reveals the name.
    var role = ""
    /// The player already knows this person's name (or the story has revealed it).
    var known = true
    /// What a person wants: their private agenda.
    var wants = ""
    var isPlayer = false
    /// The player wrote or edited this entry; their words always win.
    var byPlayer = false
    /// The turn it was last updated in play.
    var updatedTurn: Int?

    init(name: String, kind: Kind, desc: String = "", role: String = "", known: Bool = true, wants: String = "", isPlayer: Bool = false) {
        self.name = name; self.kind = kind; self.desc = desc; self.role = role; self.known = known; self.wants = wants; self.isPlayer = isPlayer
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, desc, role, known, wants, isPlayer, byPlayer, updatedTurn }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .other
        desc = (try? c.decodeIfPresent(String.self, forKey: .desc)) ?? ""
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? ""
        known = (try? c.decodeIfPresent(Bool.self, forKey: .known)) ?? true
        wants = (try? c.decodeIfPresent(String.self, forKey: .wants)) ?? ""
        isPlayer = (try? c.decodeIfPresent(Bool.self, forKey: .isPlayer)) ?? false
        byPlayer = (try? c.decodeIfPresent(Bool.self, forKey: .byPlayer)) ?? false
        updatedTurn = try? c.decodeIfPresent(Int.self, forKey: .updatedTurn)
    }

    static func kind(from s: String) -> Kind {
        switch s.lowercased() {
        case "person", "character", "people", "animal", "creature": .person
        case "place", "location": .place
        case "item", "object", "thing": .item
        case "faction", "group", "organisation", "organization": .faction
        default: .other
        }
    }

    var label: String {
        switch kind {
        case .person: isPlayer ? "You" : "Character"
        case .place: "Place"
        case .item: "Item"
        case .faction: "Faction"
        case .other: "Other"
        }
    }
}

struct Act: Codable, Hashable {
    var from: Double
    var to: Double
    var goal: String
}

struct Beat: Codable, Hashable {
    var text: String
    var done = false
}

struct StoryTurn: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case player, gm }
    var id = UUID()
    var role: Role
    var text: String
}

struct Mood: Codable, Hashable {
    var feeling: Int?
    var enjoying = ""
    var leavingPlot = false
}

struct Grade: Codable, Hashable {
    var grade: String
    var comment: String
}

struct ReportCard: Codable, Hashable {
    var title: String
    var summary: String
    var storyteller: Grade
    var player: Grade
    var next: String
}

/// A story in progress (or finished), saved as JSON in the current space's folder.
struct Adventure: Codable, Identifiable, Hashable {
    var id = UUID()
    var created = Date()
    var updated = Date()
    var setup: Experience
    var title: String
    var bible = ""
    var location = ""
    var playerName = ""
    /// People, places, items and factions (the player's own entry included).
    var lore: [LoreEntry] = []
    var beats: [Beat] = []
    var roadmap: [Act] = []
    var secrets: [String] = []
    var events: [String] = []
    var chapters: [String] = []
    /// How many turns at the start of the transcript are already covered by chapters.
    var summarisedTurns = 0
    var goalProgress = ""
    var mood = Mood()
    var transcript: [StoryTurn] = []
    var minutes: Int
    var elapsed: Double = 0
    var lastSendAt: Date?
    var turnTimes: [Double] = []
    var left: Int?
    var ended = false
    var report: ReportCard?
    var lastDirector: [String: Int] = [:]

    var playerTurns: Int { transcript.filter { $0.role == .player }.count }
    var isShort: Bool { minutes <= 15 }
    /// The people of the story, besides the player.
    var cast: [LoreEntry] { lore.filter { $0.kind == .person && !$0.isPlayer } }

    init(setup: Experience, title: String, minutes: Int) {
        self.setup = setup; self.title = title; self.minutes = minutes
    }

    enum CodingKeys: String, CodingKey {
        case id, created, updated, setup, title, bible, location, playerName, lore, cast, beats, roadmap, secrets, events, chapters,
             summarisedTurns, goalProgress, mood, transcript, minutes, elapsed, lastSendAt, turnTimes, left, ended, report, lastDirector
    }

    /// Tolerant: stories saved by an older version (with "cast" instead of "lore") still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        id = v(.id, UUID()); created = v(.created, Date()); updated = v(.updated, Date())
        setup = try c.decode(Experience.self, forKey: .setup)
        title = v(.title, "Untitled"); bible = v(.bible, ""); location = v(.location, ""); playerName = v(.playerName, "")
        lore = v(.lore, [LoreEntry]())
        if lore.isEmpty {
            struct OldCast: Decodable { var name: String?; var role: String?; var known: Bool?; var desc: String? }
            lore = v(.cast, [OldCast]()).compactMap { o in
                guard let n = o.name, !n.isEmpty else { return nil }
                return LoreEntry(name: n, kind: .person, desc: o.desc ?? "", role: o.role ?? "", known: o.known ?? false)
            }
        }
        beats = v(.beats, []); roadmap = v(.roadmap, []); secrets = v(.secrets, []); events = v(.events, []); chapters = v(.chapters, [])
        summarisedTurns = v(.summarisedTurns, 0); goalProgress = v(.goalProgress, ""); mood = v(.mood, Mood())
        transcript = v(.transcript, []); minutes = v(.minutes, 20); elapsed = v(.elapsed, 0)
        lastSendAt = try? c.decodeIfPresent(Date.self, forKey: .lastSendAt)
        turnTimes = v(.turnTimes, []); left = try? c.decodeIfPresent(Int.self, forKey: .left); ended = v(.ended, false)
        report = try? c.decodeIfPresent(ReportCard.self, forKey: .report); lastDirector = v(.lastDirector, [:])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(created, forKey: .created); try c.encode(updated, forKey: .updated)
        try c.encode(setup, forKey: .setup); try c.encode(title, forKey: .title); try c.encode(bible, forKey: .bible)
        try c.encode(location, forKey: .location); try c.encode(playerName, forKey: .playerName); try c.encode(lore, forKey: .lore)
        try c.encode(beats, forKey: .beats); try c.encode(roadmap, forKey: .roadmap); try c.encode(secrets, forKey: .secrets)
        try c.encode(events, forKey: .events); try c.encode(chapters, forKey: .chapters); try c.encode(summarisedTurns, forKey: .summarisedTurns)
        try c.encode(goalProgress, forKey: .goalProgress); try c.encode(mood, forKey: .mood); try c.encode(transcript, forKey: .transcript)
        try c.encode(minutes, forKey: .minutes); try c.encode(elapsed, forKey: .elapsed); try c.encodeIfPresent(lastSendAt, forKey: .lastSendAt)
        try c.encode(turnTimes, forKey: .turnTimes); try c.encodeIfPresent(left, forKey: .left); try c.encode(ended, forKey: .ended)
        try c.encodeIfPresent(report, forKey: .report); try c.encode(lastDirector, forKey: .lastDirector)
    }
}
