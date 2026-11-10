import Foundation
import NaturalLanguage

/// Checks in code that keep a small storyteller honest between turns: whether the player is
/// really going somewhere, the story clock, second person, things the player never had, and
/// the shape of the Game Master's review. Small models slip on these in ways code can see, so
/// each check turns a slip into a plain correction for the next reply instead of trusting the model.
enum Continuity {
    // MARK: Movement

    private static let motionVerbs = "go|goes|going|head|heading|walk|walking|run|running|hurry|hurrying|climb|climbing|swim|swimming|wander|wandering|stroll|strolling|drive|driving|ride|riding|step|stepping|move|moving|cross|crossing|return|returning|slip|slipping|sneak|sneaking|dash|dashing|race|racing|jog|jogging|come|coming|make my way|making my way|go back|come back"
    private static let destinations = "to|toward|towards|into|inside|outside|out|over|across|through|up|down|upstairs|downstairs|back|home|away|off|along|around|onto|after|closer|nearer"
    /// Words that, right before the verb, show it is not the player going anywhere ("are you going
    /// to the dance", "shake my head down", "he walks over").
    private static let notThePlayer: Set<String> = ["you", "he", "she", "they", "it", "who", "my", "his", "her", "your", "their", "its", "the", "a", "an"]
    private static let determiners: Set<String> = ["the", "a", "an", "my", "your", "his", "her", "their", "our", "this", "that", "some", "bed", "town", "work", "school", "church", "sea", "market", "bar", "door", "window"]

    /// The player says they go somewhere or look for someone ("I go find the caretaker", "I head
    /// out into the rain"). "Can I buy you a drink? What are you going to have?" is not moving.
    static func moves(_ input: String) -> Bool {
        let t = input.lowercased().replacingOccurrences(of: "’", with: "'")
        // Looking for someone or something always counts, and so do a few set phrases.
        let search = #"\b(look|looking|search|searching|hunt|hunting)\s+(for|around)\b|\b(go|going|try to|trying to|set off to)\s+find\b|\blet'?s go\b|\blet us go\b|\blead the way\b|\btake me (to|back|home)\b|\bshow me the way\b"#
        if t.range(of: search, options: .regularExpression) != nil { return true }
        // "I leave", "I follow her", "we head out": first person with a verb of leaving or following.
        let leaving = #"\b(i|we|i'll|we'll|i will|we will|let's)\s+(\w+ly\s+)?(leave|leaves|exit|follow|depart|set off|head out|go)\b(?!\s+(a|an|some|my|your|the)\s+(tip|coin|coins|note|message|money|drink|change)\b)"#
        if t.range(of: leaving, options: .regularExpression) != nil, !Self.futureVerb(t) { return true }
        // A verb of motion with a destination ("walk over to the booth", "head back home").
        guard let re = try? NSRegularExpression(pattern: "\\b(" + motionVerbs + ")\\s+(?:(?:back|over|out|up|down|on|off)\\s+)?(" + destinations + ")\\b(\\s+[a-z']+)?") else { return false }
        let ns = t as NSString
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: m.range.location).split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
            if notThePlayer.contains(before) || before.hasSuffix("'s") { continue }
            let dest = ns.substring(with: m.range(at: 2))
            let next = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            // "going to have a drink" is the future, not a journey: after a bare "to", the next word
            // has to start a place.
            if dest == "to", !next.isEmpty, !determiners.contains(next) { continue }
            return true
        }
        return false
    }

    /// "I'm going to order", "we'll go ask": the verb is about a plan, not a place.
    private static func futureVerb(_ t: String) -> Bool {
        t.range(of: #"\b(go|going)\s+to\s+(?!the\b|a\b|an\b|my\b|your\b|his\b|her\b|their\b|our\b|this\b|that\b)[a-z]+\b"#, options: .regularExpression) != nil
            && t.range(of: #"\b(leave|exit|follow|depart|set off|head out)\b"#, options: .regularExpression) == nil
    }

    // MARK: The story clock

    /// Parts of the day, in order. The clock is kept in minutes from midnight on the day the story opens.
    static let parts = ["morning", "midday", "afternoon", "evening", "night"]
    /// Where each part starts, in minutes after midnight.
    static let partStarts = [360, 690, 810, 1080, 1260]

    static func part(of minutes: Int) -> Int {
        let m = ((minutes % 1440) + 1440) % 1440
        if m < 300 { return 4 }
        return partStarts.lastIndex { m >= $0 } ?? 0
    }

    /// The time of day a phrase names, in minutes after midnight ("9:30 PM", "early morning",
    /// "just after sunset"), or nil if it names none.
    static func minutes(in text: String) -> Int? {
        let l = text.lowercased()
        if let re = try? NSRegularExpression(pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s?m\b"#),
           let m = re.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) {
            let ns = l as NSString
            let h = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let mm = m.range(at: 2).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: 2))) ?? 0
            guard h >= 1, h <= 12, mm < 60 else { return nil }
            return (h % 12 + (ns.substring(with: m.range(at: 3)) == "p" ? 12 : 0)) * 60 + mm
        }
        let words: [(String, Int)] = [
            ("before dawn", 300), ("dawn", 360), ("daybreak", 360), ("sunrise", 370), ("early morning", 420), ("mid-morning", 600),
            ("midmorning", 600), ("late morning", 640), ("morning", 540), ("early afternoon", 810), ("late afternoon", 1000),
            ("afternoon", 900), ("midday", 720), ("noon", 720), ("sunset", 1140), ("dusk", 1150), ("twilight", 1150),
            ("early evening", 1100), ("late evening", 1290), ("evening", 1170), ("midnight", 0), ("late night", 1400),
            ("small hours", 120), ("night", 1290),
        ]
        for (w, m) in words where l.range(of: "\\b" + w + "\\b", options: .regularExpression) != nil { return m }
        return nil
    }

    /// "9:40 PM".
    static func clockText(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        let h = m / 60
        return "\(h % 12 == 0 ? 12 : h % 12):" + String(format: "%02d", m % 60) + (h < 12 ? " AM" : " PM")
    }

    /// The story time line the Game Master reads: the clock's part of the day and time, then whatever
    /// else the model said about it ("the day after the storm, late autumn") minus any time of day.
    static func storyTime(clock: Int, old: String) -> String {
        let p = part(of: clock)
        let m = ((clock % 1440) + 1440) % 1440
        let plain = parts[p].prefix(1).uppercased() + String(parts[p].dropFirst())
        let name: String = p == 4 && (m >= 1380 || m < 300) ? "Late night" : plain
        let day = clock >= 1440 ? ", day \(clock / 1440 + 1) of the story" : ""
        let tail = old.split(separator: ",").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && minutes(in: $0) == nil && $0.range(of: #"(?i)\bday \d+ of the story\b"#, options: .regularExpression) == nil }
        return name + " (about " + clockText(clock) + ")" + day + (tail.isEmpty ? "" : ", " + tail.joined(separator: ", "))
    }

    /// What the sky and light are like now, so the reply paints the right one.
    static func skyHint(_ clock: Int) -> String {
        switch part(of: clock) {
        case 0: return "It is daytime: morning light, no stars or moon."
        case 1, 2: return "It is daytime: no stars, moon or sunrise."
        case 3: return "It is evening: the light is going; no sunrise or morning."
        default: return "It is dark outside: no sunrise, sunshine or morning light."
        }
    }

    /// The parts of the day a reply paints as now (0 morning to 4 night). Looks back and ahead
    /// ("last night", "in the morning", "tonight") and greetings ("good evening") don't count.
    static func dayParts(in reply: String) -> Set<Int> {
        var l = reply.lowercased().replacingOccurrences(of: "’", with: "'")
        let skip = [
            #"\b(this|that|yesterday|last|tomorrow|next|every|each|one|some|other|all|tonight's|today's|the next|the following)\s+(morning|night|evening|afternoon|dawn|sunrise|sunset)s?\b"#,
            #"\b(in|by|until|till|before|after|since|come|at|through|all)\s+(the\s+)?(morning|dawn|sunrise|daybreak|night|nightfall|evening|afternoon)\b"#,
            #"\b(good|gud)\s*(morning|evening|night|afternoon)\b|\bgoodnight\b|\btonight\b|\bovernight\b|\bnights\b|\bmornings\b|\bevenings\b"#,
            #"\b(morning|night|evening) (shift|person|owl|cap|class|paper|news|service|market|light of [a-z]+)\b"#,
        ]
        for p in skip { l = l.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        let cues: [(String, Int)] = [
            ("dawn|daybreak|sunrise|sunup|morning|breakfast|the sun (is )?(rises|rising|climbs|comes up)", 0),
            ("noon|midday", 1),
            ("afternoon", 2),
            ("sunset|dusk|twilight|evening|first stars|the sun (sets|is setting|goes down|dips)", 3),
            ("night|midnight|moon|moonlight|moonlit|starlight|starlit|starry|stars", 4),
        ]
        var out = Set<Int>()
        for (pattern, p) in cues where l.range(of: "\\b(" + pattern + ")\\b", options: .regularExpression) != nil { out.insert(p) }
        return out
    }

    // MARK: Second person

    /// A reply that left second person: the narration calls the player by name or "the player",
    /// or describes them as "they" with hardly a "you" in sight. Dialogue (in quotes) is ignored.
    static func povSlip(_ reply: String, playerName: String) -> String? {
        let narration = reply.replacingOccurrences(of: #""[^"]*"|“[^”]*”"#, with: " ", options: .regularExpression)
        let words = narration.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        guard words.count >= 25 else { return nil }
        if narration.range(of: #"(?i)\bthe (player|player character|protagonist)\b"#, options: .regularExpression) != nil {
            return "Narrate in second person: the player is \"you\", never \"the player\"."
        }
        let first = playerName.split(separator: " ").first.map(String.init) ?? ""
        if first.count > 1, narration.range(of: "\\b" + NSRegularExpression.escapedPattern(for: first) + "\\b", options: .regularExpression) != nil {
            return "Narrate in second person: the player is \"you\". The name \(first) belongs only in other characters' dialogue."
        }
        let you = words.filter { ["you", "your", "yours", "yourself", "you're", "you've", "you'll", "you'd"].contains($0) }.count
        let they = words.filter { ["they", "them", "their", "theirs", "themselves", "they're"].contains($0) }.count
        if you <= 1, they >= 2 {
            return "The last reply drifted into third person (\"they\"). Narrate in second person: the player is \"you\", in the present tense."
        }
        return nil
    }

    // MARK: Facts that last

    /// A fact worth keeping as "always true", or nil. A line that only says where a person is or
    /// what posture they are in right now ("Dolores sits beside Simon now", "Simon is alone at the
    /// bar") is not one: it goes stale the moment they move, and then pulls the story back. If such
    /// a line also says what they wear or carry, that part is kept.
    static func lastingFact(_ fact: String, people: [String]) -> String? {
        let firsts = people.compactMap { $0.split(separator: " ").first.map(String.init) }.filter { $0.count > 1 } + ["You", "The player"]
        let names = firsts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let position = "^(" + names + #")(\s+\w+)?\s+(is|are|sits|stands|leans|waits|remains|stays)\s+(now\s+|still\s+|currently\s+)?(sitting|seated|standing|leaning|waiting|alone|at|behind|beside|next to|near|in|inside|outside|on|by|with|here|there|up)\b"#
        guard fact.range(of: position, options: [.regularExpression, .caseInsensitive]) != nil else { return fact }
        guard let keep = fact.range(of: #"\b(wearing|wears|carrying|carries|holding a|has a)\b"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let who = fact.split(separator: " ").prefix(while: { !["is", "are", "sits", "stands", "leans", "waits", "remains", "stays"].contains($0.lowercased()) }).joined(separator: " ")
        let rest = String(fact[keep.lowerBound...])
        let verb = rest.lowercased()
        return who + (verb.hasPrefix("wears") || verb.hasPrefix("carries") || verb.hasPrefix("has") ? " " : " is ") + rest
    }

    /// The reply writes the player's own words: a quote tagged "you say", "you whisper" and the
    /// like, before or after it.
    static func speaksForPlayer(_ reply: String) -> Bool {
        let verbs = "say|said|whisper|whispered|murmur|murmured|admit|admitted|reply|replied|answer|answered|ask|asked|tell|echo|echoed|add|added|call|called|offer|offered|confess|confessed|laugh|laughed"
        let after = #"["”]\s*,?\s*you\s+(softly\s+|quietly\s+|gently\s+)?("# + verbs + #")\b"#
        let before = #"\byou\s+(softly\s+|quietly\s+|gently\s+)?("# + verbs + #")\b[^."“]{0,30}[,:]\s*["“]"#
        return reply.range(of: after, options: [.regularExpression, .caseInsensitive]) != nil
            || reply.range(of: before, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Things the player never had

    /// Ordinary words that can follow "your" without being an object the story must have given
    /// the player (body, senses, feelings, clothes in general, and the like).
    private static let ordinary: Set<String> = [
        "hand", "hands", "eye", "eyes", "face", "head", "heart", "breath", "voice", "mouth", "lips", "ear", "ears", "hair", "shoulder",
        "shoulders", "arm", "arms", "back", "chest", "fingers", "finger", "feet", "foot", "legs", "leg", "knees", "knee", "skin", "neck",
        "throat", "cheek", "cheeks", "chin", "nose", "palm", "palms", "wrist", "wrists", "spine", "stomach", "body", "mind", "thoughts",
        "name", "life", "own", "way", "turn", "time", "attention", "gaze", "smile", "laugh", "question", "answer", "words", "feelings",
        "mood", "memory", "memories", "pulse", "step", "steps", "seat", "place", "side", "glass", "drink", "coat", "jacket", "shoes",
        "boots", "clothes", "pocket", "pockets", "lap", "chair", "stool", "table", "fault", "friend", "friends", "family", "story",
        "presence", "company", "health", "choice", "move", "guess", "day", "night", "evening", "morning", "trip", "visit", "favourite",
        "favorite", "usual", "order", "tab", "change", "money", "coin", "coins", "cup", "plate", "food", "breakfast", "dinner", "lunch",
        "thirst", "hunger", "fatigue", "secret", "self", "dreams", "dream", "home", "room", "bed", "family's", "shadow", "reflection",
        "footsteps", "sleeve", "sleeves", "collar", "hat", "scarf", "umbrella", "fingertips", "tongue", "teeth", "brow", "forehead",
        "whiskey", "whisky", "bourbon", "gin", "beer", "wine", "coffee", "tea", "cocktail", "martini", "ale", "scotch", "rum", "water",
    ]

    /// Objects the reply hands the player ("your brass ticket") that nothing earlier in the story
    /// mentioned: the facts, the bible, the set-up and the transcript are `known`. Something the
    /// reply itself shows arriving ("she slides a whiskey over... your whiskey") is fine.
    static func inventedPossessions(_ reply: String, known: String) -> [String] {
        let text = reply.replacingOccurrences(of: "’", with: "'")
        // The words after each "your", by their part of speech: the run of adjectives and nouns, and
        // its last noun is the thing ("your brass ticket"; "your hand trembles" stops at the verb).
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var words: [(word: String, tag: NLTag?)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .joinContractions]) { tag, range in
            words.append((String(text[range]).lowercased(), tag))
            return true
        }
        let lower = text.lowercased()
        let ns = lower as NSString
        let seen = known.lowercased()
        var out: [String] = []
        for i in words.indices where words[i].word == "your" {
            var run: [String] = []
            var noun: String?
            var j = i + 1
            while j < words.count, run.count < 4, words[j].tag == .adjective || words[j].tag == .noun {
                run.append(words[j].word)
                if words[j].tag == .noun { noun = words[j].word }
                j += 1
            }
            guard let noun, noun.count >= 3, !ordinary.contains(noun), let end = run.lastIndex(of: noun) else { continue }
            let stem = noun.hasSuffix("s") ? String(noun.dropLast()) : noun
            let word = "\\b" + NSRegularExpression.escapedPattern(for: stem)
            guard seen.range(of: word, options: .regularExpression) == nil else { continue }
            // Mentioned in the reply other than as "your ...": the reply showed where it came from.
            let all = (try? NSRegularExpression(pattern: word))?.numberOfMatches(in: lower, range: NSRange(location: 0, length: ns.length)) ?? 0
            let owned = (try? NSRegularExpression(pattern: #"\byour\s+(?:[a-z'-]+\s+){0,3}?"# + NSRegularExpression.escapedPattern(for: stem)))?
                .numberOfMatches(in: lower, range: NSRange(location: 0, length: ns.length)) ?? 0
            guard all <= owned else { continue }
            let phrase = run[...end].joined(separator: " ")
            if !out.contains(phrase) { out.append(phrase) }
        }
        return Array(out.prefix(2))
    }

    // MARK: Pronouns

    /// The he/she words right after each mention of a person's first name, up to the next
    /// person's name or paragraph.
    static func pronounCounts(in text: String, for name: String, others: [String]) -> (he: Int, she: Int) {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        guard first.count > 1, let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: first) + "\\b") else { return (0, 0) }
        let ns = text as NSString
        var he = 0, she = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = m.range.location + m.range.length
            var window = ns.substring(with: NSRange(location: start, length: min(160, ns.length - start)))
            if let p = window.range(of: "\n\n") { window = String(window[..<p.lowerBound]) }
            for o in others where o != first { if let r = window.range(of: o) { window = String(window[..<r.lowerBound]) } }
            for w in window.lowercased().split(whereSeparator: { !$0.isLetter }) {
                switch w {
                case "he", "him", "his", "himself": he += 1
                case "she", "her", "hers", "herself": she += 1
                default: break
                }
            }
        }
        return (he, she)
    }

    /// A review's pronoun "fix" the reply doesn't need: it says someone is "she, not he" (or the
    /// reverse) when the reply never called them the wrong one. Code checks pronouns itself, so a
    /// claim it can't see in the text is a false alarm that would only confuse the next reply.
    static func bogusPronounFix(_ fix: String, reply: String, cast: [String]) -> Bool {
        let l = fix.lowercased()
        guard l.range(of: #"\b(he|she|him|her|his|hers|pronouns?|man|woman|male|female)\b"#, options: .regularExpression) != nil else { return false }
        let firsts = cast.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        guard let person = cast.first(where: { n in
            let f = n.split(separator: " ").first.map(String.init) ?? n
            return fix.range(of: "\\b" + NSRegularExpression.escapedPattern(for: f) + "\\b", options: .regularExpression) != nil
        }) else { return false }
        // What the fix says is right: whichever of she/he (or woman/man) it names first.
        let female = l.range(of: #"\b(she|her|woman|female)\b"#, options: .regularExpression)
        let male = l.range(of: #"\b(he|him|his|man|male)\b"#, options: .regularExpression)
        let claimsShe: Bool
        switch (female, male) {
        case let (f?, m?): claimsShe = f.lowerBound < m.lowerBound
        case (_?, nil): claimsShe = true
        case (nil, _?): claimsShe = false
        default: return false
        }
        let c = pronounCounts(in: reply, for: person, others: firsts)
        return (claimsShe ? c.he : c.she) == 0
    }

    /// Whether a text names a place: every real word of the place's name appears in it
    /// ("Back Alley" needs both "back" and "alley").
    static func names(place: String, in text: String) -> Bool {
        let skip: Set<String> = ["the", "a", "an", "of", "and", "at", "in", "on"]
        let words = place.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !skip.contains($0) }
        guard !words.isEmpty else { return false }
        let have = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return words.allSatisfy { w in have.contains(w) || have.contains(w + "s") || (w.hasSuffix("s") && have.contains(String(w.dropLast()))) }
    }

    /// Whether an exchange reads like the player going from one place to another (out a door, down
    /// a street), as opposed to crossing a room. Used with the review's own "left" answer: both
    /// must agree before anyone is counted as left behind.
    static func leavesPlace(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let exit = #"\b(outside|outdoors|out (into|onto|the door|we go|of the|of here)|steps? out|step(s|ped)? through|walk(s|ed|ing)? (out|to|toward|towards|down|along|away|home|into)|leav(e|es|ing)|left the|street|alley|alleyway|sidewalk|pavement|road|path|shore|beach|harbor|harbour|upstairs|downstairs|next door|another room|hallway|corridor|doorway|drive|drives|ride|rides|boards?|climbs?|follow(s|ed)? (him|her|them) (out|to|into|down|up))\b"#
        return t.range(of: exit, options: .regularExpression) != nil
    }

    /// The words of a text, for checking what the story has actually said.
    static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Whether a card entry ("a brass candlestick holder", "Dolores owes her brother money") is
    /// backed by the story's own words: at least `share` of its real words appear in them. The
    /// review writes the card, and a small model invents things there that the story never showed;
    /// once on the card they would be fed back and become real.
    static func grounded(_ entry: String, in story: Set<String>, share: Double = 0.6) -> Bool {
        let skip: Set<String> = ["the", "a", "an", "of", "and", "at", "in", "on", "with", "from", "for", "to", "is", "are", "was", "has", "have",
                                 "his", "her", "their", "your", "its", "that", "this", "some", "small", "little", "old", "who", "uses"]
        let words = entry.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 && !skip.contains($0) }
        guard !words.isEmpty else { return false }
        func has(_ w: String) -> Bool {
            if story.contains(w) || story.contains(w + "s") || story.contains(w + "es") { return true }
            if w.hasSuffix("s"), story.contains(String(w.dropLast())) { return true }
            // "crackling" against "crackle", "hanging" against "hang", "soaked" against "soak".
            for end in ["ing", "ed", "es"] where w.hasSuffix(end) && w.count > end.count + 3 {
                let stem = String(w.dropLast(end.count))
                if story.contains(stem) || story.contains(stem + "e") || story.contains(stem + "s") { return true }
            }
            return false
        }
        return Double(words.filter(has).count) / Double(words.count) >= share
    }

    // MARK: The review's shape

    /// The keys a review must have to be any use, in the order the prompt asks for them.
    static let reviewKeys = ["place", "left", "scene", "here", "people", "carrying", "things", "time", "timeline", "new_facts", "fixes", "feeling", "enjoying", "steps_done", "unanswered", "next"]
    static let requiredReviewKeys = ["scene", "people", "next"]

    /// Puts a review's JSON into the shape the engine reads: lists that came back as one string are
    /// split, strings that came back as lists are joined, and people given as {"name": "where"} or
    /// "Name: where" become objects. Returns the keys still missing or empty.
    static func normaliseReview(_ m: [String: Any]) -> (review: [String: Any], missing: [String]) {
        var r = m
        func sentences(_ s: String) -> [String] {
            s.replacingOccurrences(of: #"([.!?;])\s+(?=[A-Z])"#, with: "$1\n", options: .regularExpression)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }
        }
        // "here" as one string ("Walter, Dolores") becomes a list of names.
        if let h = r["here"] as? String {
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            r["here"] = ["", "none", "[]", "n/a", "nobody", "no one", "alone"].contains(t.lowercased()) ? [String]()
                : t.components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        for k in ["facts", "new_facts", "fixes", "timeline", "carrying", "things", "steps_done"] {
            if let s = r[k] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                r[k] = ["", "none", "[]", "n/a"].contains(t.lowercased()) ? [] : sentences(t)
            } else if let list = r[k] as? [Any] {
                r[k] = list.flatMap { item -> [String] in
                    if let s = item as? String { return k.hasSuffix("facts") && s.count > 180 ? sentences(s) : [s] }
                    if let d = item as? [String: Any] { return [d.values.compactMap { $0 as? String }.joined(separator: ": ")] }
                    return []
                }
            }
        }
        for k in ["unanswered", "scene", "time", "next"] {
            if let list = r[k] as? [Any] { r[k] = list.compactMap { $0 as? String }.joined(separator: " ") }
            else if let d = r[k] as? [String: Any] { r[k] = d.values.compactMap { $0 as? String }.joined(separator: " ") }
        }
        if let d = r["people"] as? [String: Any] {
            r["people"] = d.compactMap { pair -> [String: Any]? in
                let (name, v) = pair
                if let s = v as? String { return ["name": name, "where": s] }
                if var o = v as? [String: Any] { o["name"] = o["name"] ?? name; return o }
                return nil
            }
        } else if let list = r["people"] as? [Any] {
            r["people"] = list.compactMap { item -> [String: Any]? in
                if let o = item as? [String: Any] { return o }
                guard let s = item as? String, let colon = s.firstIndex(of: ":") else { return nil }
                return ["name": String(s[..<colon]).trimmingCharacters(in: .whitespaces),
                        "where": String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)]
            }
        }
        let missing = requiredReviewKeys.filter { k in
            if let s = r[k] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).count < 4 }
            if let l = r[k] as? [Any] { return l.isEmpty }
            return true
        }
        return (r, missing)
    }

    // MARK: The planner's input

    /// Content words, for comparing what a plan says the player did with what they actually said.
    static func contentWords(_ s: String) -> Set<String> {
        let small: Set<String> = ["the", "a", "an", "and", "or", "to", "of", "in", "on", "at", "for", "with", "is", "are", "was", "i", "you",
                                  "me", "my", "your", "it", "that", "this", "player", "asks", "says", "do", "does", "can", "could", "would"]
        return Set(s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init).filter { $0.count > 1 && !small.contains($0) })
    }

    /// True when a plan's PLAYER line is about the player's earlier message rather than the new one.
    static func planIsStale(playerLine: String, input: String, previous: String) -> Bool {
        let p = contentWords(playerLine)
        guard p.count >= 2, !previous.isEmpty else { return false }
        let toPrev = Double(p.intersection(contentWords(previous)).count) / Double(p.count)
        let toNew = Double(p.intersection(contentWords(input)).count) / Double(p.count)
        return toPrev >= 0.5 && toPrev > toNew + 0.2
    }
}

/// Reads the reply sentence by sentence as it streams and leaves out what should not be there,
/// before it is shown or read aloud. It is plain string work with no model call, so it adds no wait.
///
/// Two things are left out:
/// - People who are somewhere else. The tracker knows who is in the room with the player. A small
///   model still cuts away to someone left behind ("Dolores watches from her table inside") or
///   lets them answer. When the narration has an absent person acting, the rest of that paragraph
///   goes. Names inside dialogue are fine (people talk about each other), so are possessives
///   ("Walter's bar"), memories ("the key Walter gave you") and a sentence that shows the person
///   arriving.
/// - Sentences copied word for word from the last few replies (small models sometimes start a
///   reply by repeating the previous one).
struct PresenceFilter {
    struct Absent { let name: String; let at: String }

    let absent: [Absent]
    private let acts: NSRegularExpression?
    private let said: Set<String>
    private static let boundary = try! NSRegularExpression(pattern: #"[.!?…]["”’]?\s+(?=\S)"#)
    private static let arrival = try! NSRegularExpression(
        pattern: #"\b(arrives?|enters?|joins?|returns?|approach(es)?|catch(es)? up|(walks?|comes?|steps?|hurries|runs?|strides?|slips?|wanders?|climbs?|pushes) (in|into|up|over|out|through|back|down|toward|towards)|calls? (out|over|from)|voice (carries|comes|calls|drifts)|on the (phone|radio|line))\b"#,
        options: [.caseInsensitive])

    private var pending = ""
    private var inQuote = false
    private var dropping = false
    private var raw = ""
    /// What has been let through so far.
    private(set) var accepted = ""
    /// The sentences left out, in order.
    private(set) var dropped: [String] = []
    /// Who was caught acting in a scene they are not in.
    private(set) var caught: [Absent] = []
    /// How many sentences were left out as copies of earlier replies.
    private(set) var echoes = 0
    /// True when so little was left that the reply was let through whole after all.
    private(set) var restored = false
    /// True when so little was left that the reply needs writing again (see `finish(restore:)`).
    private(set) var gutted = false

    /// `absent`: the people known to be somewhere else. `earlier`: the last few replies, whose
    /// sentences must not come back word for word.
    init(absent: [Absent], earlier: [String] = []) {
        var names: [String] = []
        for p in absent {
            names.append(p.name)
            if let first = p.name.split(separator: " ").first.map(String.init), first.count >= 3, first != p.name { names.append(first) }
        }
        names = names.filter { $0.count >= 3 && $0.first?.isUppercase == true }.sorted { $0.count > $1.count }
        var re: NSRegularExpression?
        if !names.isEmpty {
            let n = "(?:" + names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")"
            // The person does something now ("Walter leans", "Walter quietly watches", "Walter is"), or
            // someone in the scene deals with them directly ("you hand it to Walter").
            let pattern = #"\b"# + n + #"\b(?!['’]s)\s+(?:[a-z]+ly\s+)?(?:[a-z]+s|is|has)\b"#
                + #"|\b(?:to|at|with|beside|toward|towards)\s+"# + n + #"\b(?!['’]s)"#
            re = try? NSRegularExpression(pattern: pattern)
        }
        acts = re
        self.absent = re == nil ? [] : absent
        var seen = Set<String>()
        for text in earlier {
            for s in Self.sentences(text) {
                let k = Self.key(s)
                if k.count >= 40 { seen.insert(k) }
            }
        }
        said = seen
    }

    /// Nothing to check: nobody is elsewhere and there are no earlier replies.
    var idle: Bool { acts == nil && said.isEmpty }

    /// What to show while the reply streams: the accepted text plus the sentence being written,
    /// unless that sentence is already on its way out.
    var preview: String {
        if dropping || hit(narration(of: pending, from: inQuote)) != nil { return accepted }
        return accepted + pending
    }

    /// Takes the next piece of the stream and returns the text that may be shown and spoken.
    mutating func feed(_ piece: String) -> String {
        raw += piece
        pending += piece
        var out = ""
        while true {
            let ns = pending as NSString
            guard let m = Self.boundary.firstMatch(in: pending, range: NSRange(location: 0, length: ns.length)) else { break }
            let end = m.range.location + m.range.length
            out += judge(ns.substring(to: end))
            pending = ns.substring(from: end)
        }
        return out
    }

    /// The end of the stream: judges the last sentence. If almost nothing survived, the tracker
    /// was probably wrong, so the left-out text is let through after all.
    /// With `restore` off, a reply left too short is only marked as gutted, so the caller can have
    /// it written again (and fall back to `giveBack()` if that fails too).
    mutating func finish(restore: Bool = true) -> String {
        var out = pending.isEmpty ? "" : judge(pending)
        pending = ""
        if !dropped.isEmpty, accepted.split(whereSeparator: \.isWhitespace).count < 30 {
            if restore { out += giveBack() } else { gutted = true }
        }
        return out
    }

    /// Lets the left-out text through after all. Returns it, for the voice.
    mutating func giveBack() -> String {
        let rest = dropped.joined()
        let out = (accepted.hasSuffix("\n") || accepted.isEmpty ? "" : " ") + rest
        accepted = raw
        restored = true
        gutted = false
        caught = []
        return out
    }

    private mutating func judge(_ unit: String) -> String {
        let narrated = narration(of: unit, from: inQuote)
        for ch in unit {
            switch ch {
            case "\"": inQuote.toggle()
            case "“": inQuote = true
            case "”": inQuote = false
            default: break
            }
        }
        let endsParagraph = unit.reversed().prefix { $0.isWhitespace }.contains { $0.isNewline }
        var keep = true
        if dropping {
            keep = false
        } else if said.contains(Self.key(unit)) {
            keep = false
            echoes += 1
        } else if caught.count < 3, let who = hit(narrated) {
            dropping = true
            keep = false
            if !caught.contains(where: { $0.name == who.name }) { caught.append(who) }
        }
        if endsParagraph { dropping = false; inQuote = false }
        if keep {
            accepted += unit
            return unit
        }
        dropped.append(unit)
        // The paragraph break survives, so what follows does not run into what came before.
        if endsParagraph, !accepted.isEmpty, !accepted.hasSuffix("\n") {
            accepted += "\n\n"
            return "\n\n"
        }
        return ""
    }

    /// The part of a sentence outside quotation marks.
    private func narration(of unit: String, from quoted: Bool) -> String {
        var q = quoted
        var out = ""
        for ch in unit {
            switch ch {
            case "\"": q.toggle()
            case "“": q = true
            case "”": q = false
            default: if !q { out.append(ch) }
            }
        }
        return out
    }

    /// The absent person this narration has acting in the scene, unless it shows them arriving.
    private func hit(_ narrated: String) -> Absent? {
        guard let acts else { return nil }
        let range = NSRange(location: 0, length: (narrated as NSString).length)
        guard let m = acts.firstMatch(in: narrated, range: range) else { return nil }
        if Self.arrival.firstMatch(in: narrated, range: range) != nil { return nil }
        let found = (narrated as NSString).substring(with: m.range)
        return absent.first { found.contains($0.name) }
            ?? absent.first { p in p.name.split(separator: " ").first.map { found.contains($0) } ?? false }
    }

    /// A text cut into sentences, the way the stream is.
    static func sentences(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        var start = 0
        for m in boundary.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = m.range.location + m.range.length
            out.append(ns.substring(with: NSRange(location: start, length: end - start)))
            start = end
        }
        if start < ns.length { out.append(ns.substring(from: start)) }
        return out
    }

    /// A sentence reduced to its letters and digits, for comparing word for word.
    static func key(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
