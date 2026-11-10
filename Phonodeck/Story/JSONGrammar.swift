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

    /// The Game Master's review of the reply just written (see `Prompts.review`).
    static let review = [
        "root ::= \"{\" ws " + [
            key("fixes") + " list3",
            key("facts") + " list12",
            key("unanswered") + " str",
            key("scene") + " str",
            key("time") + " str",
            key("timeline") + " list3",
            key("people") + " people",
            key("next") + " str",
        ].joined(separator: " \",\" ws ") + " ws \"}\"",
        list("list3", 3),
        list("list12", 12),
        #"people ::= "[" ws ( person ( "," ws person ){0,5} )? ws "]""#,
        "person ::= \"{\" ws " + [key("name") + " str", key("where") + " str", key("doing") + " str", key("heading") + " str"]
            .joined(separator: " \",\" ws ") + " ws \"}\"",
        common,
    ].joined(separator: "\n")

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
