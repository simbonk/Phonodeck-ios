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

    private static let speechVerbs = #"(?:says|said|asks|asked|replies|replied|answers|answered|adds|added|mutters|muttered|whispers|whispered|murmurs|murmured|chuckles|chuckled|laughs|laughed|calls|called|continues|continued|repeats|repeated|offers|offered|teases|teased|tells|told|corrects|corrected|interrupts|interrupted|grumbles|grumbled|sighs|sighed|speaks|spoke|chimes|chimed|pipes|piped)"#

    private static let invertedSpeechVerbs = #"(?:says|said|asks|asked|replies|replied|answers|answered|adds|added|mutters|muttered|whispers|whispered|murmurs|murmured|chuckles|chuckled|laughs|laughed|calls|called|continues|continued|repeats|repeated|grumbles|grumbled|sighs|sighed|speaks|spoke)"#

    private static let transitiveVerbs = #"(?:watch|watches|watched|watching|eye|eyes|eyed|eyeing|see|sees|saw|seeing|notice|notices|noticed|noticing|hear|hears|heard|hearing|tell|tells|told|telling|ask|asks|asked|asking|hand|hands|handed|handing|pass|passes|passed|passing|offer|offers|offered|offering|show|shows|showed|showing|face|faces|faced|facing|ignore|ignores|ignored|ignoring|study|studies|studied|studying|leave|leaves|left|leaving|catch|catches|caught|catching|mention|mentions|mentioned|mentioning|address|addresses|addressed|addressing|remind|reminds|reminded|reminding|warn|warns|warned|warning|join|joins|joined|joining|follow|follows|followed|following|meet|meets|met|meeting|greet|greets|greeted|greeting)"#

    private static let subordinateClausePattern = #"\b(?:where|while|who|whom|whose|which|when|whenever|until|before|after|since|though|although|because|as)\b[^,;—–.!?]*"#

    private static let prepositionalPhrasePattern = #"\b(?:toward|towards|at|past|behind|beside|near|about|of|to|for|with|from|than|like|into|onto|over|across|against|around|between|opposite|by|in|on|under|along|through)\b(?:\s+(?!and\b|but\b|then\b|so\b|yet\b)[^,;—–.!?\s]+)*"#

    private func subjectPatterns(for c: CharacterVoice) -> [String] {
        var pats = [#"\b"# + NSRegularExpression.escapedPattern(for: c.name.lowercased()) + #"\b"#]
        if c.firstName.count >= 3 {
            pats.append(#"\b"# + NSRegularExpression.escapedPattern(for: c.firstName) + #"\b"#)
        }
        if c.fullRole.count >= 4 {
            pats.append(#"\b(?:the\s+)?"# + NSRegularExpression.escapedPattern(for: c.fullRole) + #"\b"#)
        }
        if !c.roleHead.isEmpty {
            // Require definite article so adjective uses like "his regular coffee" never match "the regular".
            pats.append(#"\bthe\s+(?:[a-z'-]+\s+){0,2}"# + NSRegularExpression.escapedPattern(for: c.roleHead) + #"\b"#)
        }
        if c.gender == .male, characters.filter({ $0.gender == .male }).count == 1 {
            pats.append(#"\bhe\b"#)
        }
        if c.gender == .female, characters.filter({ $0.gender == .female }).count == 1 {
            pats.append(#"\bshe\b"#)
        }
        return pats
    }

    private func targetPatterns(for c: CharacterVoice) -> [String] {
        var pats = [NSRegularExpression.escapedPattern(for: c.name.lowercased())]
        if c.firstName.count >= 3 { pats.append(NSRegularExpression.escapedPattern(for: c.firstName)) }
        if c.fullRole.count >= 4 { pats.append(NSRegularExpression.escapedPattern(for: c.fullRole)) }
        if !c.roleHead.isEmpty { pats.append(NSRegularExpression.escapedPattern(for: c.roleHead)) }
        return pats
    }

    private func lastMatch(of pattern: String, in text: String) -> String.Index? {
        var found: String.Index? = nil
        var start = text.startIndex
        while start < text.endIndex,
              let r = text.range(of: pattern, options: .regularExpression, range: start..<text.endIndex) {
            found = r.lowerBound
            start = r.upperBound > start ? r.upperBound : text.index(after: start)
        }
        return found
    }

    private func stripSubordinateClauses(in sentence: String) -> String {
        sentence.replacingOccurrences(of: Self.subordinateClausePattern, with: " ", options: .regularExpression)
    }

    private func stripNonSubjectClauses(in sentence: String) -> String {
        var s = stripSubordinateClauses(in: sentence)
        s = s.replacingOccurrences(of: Self.prepositionalPhrasePattern, with: " ", options: .regularExpression)
        for c in characters {
            for t in targetPatterns(for: c) {
                let objPat = #"\b"# + Self.transitiveVerbs + #"\s+(?:the\s+(?:[a-z'-]+\s+){0,2}|a\s+|an\s+)?"# + t + #"(?:'s|’s)?\b"#
                s = s.replacingOccurrences(of: objPat, with: " ", options: .regularExpression)
                // Strip trailing absolute participial background clauses (", the friendly regular still humming").
                let partPat = #"[,;—–]\s*(?:the\s+(?:[a-z'-]+\s+){0,2})?"# + t + #"\s+(?:still\s+|quietly\s+|softly\s+|slowly\s+)?[a-z]+ing\b[^,;—–.!?]*"#
                s = s.replacingOccurrences(of: partPat, with: " ", options: .regularExpression)
            }
        }
        return s
    }

    private func matchSpeechVerb(in sentence: String, isPostQuoteTag: Bool) -> CharacterVoice? {
        let stripped = stripSubordinateClauses(in: sentence)
        var best: (CharacterVoice, String.Index)? = nil
        for c in characters {
            for sp in subjectPatterns(for: c) {
                let pat = sp + #"(?:\s+[a-z'-]+ly)?\s+"# + Self.speechVerbs + #"\b"#
                if let idx = lastMatch(of: pat, in: stripped) {
                    if best == nil || idx > best!.1 { best = (c, idx) }
                }
            }
        }
        if let found = best { return found.0 }
        if isPostQuoteTag {
            for c in characters {
                for sp in subjectPatterns(for: c) {
                    let pat = #"^[,;—–\s]*"# + Self.invertedSpeechVerbs + #"\s+"# + sp
                    if stripped.range(of: pat, options: .regularExpression) != nil {
                        return c
                    }
                }
            }
        }
        return nil
    }

    private func findLastSubject(in skeleton: String) -> CharacterVoice? {
        var best: (CharacterVoice, String.Index)? = nil
        for c in characters {
            for pat in subjectPatterns(for: c) {
                if let idx = lastMatch(of: pat, in: skeleton) {
                    if best == nil || idx > best!.1 { best = (c, idx) }
                }
            }
        }
        return best?.0
    }

    /// Finds the acting/speaking character in a narration cue (e.g. "Walter says", "the regular chuckles",
    /// "she whispers"), ignoring characters mentioned only in subordinate clauses, prepositional phrases,
    /// or as direct objects ("He turns to the neighbor stools where the friendly regular hums, then back to you." -> Walter).
    func matchSpeaker(in narration: String, isPostQuoteTag: Bool = false) -> CharacterVoice? {
        let low = narration.lowercased()
        guard low.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return nil }

        let sentences = low
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return nil }

        // For a post-quote attribution tag, only the first sentence belongs to the preceding quote.
        let ordered = isPostQuoteTag ? [sentences[0]] : Array(sentences.reversed())

        for sent in ordered {
            // 1. Explicit speaking-verb attribution ("she tells the bartender", "says Dolores").
            if let sp = matchSpeechVerb(in: sent, isPostQuoteTag: isPostQuoteTag) {
                return sp
            }
            // 2. Main-clause grammatical subject after stripping subordinate/prepositional/object mentions.
            let skeleton = stripNonSubjectClauses(in: sent)
            if let sp = findLastSubject(in: skeleton) {
                return sp
            }
            // 3. Unambiguous possessive pronoun fallback ("His voice drops low.", "Her eyes light up.").
            let hasHis = skeleton.range(of: #"\bhis\b"#, options: .regularExpression) != nil
            let hasHer = skeleton.range(of: #"\bher\b"#, options: .regularExpression) != nil
            if hasHis && !hasHer {
                let masc = characters.filter { $0.gender == .male }
                if masc.count == 1 { return masc[0] }
            }
            if hasHer && !hasHis {
                let fem = characters.filter { $0.gender == .female }
                if fem.count == 1 { return fem[0] }
            }
        }
        return nil
    }

    /// True when the narration immediately following a closing quote is a dialogue tag for that quote
    /// (`"Bob," he repeats.` or `"Good?" she asks.`), rather than an unrelated next sentence (`"Good." Dolores hums.`).
    private func looksLikeDialogueTag(quote: String, after: String) -> Bool {
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return false }
        if let last = q.last, last == "," || last == "—" || last == "–" { return true }
        if let first = a.first, first.isLowercase { return true }
        let firstSentence = a.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? a
        return matchSpeechVerb(in: firstSentence.lowercased(), isPostQuoteTag: true) != nil
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
                // Narration updates who's currently acting/speaking if a person is the grammatical subject.
                if let matched = matchSpeaker(in: piece) {
                    currentSpeaker = matched.name
                }
                out.append(Segment(text: piece, speaker: nil, isDialogue: false))
            } else {
                // Dialogue: if the immediately following narration is an attribution tag for this quote
                // ("\"Bob,\" he repeats" or "\"My name's Dolores,\" the regular says"), prefer it.
                if idx + 1 < rawSpans.count, !rawSpans[idx + 1].isDialogue,
                   looksLikeDialogueTag(quote: piece, after: rawSpans[idx + 1].text),
                   let after = matchSpeaker(in: rawSpans[idx + 1].text, isPostQuoteTag: true) {
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
