import Foundation

/// Checks for how the app reads the model's answers, run at launch in debug builds and again for
/// each overnight report. Each case is an answer written the way a small model really writes it:
/// a different key, a first name, a question mark, a bare true. The Nov 26 run lost "who is here"
/// and "where is Dolores" to a strict reading, and the reply left people out; these keep that from
/// coming back without a word. A failure is printed to the console and kept in `failures`.
@MainActor
enum ReadChecks {
    static private(set) var failures: [String] = []
    static private(set) var count = 0

    static func run() {
        var bad: [String] = []
        var n = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            n += 1
            if !ok { bad.append(what()) }
        }

        let cast = ["Dolores Reyes", "Elias Crane", "Mary Crane", "Arthur Hale"]
        let menu = cast + ["brass key", "the Velvet Thorn"]
        let places = ["The Velvet Thorn", "Back Alley"]
        typealias L = Looks.Look

        // The lookups, under any key and in any spelling.
        func looks(_ m: [String: Any], _ want: [L]) {
            let got = StoryEngine.readLooks(JSONExtract.plainKeys(m), menu: menu, cast: cast)
            check(got == want, "readLooks(\(m)) gave \(got.map(\.text)), wanted \(want.map(\.text))")
        }
        looks(["look": ["who is here"]], [L(kind: .whoIsHere)])
        looks(["lookup": "who is here"], [L(kind: .whoIsHere)])
        looks(["Lookups": ["Who's here?", "where is Dolores"]], [L(kind: .whoIsHere), L(kind: .whereIs, target: "Dolores Reyes")])
        looks(["look": ["Who else is here?"]], [L(kind: .whoIsHere)])
        looks(["look": ["Elias Crane"]], [L(kind: .lookAt, target: "Elias Crane")])
        looks(["look": ["look at the brass key"]], [L(kind: .lookAt, target: "brass key")])
        looks(["look": ["look at: Dolores"]], [L(kind: .lookAt, target: "Dolores Reyes")])
        looks(["look": "who is here, the time"], [L(kind: .whoIsHere), L(kind: .time)])
        looks(["look": ["time", "ways out", "Outside."]], [L(kind: .time), L(kind: .waysOut), L(kind: .outside)])
        looks(["look": ["backstory of Mr. Hale"]], [L(kind: .backstory, target: "Arthur Hale")])
        looks(["looks": ["Where's Mary?"]], [L(kind: .whereIs, target: "Mary Crane")])
        looks(["look": ["remember the studio"]], [L(kind: .remember, target: "the studio")])
        // Words that fit two people, or nobody, are not guessed.
        looks(["look": ["where is Crane"]], [])
        looks(["look": ["the moon landing"]], [])
        looks(["look": []], [])

        // A person or a place, however the form names them.
        for (raw, want) in [("Dolores", "Dolores Reyes"), ("dolores, the bartender", "Dolores Reyes"), ("Mr. Hale", "Arthur Hale"),
                            ("Mary Crane", "Mary Crane"), ("elias", "Elias Crane"), ("Crane", ""), ("nobody", ""), ("", "")] {
            let got = Looks.person(raw, in: cast)
            check(got == want, "Looks.person(\"\(raw)\") gave \"\(got)\", wanted \"\(want)\"")
        }
        for (raw, want) in [("the velvet thorn", "The Velvet Thorn"), ("Velvet Thorn.", "The Velvet Thorn"), ("back alley", "Back Alley"), ("the kitchen", "")] {
            let got = Looks.place(raw, in: places)
            check(got == want, "Looks.place(\"\(raw)\") gave \"\(got)\", wanted \"\(want)\"")
        }

        // Fields written as other JSON types.
        check(JSONExtract.text(true) == "yes", "text(true) should be yes")
        check(JSONExtract.text(["Dolores"]) == "Dolores", "text([\"Dolores\"]) should be Dolores")
        check(JSONExtract.text(3) == "3", "text(3) should be 3")
        check(JSONExtract.text(nil) == "", "text(nil) should be empty")
        check(JSONExtract.text(" Elias \n") == "Elias", "text should trim")
        check(JSONExtract.flag("Yes") == true, "flag(\"Yes\") should be true")
        check(JSONExtract.flag(false) == false, "flag(false) should be false")
        check(JSONExtract.flag(0) == false, "flag(0) should be false")
        check(JSONExtract.flag("maybe") == nil, "flag(\"maybe\") should be nil")
        let keys = JSONExtract.plainKeys(["New Place": "the cellar", "also-to": "Mary", "Look": ["the time"]])
        check(JSONExtract.text(keys["new_place"]) == "the cellar", "plainKeys should read \"New Place\" as new_place")
        check(JSONExtract.text(keys["also_to"]) == "Mary", "plainKeys should read \"also-to\" as also_to")
        check(keys["look"] != nil, "plainKeys should read \"Look\" as look")
        // A real reply from a model that ignored the grammar, end to end through the JSON reader.
        if let m = JSONExtract.object("Sure! ```json\n{\"To\": \"Dolores\", \"lookup\": [\"Who is here?\", \"where is Elias\"],}\n```") {
            let k = JSONExtract.plainKeys(m)
            check(Looks.person(JSONExtract.text(k["to"]), in: cast) == "Dolores Reyes", "the fenced reply's \"To\" should be Dolores Reyes")
            let got = StoryEngine.readLooks(k, menu: menu, cast: cast)
            check(got == [L(kind: .whoIsHere), L(kind: .whereIs, target: "Elias Crane")], "the fenced reply's lookups gave \(got.map(\.text))")
        } else {
            check(false, "JSONExtract.object couldn't read a fenced reply with a trailing comma")
        }

        // Where people are: a single object, keys in capitals, "yes" for true.
        let one = StoryEngine.whereabouts(["Name": "Dolores Reyes", "where": "behind the bar", "with_player": "yes"])
        check(one.count == 1 && one.first?.here == true, "whereabouts of a single object gave \(one.count) people")
        let two = StoryEngine.whereabouts([["name": "Elias Crane", "where": "by the door", "with_player": false],
                                           ["name": "Mary Crane", "where": "upstairs", "with_player": 0]])
        check(two.count == 2 && two.allSatisfy { $0.here == false }, "whereabouts with false and 0 should be two people, not here")

        // "Who is here?" asked every which way, and questions that aren't it.
        for q in ["Who is here with us now?", "Who's around tonight?", "So who all is in here with us?", "Who else is in the room?",
                  "Is anyone else here?", "Is there anybody else around?", "Who are all these people?"] {
            check(StoryEngine.asksWhoIsHere(q), "asksWhoIsHere(\"\(q)\") should be true")
        }
        for q in ["Who is she?", "What's your name?", "Where is the door?", "Who was in the war with you?", "Who here has a light?"] {
            check(!StoryEngine.asksWhoIsHere(q), "asksWhoIsHere(\"\(q)\") should be false")
        }

        // Real interest in the person you talk with opens one more of what they keep close.
        for q in ["How long have you lived here?", "Tell me more about that.", "Go on.", "That sounds hard.", "I'm sorry, that must have been lonely.",
                  "What happened after that?", "Do you miss your brother?", "Could you tell me more about the war?"] {
            check(StoryEngine.opensUp(q), "opensUp(\"\(q)\") should be true")
        }
        for q in ["Could you pour me another?", "Can you pass the salt?", "I sit down by the fire.", "Nice weather.", "Where is the door?"] {
            check(!StoryEngine.opensUp(q), "opensUp(\"\(q)\") should be false")
        }

        // Who the player speaks to, and who they only ask about (Nov 27: a question about the old
        // barber, put to his nephew, moved the talk to the barber).
        let earl = LoreEntry(name: "Earl Hollis", kind: .person, role: "the old barber")
        let hannah = LoreEntry(name: "Hannah Crane", kind: .person, role: "the grown daughter")
        check(!StoryEngine.addresses(earl, in: "I say: \"How long have you known the old barber?\""), "a question about the old barber isn't speaking to him")
        check(StoryEngine.addresses(earl, in: "I turn to the old barber. Then I say: \"How's business?\""), "turning to the old barber is speaking to him")
        check(StoryEngine.addresses(earl, in: "I say: \"Earl, how's business?\""), "\"Earl, ...\" is speaking to Earl")
        check(!StoryEngine.addresses(hannah, in: "I turn to the old keeper. Then I say: \"Is the grown daughter all right?\""), "asking after the daughter isn't speaking to her")

        // He and she after a name said inside someone's speech belong to the speaker (Nov 27).
        let walter = Continuity.pronounCounts(in: "\"Walter's right there behind you,\" she says softly. \"And the costumer? She's got her sketchbook open.\"", for: "Walter Pruitt", others: ["Walter", "Dolores"])
        check(walter.she == 0, "the speaker's \"she says\" was counted for Walter (\(walter.she))")
        let elias = Continuity.pronounCounts(in: "Elias sets down the tool. \"Fine,\" he says, and he turns back.", for: "Elias Crane", others: ["Elias"])
        check(elias.he == 2, "Elias's own \"he says\" should count (\(elias.he))")
        // Role-named newcomer ("The old man") must never match bare "The" or steal the speaker's "she/her".
        let oldMan = Continuity.pronounCounts(in: "She pushes it across the counter, then spins back to face the old man, gesturing with her free hand. \"If he starts talking,\" she says.", for: "The old man", others: ["Marlene", "Sal", "man"])
        check(oldMan.she == 0, "Marlene's \"she/her\" was counted for The old man (\(oldMan.she))")

        // speaksForPlayer must never flag an NPC saying "You said earlier..." inside spoken quotes.
        check(!Continuity.speaksForPlayer("She leans forward. \"You said earlier you didn't have much.\" Her eyes search yours."), "NPC quote starting with \"You said\" should not trigger speaksForPlayer")
        check(Continuity.speaksForPlayer("\"I'll take coffee,\" you say softly."), "narration tag \"you say\" after quote should trigger speaksForPlayer")

        // VoiceCast clause-aware speaker attribution, shared surname, & distinct voice assignment.
        let vcCast = [
            LoreEntry(name: "Walter Pruitt", kind: .person, role: "the bartender"),
            LoreEntry(name: "Dolores Reyes", kind: .person, role: "the friendly regular"),
        ]
        let vcFacts = ["Walter Pruitt uses he/him.", "Dolores Reyes uses she/her."]
        let vc = VoiceCast.build(cast: vcCast, facts: vcFacts, narratorKokoro: "am_michael", narratorAppleID: nil, defaultSpeaker: "Walter Pruitt")
        check(vc.characters.allSatisfy { $0.kokoroVoice != "am_michael" }, "VoiceCast should not collide with narrator am_michael")
        check(Set(vc.characters.map(\.kokoroVoice)).count == 2, "VoiceCast should give distinct Kokoro voices to Walter and Dolores")
        let s1 = vc.matchSpeaker(in: "He turns to the neighbor stools where the friendly regular hums, then back to you.")
        check(s1?.name == "Walter Pruitt", "subordinate mention of regular should not steal speaker from Walter (got \(s1?.name ?? "nil"))")
        var inQ = false
        var curSp: String? = "Walter Pruitt"
        let segs = vc.segment("\"My name's Dolores,\" the friendly regular says.", inQuote: &inQ, currentSpeaker: &curSp)
        check(segs.first(where: \.isDialogue)?.speaker?.name == "Dolores Reyes", "post-quote tag should attribute quote to Dolores")

        // Two-male shared-surname cast (Earl Hollis & Marcus Hollis) with empty defaultSpeaker.
        let hollisCast = [
            LoreEntry(name: "Earl Hollis", kind: .person, role: "the old barber"),
            LoreEntry(name: "Marcus Hollis", kind: .person, role: "the young apprentice"),
        ]
        let hollisFacts = ["Earl Hollis uses he/him.", "Marcus Hollis uses he/him."]
        let hvc = VoiceCast.build(cast: hollisCast, facts: hollisFacts, narratorKokoro: "am_michael", narratorAppleID: nil, defaultSpeaker: "")
        check(hvc.matchSpeaker(in: "Inside, Hollis watches you settle back into the leather.")?.name == "Earl Hollis", "shared surname Hollis should resolve to senior barber Earl Hollis")
        check(hvc.matchSpeaker(in: "You step across the linoleum as you approach the stool where the old barber sits.")?.name == "Earl Hollis", "single unambiguous character mention should resolve to Earl Hollis")

        // Fire hydrant must not map to indoor fireplace.
        check(Rules.icon(for: "a fire hydrant") != "fireplace", "fire hydrant should not map to fireplace (got \(Rules.icon(for: "a fire hydrant")))")

        // RoomBuilder room-type library & unknown-room fallback detection.
        for (place, wantType) in [
            ("La Boulangerie", "bakery"), ("The Little Bakery", "bakery"),
            ("The Corner Café", "café"), ("The Dining Room", "dining room"),
            ("The Public Library", "library"), ("The Clockmaker's Workshop", "workshop"),
            ("The Grand Lobby", "lobby"), ("The Stone Chapel", "chapel"),
            ("The Train Car", "train car"), ("The Back Porch", "porch"),
            ("The Brass Observatory", "other"), ("The Photo Darkroom", "other"),
        ] {
            let got = RoomBuilder.type(for: place)
            check(got == wantType, "RoomBuilder.type(for: \"\(place)\") gave \"\(got)\", wanted \"\(wantType)\"")
        }

        // All 6 curated PrebuiltWorlds load with valid maps, casts, doors, and clocks.
        for exp in CuratedExperiences.all {
            let built = PrebuiltWorlds.adventure(for: exp, player: PlayerDetails(name: "", age: 0, gender: "", interest: ""))
            check(built != nil, "PrebuiltWorlds missing for \(exp.title)")
            if let a = built, let r = a.room {
                check(r.player != nil, "Prebuilt \(exp.title) missing player on map")
                check(a.cast.count >= 2, "Prebuilt \(exp.title) has fewer than 2 cast (\(a.cast.count))")
                check(r.objects.count >= 3, "Prebuilt \(exp.title) has too few objects (\(r.objects.count))")
                check(!r.doors.isEmpty, "Prebuilt \(exp.title) missing doors")
                check(a.clock != nil, "Prebuilt \(exp.title) missing clock")
            }
        }

        count = n
        failures = bad
        for b in bad { print("ReadChecks failed: " + b) }
    }
}
