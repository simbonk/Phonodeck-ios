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
    /// A guide for a good series of events, for the Game Master only.
    var beats = ""
    var minutes = 20

    enum CodingKeys: String, CodingKey {
        case format, id, title, author, simulator, feeling, describe, world, vibe, who, traits, place, goal, hook, allies, threat, play, avoid, beats, minutes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        format = (try? c.decodeIfPresent(Int.self, forKey: .format)) ?? 1
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = s(.title); author = s(.author); feeling = s(.feeling); describe = s(.describe); world = s(.world)
        vibe = s(.vibe); who = s(.who); traits = s(.traits); place = s(.place); goal = s(.goal); hook = s(.hook)
        allies = s(.allies); threat = s(.threat); play = s(.play); avoid = s(.avoid); beats = s(.beats)
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
        if player.age >= 18 { add("Romance", player.interest.isEmpty ? "" : "interested in " + player.interest) }
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
            name: d.string(forKey: "playerName") ?? "", age: d.integer(forKey: "playerAge"),
            gender: d.string(forKey: "playerGender") ?? "", interest: d.string(forKey: "playerInterest") ?? "")
    }
}

struct CastMember: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var role: String
    var known: Bool
    var desc: String

    enum CodingKeys: String, CodingKey { case name, role, known, desc }
    init(name: String, role: String, known: Bool, desc: String) {
        self.name = name; self.role = role; self.known = known; self.desc = desc
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        role = (try? c.decode(String.self, forKey: .role)) ?? ""
        known = (try? c.decode(Bool.self, forKey: .known)) ?? false
        desc = (try? c.decode(String.self, forKey: .desc)) ?? ""
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
    var cast: [CastMember] = []
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
}
