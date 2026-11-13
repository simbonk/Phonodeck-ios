import Foundation

/// GBNF grammars (llama.cpp's grammar format) for the JSON the background calls write. With a
/// GGUF storyteller, llama.cpp only lets the model pick tokens the grammar allows, so the output is
/// always one well-formed object with exactly these keys in this order, and every list is capped:
/// a small model can't echo the instructions back, run a list on forever ("Simon is not ... "
/// hundreds of times) or break the JSON. Strings stay free text, so the code checks in
/// StoryEngine still validate what is inside them. MLX models ignore grammars; their output is
/// checked the same way after the fact.
enum JSONGrammar {
    /// Shared rules: a JSON string (no raw control characters), and at most one space or line
    /// break between items, so whitespace can't loop either.
    private static let common = #"""
    ws ::= [ \n]?
    str ::= "\"" chr* "\""
    chr ::= [^"\\\x7F\x00-\x1F] | "\\" ["\\/nt]
    """#

    /// A list of up to `n` strings.
    private static func list(_ name: String, _ n: Int) -> String {
        n <= 1 ? #"\#(name) ::= "[" ws ( str )? ws "]""# : #"\#(name) ::= "[" ws ( str ( "," ws str ){0,\#(n - 1)} )? ws "]""#
    }

    /// `"key":` with optional space, for the rules below.
    private static func key(_ k: String) -> String { #""\"\#(k)\":" ws"# }

    /// A JSON string of at most `n` characters, so one value can't swallow the whole reply (a
    /// small model otherwise argues with itself inside a string until the room runs out).
    private static func capped(_ name: String, _ n: Int) -> String { #"\#(name) ::= "\"" chr{0,\#(n)} "\"""# }

    /// The Game Master's review of the reply just written (see `Prompts.review`). `cast` is the
    /// named people of this story: "here" (who is in the room with the player) may only hold
    /// those names, so presence is always about real people, spelled the way the code knows them.
    static func review(cast: [String]) -> String {
        let names = safe(cast, max: 40)
        let who = names.isEmpty ? "who ::= s40" : "who ::= " + names.map { "\"\\\"" + $0 + "\\\"\"" }.joined(separator: " | ")
        // How many more names may follow the first.
        let more = names.isEmpty ? 5 : names.count - 1
        let keys = [
            key("scene") + " s240",
            key("left") + " bool",
            key("here") + " here",
            key("people") + " people",
            key("carrying") + " items",
            key("things") + " items",
            key("time") + " s120",
            key("timeline") + " timeline",
            key("new_facts") + " newfacts",
            key("fixes") + " fixes",
            key("unanswered") + " s240",
            key("next") + " s400",
        ]
        return [
            "root ::= \"{\" ws " + keys.joined(separator: " \",\" ws ") + " ws \"}\"",
            more > 0 ? #"here ::= "[" ws ( who ( "," ws who ){0,\#(more)} )? ws "]""# : #"here ::= "[" ws ( who )? ws "]""#,
            who,
            #"people ::= "[" ws ( person ( "," ws person ){0,5} )? ws "]""#,
            "person ::= \"{\" ws " + [key("name") + " s40", key("where") + " s160", key("doing") + " s160", key("heading") + " s120"]
                .joined(separator: " \",\" ws ") + " ws \"}\"",
            #"items ::= "[" ws ( s60 ( "," ws s60 ){0,5} )? ws "]""#,
            #"timeline ::= "[" ws ( s160 ( "," ws s160 )? )? ws "]""#,
            #"newfacts ::= "[" ws ( s160 ( "," ws s160 ){0,2} )? ws "]""#,
            #"fixes ::= "[" ws ( s240 )? ws "]""#,
            #"bool ::= "true" | "false""#,
            capped("s40", 40), capped("s60", 60), capped("s120", 120), capped("s160", 160), capped("s240", 240), capped("s400", 400),
            common,
        ].joined(separator: "\n")
    }

    /// Names that can be spelled safely as grammar choices.
    private static func safe(_ options: [String], max: Int) -> [String] {
        options.filter { n in
            !n.isEmpty && n.count <= max && n.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || " -.',".unicodeScalars.contains($0) }
        }
    }

    /// One of a fixed set of answers, as a JSON string. Names that can't be spelled safely in a
    /// grammar are left out.
    private static func choice(_ name: String, _ options: [String]) -> String {
        return name + " ::= " + safe(options, max: 60).map { "\"\\\"" + $0 + "\\\"\"" }.joined(separator: " | ")
    }

    /// The first half of the read (see `Prompts.lookQuestion`): who the player turns to and where
    /// they go, picked from what exists, and up to three lookups from the fixed list in `Looks`.
    static func look(cast: [String], places: [String], cards: [String], people: [String]) -> String {
        let cardNames = safe(cards, max: 60)
        let personNames = safe(people, max: 40)
        var looks: [String] = Looks.Kind.allCases.filter { !$0.takesTarget }.map { #""\""# + $0.rawValue + #"\"""# }
        if !cardNames.isEmpty { looks.append(#""\"look at " lname "\"""#) }
        if !personNames.isEmpty { looks.append(#""\"where is " pname "\"""#) }
        looks.append(#""\"remember " topic "\"""#)
        return [
            "root ::= \"{\" ws " + [
                key("to") + " who",
                key("going") + " where",
                key("new_place") + " s40",
                key("takes") + " s40",
                key("puts_down") + " s40",
                key("spot") + " s60",
                key("tells") + " s80",
                key("body") + " s40",
                key("feels") + " s40",
                key("goal_step") + " s80",
                key("look") + " looks",
            ].joined(separator: " \",\" ws ") + " ws \"}\"",
            choice("who", cast + ["nobody"]),
            choice("where", ["staying"] + places + ["somewhere new"]),
            #"looks ::= "[" ws ( lk ( "," ws lk ){0,2} )? ws "]""#,
            "lk ::= " + looks.joined(separator: " | "),
            cardNames.isEmpty ? "" : "lname ::= " + cardNames.map { "\"" + $0 + "\"" }.joined(separator: " | "),
            personNames.isEmpty ? "" : "pname ::= " + personNames.map { "\"" + $0 + "\"" }.joined(separator: " | "),
            #"topic ::= [a-zA-Z0-9 ,'-]{3,40}"#,
            capped("s40", 40),
            capped("s60", 60),
            capped("s80", 80),
            common,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The second half of the read (see `Prompts.planQuestion`): the moment, planned from what was
    /// looked up.
    /// When the player asked something, the answer can't be left empty.
    static func plan(asked: Bool) -> String {
        [
            "root ::= \"{\" ws " + [
                key("does") + " s200",
                key("answer") + (asked ? " sans" : " s240"),
                key("beat") + " s240",
            ].joined(separator: " \",\" ws ") + " ws \"}\"",
            capped("s240", 240),
            capped("s200", 200),
            #"sans ::= "\"" chr{6,240} "\"""#,
            common,
        ].joined(separator: "\n")
    }

    /// One short answer after a reply (see `Prompts.rebuild`): a list of up to `n` strings of at
    /// most `chars` characters, under one key.
    static func strings(_ k: String, max n: Int, chars: Int) -> String {
        [
            "root ::= \"{\" ws " + key(k) + " items ws \"}\"",
            n <= 1 ? #"items ::= "[" ws ( s )? ws "]""# : #"items ::= "[" ws ( s ( "," ws s ){0,\#(n - 1)} )? ws "]""#,
            capped("s", chars),
            common,
        ].joined(separator: "\n")
    }

    /// One short free answer under one key.
    static func text(_ k: String, chars: Int) -> String {
        ["root ::= \"{\" ws " + key(k) + " s ws \"}\"", capped("s", chars), common].joined(separator: "\n")
    }

    /// Up to `n` names picked from a fixed list, under one key ([] for none).
    static func names(_ k: String, from options: [String], max n: Int) -> String {
        let ok = safe(options, max: 60)
        guard !ok.isEmpty else { return strings(k, max: 0, chars: 1).replacingOccurrences(of: "( s )?", with: "") }
        return [
            "root ::= \"{\" ws " + key(k) + " items ws \"}\"",
            n <= 1 ? #"items ::= "[" ws ( nm )? ws "]""# : #"items ::= "[" ws ( nm ( "," ws nm ){0,\#(n - 1)} )? ws "]""#,
            choice("nm", ok),
            common,
        ].joined(separator: "\n")
    }

    /// One choice from a fixed list, under one key, plus a short free name (for a new place).
    static func pickOne(_ k: String, from options: [String], free: String, chars: Int) -> String {
        [
            "root ::= \"{\" ws " + key(k) + " opt \",\" ws " + key(free) + " s ws \"}\"",
            choice("opt", options),
            capped("s", chars),
            common,
        ].joined(separator: "\n")
    }

    /// One choice from a fixed list, under one key.
    static func one(_ k: String, from options: [String]) -> String {
        [
            "root ::= \"{\" ws " + key(k) + " opt ws \"}\"",
            choice("opt", options),
            common,
        ].joined(separator: "\n")
    }

    /// A yes or no under one key, then a short text under another.
    static func yesNo(_ k: String, then k2: String, chars: Int) -> String {
        [
            "root ::= \"{\" ws " + key(k) + " yn \",\" ws " + key(k2) + " s ws \"}\"",
            choice("yn", ["yes", "no"]),
            capped("s", chars),
            common,
        ].joined(separator: "\n")
    }

    /// A yes or no under one key, then two short texts under their own keys.
    static func yesNo(_ k: String, then k2: String, _ c2: Int, and k3: String, _ c3: Int) -> String {
        [
            "root ::= \"{\" ws " + key(k) + " yn \",\" ws " + key(k2) + " sa \",\" ws " + key(k3) + " sb ws \"}\"",
            choice("yn", ["yes", "no"]),
            capped("sa", c2), capped("sb", c3),
            common,
        ].joined(separator: "\n")
    }

    /// Two short texts, each under its own key.
    static func pair(_ k1: String, _ c1: Int, _ k2: String, _ c2: Int) -> String {
        [
            "root ::= \"{\" ws " + key(k1) + " sa \",\" ws " + key(k2) + " sb ws \"}\"",
            capped("sa", c1), capped("sb", c2),
            common,
        ].joined(separator: "\n")
    }

    /// Three short texts, each under its own key.
    static func triple(_ k1: String, _ c1: Int, _ k2: String, _ c2: Int, _ k3: String, _ c3: Int) -> String {
        [
            "root ::= \"{\" ws " + key(k1) + " sa \",\" ws " + key(k2) + " sb \",\" ws " + key(k3) + " sc ws \"}\"",
            capped("sa", c1), capped("sb", c2), capped("sc", c3),
            common,
        ].joined(separator: "\n")
    }

    /// The room builder, question 1: the shell of a room (its type, size, doors, windows, and what
    /// is happening inside and outside).
    static func roomShell(types: [String], sizes: [String]) -> String {
        [
            "root ::= \"{\" ws " + [
                key("type") + " ty",
                key("size") + " sz",
                key("doors") + " doors",
                key("windows") + " wins",
                key("inside") + " s120",
                key("outside") + " s120",
            ].joined(separator: " \",\" ws ") + " ws \"}\"",
            choice("ty", types),
            choice("sz", sizes),
            choice("wall", ["north", "south", "east", "west"]),
            #"doors ::= "[" ws door ( "," ws door ){0,2} ws "]""#,
            "door ::= \"{\" ws " + key("wall") + " wall \",\" ws " + key("leads_to") + " s40 ws \"}\"",
            #"wins ::= "[" ws ( win ( "," ws win )? )? ws "]""#,
            "win ::= \"{\" ws " + key("wall") + " wall \",\" ws " + key("view") + " s60 ws \"}\"",
            capped("s40", 40), capped("s60", 60), capped("s120", 120),
            common,
        ].joined(separator: "\n")
    }

    /// The room builder, question 2: up to eight objects, each with a kind and a zone from the lists.
    static func roomThings(kinds: [String], zones: [String]) -> String {
        [
            "root ::= \"{\" ws " + key("things") + " things ws \"}\"",
            #"things ::= "[" ws ( th ( "," ws th ){0,7} )? ws "]""#,
            "th ::= \"{\" ws " + [key("name") + " s40", key("kind") + " kd", key("made_of") + " s40", key("where") + " zn"]
                .joined(separator: " \",\" ws ") + " ws \"}\"",
            choice("kd", kinds),
            choice("zn", zones),
            capped("s40", 40),
            common,
        ].joined(separator: "\n")
    }

    /// The room builder, question 3: where each person is and who or what they face.
    static func roomPeople(names: [String], zones: [String], faces: [String]) -> String {
        let n = max(1, safe(names, max: 60).count)
        return [
            "root ::= \"{\" ws " + key("people") + " people ws \"}\"",
            #"people ::= "[" ws ( pp ( "," ws pp ){0,\#(n - 1)} )? ws "]""#,
            "pp ::= \"{\" ws " + [key("name") + " nm", key("where") + " zn", key("facing") + " fc"].joined(separator: " \",\" ws ") + " ws \"}\"",
            choice("nm", names),
            choice("zn", zones),
            choice("fc", faces),
            common,
        ].joined(separator: "\n")
    }

    /// After a reply: one person in view, as the moment leaves them (what they are doing, their
    /// expression, what they hold, where they are and what they face, the last two from lists).
    static func personNow(zones: [String], faces: [String]) -> String {
        [
            "root ::= \"{\" ws " + [key("doing") + " s80", key("expression") + " s40", key("holding") + " s40",
                                   key("where") + " zn", key("facing") + " fc"].joined(separator: " \",\" ws ") + " ws \"}\"",
            choice("zn", ["stays put"] + zones),
            choice("fc", faces),
            capped("s80", 80), capped("s40", 40),
            common,
        ].joined(separator: "\n")
    }

    /// After a reply: where the player is now in the room, and what they face.
    static func playerNow(zones: [String], faces: [String]) -> String {
        [
            "root ::= \"{\" ws " + key("where") + " zn \",\" ws " + key("facing") + " fc ws \"}\"",
            choice("zn", ["stays put"] + zones),
            choice("fc", faces),
            common,
        ].joined(separator: "\n")
    }

    /// The room builder's push-back: for each refused object ("1", "2", ...), a zone from its own
    /// list of zones that keep the rules.
    static func roomRetry(allowed: [[String]]) -> String {
        var rules: [String] = []
        var keys: [String] = []
        for (i, zs) in allowed.enumerated() {
            keys.append(key(String(i + 1)) + " z\(i + 1)")
            rules.append(choice("z\(i + 1)", zs))
        }
        return (["root ::= \"{\" ws " + keys.joined(separator: " \",\" ws ") + " ws \"}\""] + rules + [common]).joined(separator: "\n")
    }

    /// The foveated gate: a yes or no for each numbered card item, "1" to `n`, in order.
    static func gate(count n: Int) -> String {
        let keys = (1...max(1, n)).map { key(String($0)) + " yn" }
        return [
            "root ::= \"{\" ws " + keys.joined(separator: " \",\" ws ") + " ws \"}\"",
            choice("yn", ["yes", "no"]),
            common,
        ].joined(separator: "\n")
    }

    /// Building a place the player arrives in (see `Prompts.buildPlace`).
    static let place = [
        "root ::= \"{\" ws " + key("desc") + " s300 \",\" ws " + key("things") + " items ws \"}\"",
        #"items ::= "[" ws ( s60 ( "," ws s60 ){0,4} )? ws "]""#,
        capped("s300", 300), capped("s60", 60),
        common,
    ].joined(separator: "\n")

    /// Coming back to a place after a long time away (see `Prompts.awayQuestion`): who is still
    /// there, picked from the people left there, and up to two ordinary changes.
    static func away(people: [String]) -> String {
        let ok = safe(people, max: 60)
        return [
            "root ::= \"{\" ws " + key("still_here") + " here \",\" ws " + key("changes") + " items ws \"}\"",
            ok.isEmpty ? #"here ::= "[" ws "]""# : #"here ::= "[" ws ( nm ( "," ws nm ){0,5} )? ws "]""#,
            ok.isEmpty ? "" : choice("nm", ok),
            #"items ::= "[" ws ( s ( "," ws s )? )? ws "]""#,
            capped("s", 140),
            common,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The memory pass (see `Prompts.memory`).
    static let memory = [
        "root ::= \"{\" ws " + [
            key("events") + " list2",
            key("location") + " str",
            key("lore") + " lore",
            key("beats_done") + " list3",
            key("goal_progress") + " str",
            key("mood") + " mood",
        ].joined(separator: " \",\" ws ") + " ws \"}\"",
        list("list2", 2),
        list("list3", 3),
        #"lore ::= "[" ws ( entry ( "," ws entry ){0,3} )? ws "]""#,
        "entry ::= \"{\" ws " + [key("name") + " str", key("type") + " kind", key("role") + " str", key("desc") + " str"]
            .joined(separator: " \",\" ws ") + " ws \"}\"",
        #"kind ::= "\"person\"" | "\"place\"" | "\"item\"" | "\"faction\"""#,
        "mood ::= \"{\" ws " + [key("feeling") + " score", key("enjoying") + " str", key("leaving_plot") + " bool"]
            .joined(separator: " \",\" ws ") + " ws \"}\"",
        #"score ::= "10" | [0-9]"#,
        #"bool ::= "true" | "false""#,
        common,
    ].joined(separator: "\n")

    /// Where a finished story stands at its last line, for Continue (see `Prompts.ending`).
    static let ending = [
        "root ::= \"{\" ws " + [
            key("place") + " str",
            key("time") + " str",
            key("with_you") + " str",
            key("people") + " people",
            key("facts") + " list8",
            key("recap") + " str",
        ].joined(separator: " \",\" ws ") + " ws \"}\"",
        list("list8", 8),
        #"people ::= "[" ws ( person ( "," ws person ){0,5} )? ws "]""#,
        "person ::= \"{\" ws " + [key("name") + " str", key("where") + " str", key("doing") + " str"]
            .joined(separator: " \",\" ws ") + " ws \"}\"",
        common,
    ].joined(separator: "\n")
}
