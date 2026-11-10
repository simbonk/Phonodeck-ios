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
        let names = cast.filter { n in
            !n.isEmpty && n.count <= 40 && n.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || " -.'".unicodeScalars.contains($0) }
        }
        let who = names.isEmpty ? "who ::= s40" : "who ::= " + names.map { "\"\\\"" + $0 + "\\\"\"" }.joined(separator: " | ")
        // How many more names may follow the first.
        let more = names.isEmpty ? 5 : names.count - 1
        return [
            "root ::= \"{\" ws " + [
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
            ].joined(separator: " \",\" ws ") + " ws \"}\"",
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

    /// One of a fixed set of answers, as a JSON string. Names that can't be spelled safely in a
    /// grammar are left out.
    private static func choice(_ name: String, _ options: [String]) -> String {
        let safe = options.filter { n in
            !n.isEmpty && n.count <= 60 && n.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || " -.',".unicodeScalars.contains($0) }
        }
        return name + " ::= " + safe.map { "\"\\\"" + $0 + "\\\"\"" }.joined(separator: " | ")
    }

    /// The reading of the player's new message (see `Prompts.readPlayer`): who they turn to and
    /// where they go are picked from what exists, never written freely.
    static func intent(cast: [String], places: [String]) -> String {
        [
            "root ::= \"{\" ws " + [
                key("to") + " who",
                key("going") + " where",
                key("answer") + " s240",
                key("beat") + " s240",
            ].joined(separator: " \",\" ws ") + " ws \"}\"",
            choice("who", cast + ["nobody"]),
            choice("where", ["staying"] + places + ["somewhere new"]),
            capped("s240", 240),
            common,
        ].joined(separator: "\n")
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
