import AVFoundation
import Foundation

/// Assigns a distinct, stable voice to each character in a story and splits streamed story text
/// into Narration vs. Character Dialogue segments so Phonodeck plays like a true multi-voice audio drama.
struct VoiceCast {
    /// Settings toggle (on by default).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "multiVoiceCast") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "multiVoiceCast") }
    }

    enum Gender { case male, female, neutral }

    struct CharacterVoice: Equatable {
        let name: String
        let firstName: String
        let fullRole: String
        let roleHead: String
        let gender: Gender
        let voiceHint: String
        let kokoroVoice: String
        let qwenVoice: String
        let appleVoiceID: String?
        let applePitch: Float
    }

    struct Segment {
        let text: String
        let speaker: CharacterVoice?
        let isDialogue: Bool
    }

    let characters: [CharacterVoice]
    let defaultSpeakerName: String

    static let empty = VoiceCast(characters: [], defaultSpeakerName: "")

    /// Deterministically casts distinct voices for everyone in `cast`, avoiding collision with
    /// the user's chosen Narrator voice.
    @MainActor
    static func build(cast: [LoreEntry], facts: [String], narratorKokoro: String, narratorAppleID: String?, defaultSpeaker: String) -> VoiceCast {
        let people = cast.filter { !$0.isPlayer && !$0.name.isEmpty }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !people.isEmpty else { return .empty }

        let femaleUS = ["af_bella", "af_sarah", "af_nicole", "af_heart"]
        let femaleUK = ["bf_emma", "bf_isabella"]
        let maleDeep = ["am_adam", "bm_george", "am_fenrir", "am_michael"]
        let maleLight = ["am_michael", "bm_fable", "bm_lewis", "am_adam"]

        var usedKokoro: Set<String> = [narratorKokoro]
        let installedApple = Narrator.appleVoices.filter { $0.identifier != narratorAppleID }
        var usedApple: Set<String> = []
        if let narratorAppleID { usedApple.insert(narratorAppleID) }

        let genericRoles: Set<String> = ["man", "woman", "girl", "boy", "lady", "person", "guy", "one", "figure", "stranger", "friend", "guest"]

        func pronoun(for name: String) -> Gender {
            guard let f = facts.first(where: { $0.hasPrefix(name + " uses ") }) else { return .neutral }
            let low = f.lowercased()
            if low.contains("she") { return .female }
            if low.contains("he") { return .male }
            return .neutral
        }

        func pickKokoro(gender: Gender, hint: String, index: Int) -> String {
            let low = hint.lowercased()
            let wantsUK = low.range(of: #"\b(british|english|scottish|irish|london|yorkshire|posh|crisp|accent)\b"#, options: .regularExpression) != nil
            let wantsDeep = low.range(of: #"\b(deep|low|rough|gravel|gruff|clipped|steady|measured|baritone|calm|dry|serious)\b"#, options: .regularExpression) != nil
            let pool: [String]
            switch gender {
            case .female:
                pool = wantsUK ? (femaleUK + femaleUS) : (femaleUS + femaleUK)
            case .male:
                if wantsUK {
                    pool = ["bm_george", "bm_lewis", "bm_fable"] + maleDeep
                } else {
                    pool = wantsDeep ? (maleDeep + maleLight) : (maleLight + maleDeep)
                }
            case .neutral:
                pool = (index % 2 == 0) ? (femaleUS + maleLight) : (maleLight + femaleUS)
            }
            if let free = pool.first(where: { !usedKokoro.contains($0) }) {
                usedKokoro.insert(free)
                return free
            }
            return pool[index % max(1, pool.count)]
        }

        func pickApple(gender: Gender, index: Int) -> (String?, Float) {
            let preferredNames: [String] = gender == .female
                ? ["Samantha", "Ava", "Zoe", "Allison", "Karen", "Martha", "Moira", "Tessa", "Serena", "Victoria"]
                : gender == .male
                ? ["Daniel", "Aaron", "Alex", "Arthur", "Oliver", "Tom", "Evan", "Nathan", "Lee", "Jamie"]
                : []
            if let match = installedApple.first(where: { v in
                !usedApple.contains(v.identifier) && preferredNames.contains(where: { v.name.localizedCaseInsensitiveContains($0) })
            }) {
                usedApple.insert(match.identifier)
                return (match.identifier, 1.0)
            }
            if let anyFree = installedApple.first(where: { !usedApple.contains($0.identifier) }) {
                usedApple.insert(anyFree.identifier)
                let pitch: Float = gender == .male ? 0.94 : gender == .female ? 1.06 : 1.0
                return (anyFree.identifier, pitch)
            }
            let pitch: Float = gender == .male ? 0.92 : gender == .female ? 1.08 : (index % 2 == 0 ? 0.96 : 1.04)
            return (nil, pitch)
        }

        var assigned: [CharacterVoice] = []
        for (i, c) in people.enumerated() {
            let g = pronoun(for: c.name)
            let hint = c.voice.isEmpty ? c.desc : c.voice
            let kokoro = pickKokoro(gender: g, hint: hint, index: i)
            let qwenBase = (g == .male && i % 2 == 0) ? "Aiden" : "Ryan"
            let cleanHint = hint.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            let qwen = cleanHint.isEmpty ? qwenBase : "\(qwenBase), \(cleanHint.prefix(90))."
            let (appleID, pitch) = pickApple(gender: g, index: i)
            let fullRole = Continuity.roleLabel(c.role).lowercased().replacingOccurrences(of: #"^(the|a|an)\s+"#, with: "", options: .regularExpression)
            let rawHead = fullRole.split(separator: " ").last.map(String.init) ?? ""
            let roleHead = (rawHead.count >= 4 && !genericRoles.contains(rawHead)) ? rawHead : ""
            assigned.append(CharacterVoice(
                name: c.name,
                firstName: Cards.first(c.name).lowercased(),
                fullRole: fullRole,
                roleHead: roleHead,
                gender: g,
                voiceHint: hint,
                kokoroVoice: kokoro,
                qwenVoice: qwen,
                appleVoiceID: appleID,
                applePitch: pitch
            ))
        }
        return VoiceCast(characters: assigned, defaultSpeakerName: defaultSpeaker)
    }

    /// Finds the acting/speaking character in a narration cue (e.g. "Walter says", "the regular chuckles",
    /// "she whispers"), ignoring characters mentioned only as the object of a glance or preposition
    /// ("She glances briefly toward the bartender" -> Dolores, not Walter).
    func matchSpeaker(in narration: String) -> CharacterVoice? {
        var low = narration.lowercased()
        guard low.count >= 2 else { return nil }

        // Remove character references that are merely the object of a preposition ("toward the bartender",
        // "at Dolores", "past Walter", "to the regular") so glancing at someone never steals the voice.
        let prep = #"\b(?:toward|towards|at|past|behind|beside|near|about|to|for|with|from|than|like)\s+(?:the\s+|a\s+|an\s+)?"#
        for c in characters {
            var targets = [c.name.lowercased()]
            if c.firstName.count >= 3 { targets.append(c.firstName) }
            if c.fullRole.count >= 4 { targets.append(c.fullRole) }
            if !c.roleHead.isEmpty { targets.append(c.roleHead) }
            for t in targets {
                let pat = prep + NSRegularExpression.escapedPattern(for: t) + #"\b"#
                low = low.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
            }
        }

        let words = Continuity.wordSet(low)

        // 1. Direct name or role match (take the last remaining subject mention in the narration).
        var best: (CharacterVoice, String.Index)? = nil
        func consider(_ c: CharacterVoice, range: Range<String.Index>?) {
            guard let r = range else { return }
            if best == nil || r.lowerBound > best!.1 { best = (c, r.lowerBound) }
        }
        for c in characters {
            consider(c, range: low.range(of: c.name.lowercased(), options: .backwards))
            if c.firstName.count >= 3, words.contains(c.firstName) {
                consider(c, range: low.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: c.firstName) + #"\b"#, options: [.regularExpression, .backwards]))
            }
            if c.fullRole.count >= 4 {
                consider(c, range: low.range(of: c.fullRole, options: .backwards))
            }
            if !c.roleHead.isEmpty, words.contains(c.roleHead) {
                consider(c, range: low.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: c.roleHead) + #"\b"#, options: [.regularExpression, .backwards]))
            }
        }
        if let found = best { return found.0 }

        // 2. Unambiguous pronoun cue ("he says", "she laughs", "her voice").
        let hasShe = low.range(of: #"\b(she|her|hers)\b"#, options: .regularExpression) != nil
        let hasHe = low.range(of: #"\b(he|him|his)\b"#, options: .regularExpression) != nil
        if hasShe && !hasHe {
            let fem = characters.filter { $0.gender == .female }
            if fem.count == 1 { return fem[0] }
        }
        if hasHe && !hasShe {
            let masc = characters.filter { $0.gender == .male }
            if masc.count == 1 { return masc[0] }
        }
        return nil
    }

    func character(named name: String) -> CharacterVoice? {
        guard !name.isEmpty else { return nil }
        return characters.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
                || $0.firstName == Cards.first(name).lowercased()
        }
    }

    /// Stateful parser that splits a streamed sentence/chunk into narration and quoted dialogue
    /// segments, preserving quote state and speaker identity across streamed chunks.
    func segment(_ chunk: String, inQuote: inout Bool, currentSpeaker: inout String?) -> [Segment] {
        guard !characters.isEmpty else {
            return [Segment(text: chunk, speaker: nil, isDialogue: false)]
        }

        // First split the chunk into raw (text, isDialogue) spans while tracking quote toggles.
        var rawSpans: [(text: String, isDialogue: Bool)] = []
        var buf = ""
        for ch in chunk {
            if ch == "\"" {
                if !buf.isEmpty {
                    rawSpans.append((buf, inQuote))
                    buf = ""
                }
                inQuote.toggle()
            } else if ch == "“" {
                if !buf.isEmpty {
                    rawSpans.append((buf, inQuote))
                    buf = ""
                }
                inQuote = true
            } else if ch == "”" {
                if !buf.isEmpty {
                    rawSpans.append((buf, inQuote))
                    buf = ""
                }
                inQuote = false
            } else {
                buf.append(ch)
            }
        }
        if !buf.isEmpty {
            rawSpans.append((buf, inQuote))
        }

        var out: [Segment] = []
        for idx in rawSpans.indices {
            let piece = rawSpans[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if !rawSpans[idx].isDialogue {
                // Narration updates who's currently acting/speaking if a person is named.
                if let matched = matchSpeaker(in: piece) {
                    currentSpeaker = matched.name
                }
                out.append(Segment(text: piece, speaker: nil, isDialogue: false))
            } else {
                // Dialogue: if the immediately following narration attributes this quote
                // ("\"Bob,\" he repeats" or "\"My name's Dolores,\" the regular says"), prefer it!
                if idx + 1 < rawSpans.count, !rawSpans[idx + 1].isDialogue,
                   let after = matchSpeaker(in: rawSpans[idx + 1].text) {
                    currentSpeaker = after.name
                }
                let resolved = currentSpeaker.flatMap { character(named: $0) }
                    ?? character(named: defaultSpeakerName)
                    ?? (characters.count == 1 ? characters[0] : nil)
                out.append(Segment(text: piece, speaker: resolved, isDialogue: true))
            }
        }
        return out
    }
}
