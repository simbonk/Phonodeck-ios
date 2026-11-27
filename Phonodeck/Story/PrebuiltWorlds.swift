import Foundation

/// Hand-crafted, ready-to-play rooms and settled casts for the curated experiences.
/// Choosing "Ready-built room & cast" skips the slow architect, portrait, consistency-check,
/// and room-drawing passes (~40 LLM calls) and jumps straight into the opening narration.
enum PrebuiltWorlds {
    static let supportedIDs: Set<UUID> = [
        CuratedExperiences.speakeasy.id,
        CuratedExperiences.foggyLight.id,
        CuratedExperiences.allNightDiner.id,
        CuratedExperiences.barbershop.id,
        CuratedExperiences.leftBankBookshop.id,
        CuratedExperiences.skiLodge.id,
    ]

    static func hasPrebuilt(_ id: UUID) -> Bool {
        supportedIDs.contains(id)
    }

    static func summary(for id: UUID) -> String? {
        switch id {
        case CuratedExperiences.speakeasy.id:
            return "8×6 m speakeasy · the bartender behind the mahogany bar & the regular in the corner booth"
        case CuratedExperiences.foggyLight.id:
            return "7×6 m keeper's kitchen · the old keeper & his daughter around the pine table"
        case CuratedExperiences.allNightDiner.id:
            return "8×6 m highway diner · the night waitress behind the counter & the cook at the grill window"
        case CuratedExperiences.barbershop.id:
            return "6×7 m barbershop · the old barber at your chair & his apprentice sweeping by the window"
        case CuratedExperiences.leftBankBookshop.id:
            return "7×6 m bookshop · the owner behind the counter & the young poet in the armchair by the stove"
        case CuratedExperiences.skiLodge.id:
            return "8×7 m lodge great room · the lodge owner & the ski patroller around the stone fireplace"
        default:
            return nil
        }
    }

    static func adventure(for setup: Experience, player: PlayerDetails) -> Adventure? {
        switch setup.id {
        case CuratedExperiences.speakeasy.id:
            return speakeasy(setup: setup, player: player)
        case CuratedExperiences.foggyLight.id:
            return foggyLight(setup: setup, player: player)
        case CuratedExperiences.allNightDiner.id:
            return allNightDiner(setup: setup, player: player)
        case CuratedExperiences.barbershop.id:
            return barbershop(setup: setup, player: player)
        case CuratedExperiences.leftBankBookshop.id:
            return leftBankBookshop(setup: setup, player: player)
        case CuratedExperiences.skiLodge.id:
            return skiLodge(setup: setup, player: player)
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static func obj(
        _ name: String,
        icon: String,
        x: Int,
        y: Int,
        w: Int = 1,
        d: Int = 1,
        facing: Facing = .s,
        on: UUID? = nil,
        blocks: Blocks = .none,
        along: String? = nil,
        makeup: String = "",
        state: String = ""
    ) -> Thing {
        var t = Thing(kind: .object, name: name, icon: icon, x: x, y: y, w: w, d: d, facing: facing, on: on, blocks: blocks)
        t.along = along
        t.makeup = makeup
        t.state = state
        return t
    }

    private static func npcThing(
        _ name: String,
        x: Int,
        y: Int,
        facing: Facing,
        on: UUID? = nil,
        doing: String,
        wearing: String,
        expression: String = "settled",
        feeling: String = "calm",
        holding: [String] = []
    ) -> Thing {
        var t = Thing(kind: .person, name: name, icon: "", x: x, y: y, facing: facing, on: on)
        t.doing = doing
        t.wearing = wearing
        t.expression = expression
        t.feeling = feeling
        t.holding = holding
        return t
    }

    private static func playerThing(
        _ name: String,
        x: Int,
        y: Int,
        facing: Facing,
        on: UUID? = nil,
        doing: String,
        wearing: String
    ) -> Thing {
        var t = Thing(kind: .player, name: name.isEmpty ? "You" : name, icon: "", x: x, y: y, facing: facing, on: on)
        t.doing = doing
        t.wearing = wearing
        return t
    }

    private static func personLore(
        name: String,
        role: String,
        desc: String,
        wants: String,
        privateLife: String,
        ties: String,
        looks: String,
        wears: String,
        voice: String,
        habit: String,
        depths: [String]
    ) -> LoreEntry {
        var c = LoreEntry(name: name, kind: .person, desc: desc, role: role, known: false, wants: wants)
        c.privateLife = privateLife
        c.ties = ties
        c.looks = looks
        c.wears = wears
        c.voice = voice
        c.habit = habit
        c.depths = depths
        return c
    }

    private static func playerGenderFact(_ player: PlayerDetails) -> String? {
        let g = player.gender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return nil }
        return "You are \(g)."
    }

    private static func finish(
        setup: Experience,
        player: PlayerDetails,
        location: String,
        placeDesc: String,
        bible: String,
        clock: Int,
        eraDate: String,
        spot: String,
        scene: String,
        things: [String],
        ambience: String,
        body: String,
        feels: String,
        cast: [LoreEntry],
        whereabouts: [Whereabout],
        facts: [String],
        room: Room
    ) -> Adventure {
        var a = Adventure(setup: setup, title: setup.title.isEmpty ? "Untitled" : setup.title, minutes: max(5, setup.minutes))
        a.nameless = true
        a.playerName = player.name
        let interest = player.interest.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.setup.romance.isEmpty, !interest.isEmpty {
            a.setup.romance = "attracted to \(interest)"
        }
        a.bible = bible
        a.location = location
        a.visit(location, from: "")

        let playerDesc = [setup.who, setup.traits].filter { !$0.isEmpty }.joined(separator: ". ")
        a.lore = [
            LoreEntry(name: player.name.isEmpty ? "You" : player.name, kind: .person, desc: playerDesc, isPlayer: true),
            LoreEntry(name: location, kind: .place, desc: placeDesc),
        ] + cast

        for c in cast where !c.wants.isEmpty {
            a.wants[c.name.lowercased()] = c.wants
        }
        a.whereabouts = whereabouts

        a.clock = clock
        a.storyTime = Continuity.storyTime(clock: clock, old: eraDate)
        a.spot = spot
        a.scene = scene
        a.things = things
        a.placeThings[location.lowercased()] = things
        a.ambience[location.lowercased()] = ambience
        a.body = body
        a.feels = feels

        var allFacts = facts
        if let gf = playerGenderFact(player) {
            allFacts.insert(gf, at: min(2, allFacts.count))
        }
        a.facts = allFacts
        a.coreFacts = allFacts

        a.rooms = [room]
        a.roomID = room.id
        return a
    }

    // MARK: - 1. A Speakeasy in the Rain

    private static func speakeasy(setup: Experience, player: PlayerDetails) -> Adventure {
        let location = "The Hidden Speakeasy"

        let bar = obj("long mahogany bar", icon: "bar", x: 2, y: 1, w: 4, d: 1, blocks: .way, along: "wall", makeup: "polished dark mahogany with a brass footrail")
        let stool1 = obj("bar stool", icon: "stool", x: 3, y: 2, makeup: "turned oak with a worn leather seat")
        let stool2 = obj("empty bar stool", icon: "stool", x: 4, y: 2, makeup: "turned oak with a worn leather seat")
        let stool3 = obj("end bar stool", icon: "stool", x: 2, y: 2, makeup: "turned oak with a worn leather seat")
        let taps = obj("brass taps and steaming coffee pot", icon: "small", x: 4, y: 1, on: bar.id, makeup: "brass and enamel", state: "hot")
        let barLamp = obj("warm green glass bar lamp", icon: "small", x: 2, y: 1, on: bar.id, makeup: "brass and green glass", state: "lit")
        let shelf = obj("mirror-backed bottle shelf", icon: "shelf", x: 6, y: 0, w: 2, d: 1, blocks: .way, along: "wall", makeup: "dark oak and spotted mirror")
        let gramStand = obj("small wooden gramophone stand", icon: "table", x: 0, y: 2, makeup: "scratched walnut")
        let gramophone = obj("crackling brass-horn gramophone", icon: "small", x: 0, y: 2, on: gramStand.id, makeup: "oak and brass", state: "playing a soft jazz record")
        let booth = obj("velvet corner booth", icon: "sofa", x: 0, y: 5, w: 2, d: 1, facing: .n, blocks: .way, along: "wall", makeup: "faded burgundy velvet")
        let boothTable = obj("corner booth table", icon: "table", x: 1, y: 4, makeup: "round marble-topped oak", state: "draped with folded silk and a sewing kit")
        let sideTable = obj("small round table", icon: "table", x: 6, y: 3, makeup: "dark wood")
        let sideChair = obj("bentwood chair", icon: "chair", x: 6, y: 4, facing: .n, makeup: "bentwood")
        let floorLamp = obj("warm paper-shaded lamp", icon: "lamp", x: 7, y: 5, makeup: "brass stand with a warm amber shade", state: "lit")

        let walter = personLore(
            name: "Walter Pruitt",
            role: "the bartender",
            desc: "Serious, precise and quietly kind, tending a hidden downtown bar through Prohibition.",
            wants: "keep the bar dry and peaceful while saving every spare nickel",
            privateLife: "He is quietly saving every dollar to open a sunlit neighbourhood bakery in Pasadena once Prohibition ends.",
            ties: "Dolores: They have shared quiet rainy nights here since 1923, and Walter quietly keeps a fresh pot of coffee on for her late studio shifts without charging.",
            looks: "Trim 34-year-old man with neatly parted dark hair, calm grey eyes, and steady hands.",
            wears: "Crisp white shirt with rolled sleeves, black waistcoat, and a spotless linen apron.",
            voice: "Low, steady, measured baritone with a dry, unhurried calm.",
            habit: "Polishes each glass twice and checks the rim against the bar lamp.",
            depths: [
                "Walter Pruitt worries that pouring illegal liquor night after night is turning him into someone harder than he meant to be.",
                "Walter Pruitt once turned down a chance to go into business with his older brother before the war, and still regrets letting pride win.",
                "Walter Pruitt keeps a folded floor plan for a corner bakery in Pasadena inside his ledger, with his late mother's sourdough recipe tucked behind it."
            ]
        )

        let dolores = personLore(
            name: "Dolores Vega",
            role: "the friendly regular",
            desc: "Warm, lively studio seamstress who sits in the corner booth humming along with the jazz record.",
            wants: "finish the evening's costume stitching and catch her big break as lead designer",
            privateLife: "She is sure her big break at the movie studios is close, though rent on her tiny sewing room is two weeks overdue.",
            ties: "Walter: They have shared quiet rainy nights here since 1923, and Walter quietly keeps a fresh pot of coffee on for her late studio shifts without charging.",
            looks: "Bright-eyed 27-year-old woman with dark pinned waves, ink-smudged fingertips, and an easy smile.",
            wears: "Mustard wool cardigan over a dark skirt, with a brass thimble on her right thumb.",
            voice: "Warm, quick, musical alto with a bright laugh and soft California rhythm.",
            habit: "Hums under her breath and bites the end of her thread before knotting a stitch.",
            depths: [
                "Dolores Vega is quietly anxious about covering next month's rent on her sewing room if the studio delays paychecks again.",
                "Dolores Vega gave up a steady dressmaking job in San Diego to chase film work in Los Angeles and hasn't told her family how tight money gets.",
                "Dolores Vega has been secretly sketching a full wardrobe portfolio for a major silent drama, terrified the studio head will laugh if she ever shows it."
            ]
        )

        let pWalter = npcThing(walter.name, x: 3, y: 0, facing: .s, doing: "polishing a glass behind the mahogany bar", wearing: walter.wears, expression: "calm and attentive", feeling: "composed", holding: ["clean towel", "glass"])
        let pDolores = npcThing(dolores.name, x: 0, y: 5, facing: .ne, on: booth.id, doing: "hemming a velvet costume cuff in the corner booth", wearing: dolores.wears, expression: "warm and absorbed", feeling: "cheerful", holding: ["needle", "velvet cuff"])
        let pPlayer = playerThing(player.name, x: 3, y: 2, facing: .n, on: stool1.id, doing: "sitting at the bar, warming up out of the rain", wearing: "rain-soaked travel coat and damp shoes")

        var room = Room(
            name: location,
            type: "bar",
            width: 8,
            depth: 6,
            inside: "A low-ceilinged hidden speakeasy behind a downtown flower shop: warm amber lamplight over polished mahogany, rain drumming on the skylight overhead, and soft jazz crackling from the corner.",
            outside: "A heavy February downpour lashing downtown Los Angeles alleys.",
            sound: "Rain drumming steadily on the skylight and a crackling jazz record on the gramophone.",
            doors: [Opening(wall: .south, at: 3, width: 1, leadsTo: "flower shop back passage")],
            windows: [Opening(wall: .east, at: 1, width: 2, view: "rain-streaked alley bricks")],
            things: [bar, stool1, stool2, stool3, taps, barLamp, shelf, gramStand, gramophone, booth, boothTable, sideTable, sideChair, floorLamp, pWalter, pDolores, pPlayer],
            log: [
                "shell: The Hidden Speakeasy (8 × 6 m)",
                "place: long mahogany bar → north side",
                "place: velvet corner booth & gramophone → south-west corner",
                "enter: Walter Pruitt behind the bar; Dolores Vega in the corner booth; you on a bar stool"
            ],
            built: true
        )
        room.built = true

        let facts = [
            "Walter Pruitt uses he/him.",
            "Dolores Vega uses she/her.",
            "It is February 1925 in Los Angeles during Prohibition, and a heavy winter rainstorm is falling outside.",
            "You are a traveller new in town, soaked from the storm, with time to kill.",
            "Walter Pruitt is 34 years old.",
            "Walter Pruitt has lived and worked here for 12 years, since 1913.",
            "Walter Pruitt learned baking from his mother in Bakersfield before moving to Los Angeles as a young man.",
            "Walter Pruitt took over tending this back-room bar after the flower shop owner needed someone who kept quiet.",
            "Walter Pruitt is proud that nobody has ever been turned away cold or left alone in a storm on his watch.",
            "Dolores Vega is 27 years old.",
            "Dolores Vega has lived and worked here for 5 years, since 1920.",
            "Dolores Vega grew up sewing beside her aunt in San Diego before taking a train north to Los Angeles.",
            "Dolores Vega remembers mending a leading actress's torn gown five minutes before cameras rolled on a Culver City lot.",
            "Dolores Vega is proud of every stitch she turns out by hand, even when her name never reaches the credits."
        ]

        return finish(
            setup: setup,
            player: player,
            location: location,
            placeDesc: setup.place,
            bible: "Los Angeles, February 1925, during Prohibition. On a stormy night you have ducked through the back of a downtown flower shop into a quiet hidden speakeasy to wait out the rain. You sit on a stool at the long mahogany bar across from the serious, precise bartender, while a friendly regular hums over her sewing in the velvet corner booth beside a crackling gramophone.",
            clock: 21 * 60 + 5,
            eraDate: "Night (about 9:05 PM), February 1925",
            spot: "on a stool at the mahogany bar, facing the bartender",
            scene: "You sit on a stool at the long mahogany bar, coat damp from the storm. The bartender stands across the counter polishing a glass beneath a warm green lamp. In the south-west corner booth near the crackling gramophone, the friendly regular hems a dark velvet cuff.",
            things: ["long mahogany bar with brass taps", "steaming enamel coffee pot", "warm green glass bar lamp", "crackling brass-horn gramophone", "velvet corner booth with sewing kit", "rain-streaked skylight overhead"],
            ambience: "Rain drumming steadily on the skylight, a jazz record crackling softly on the gramophone, and warm amber lamplight over dark mahogany.",
            body: "soaked from the rain, starting to warm up",
            feels: "a little homesick, glad to be out of the storm",
            cast: [walter, dolores],
            whereabouts: [
                Whereabout(name: walter.name, at: "behind the long mahogany bar", doing: "polishing a glass", here: true, engaged: true),
                Whereabout(name: dolores.name, at: "in the velvet corner booth near the gramophone", doing: "sewing a costume cuff", here: true, engaged: false),
            ],
            facts: facts,
            room: room
        )
    }

    // MARK: - 2. Fog at the Light

    private static func foggyLight(setup: Experience, player: PlayerDetails) -> Adventure {
        let location = "The Keeper's Kitchen"

        let stove = obj("cast-iron kitchen stove", icon: "fireplace", x: 2, y: 0, w: 2, d: 1, blocks: .way, along: "wall", makeup: "blackened cast iron", state: "radiating steady heat")
        let kettle = obj("steaming tin kettle", icon: "small", x: 2, y: 0, on: stove.id, makeup: "dented tin", state: "hissing gently")
        let stairs = obj("spiral iron tower stair", icon: "stairs", x: 5, y: 0, w: 2, d: 2, blocks: .way, makeup: "painted black cast iron climbing to the lamp room")
        let cupboard = obj("painted pine pantry cupboard", icon: "shelf", x: 0, y: 0, w: 1, d: 2, blocks: .way, along: "wall", makeup: "faded sea-green pine")
        let table = obj("scrubbed pine kitchen table", icon: "table", x: 2, y: 2, w: 2, d: 1, makeup: "salt-worn white pine")
        let oilLamp = obj("kerosene table lamp and tin mugs", icon: "small", x: 3, y: 2, on: table.id, makeup: "brass lamp and chipped enamel mugs", state: "burning steady")
        let chairSouth = obj("pine kitchen chair", icon: "chair", x: 3, y: 3, facing: .n, makeup: "sturdy pine")
        let chairNorth = obj("keeper's wooden chair", icon: "chair", x: 2, y: 1, facing: .s, makeup: "weathered oak")
        let chairWest = obj("window chair", icon: "chair", x: 1, y: 2, facing: .e, makeup: "painted pine")
        let hooks = obj("coat hooks with yellow oilskins", icon: "shelf", x: 5, y: 5, w: 2, d: 1, blocks: .way, along: "wall", makeup: "iron hooks with dripping slickers")

        let elias = personLore(
            name: "Elias Crane",
            role: "the old keeper",
            desc: "Gruff, weathered and generous lighthouse keeper with forty years tending this point.",
            wants: "keep the foghorn on beat and make sure a stranded traveller gets warm tea",
            privateLife: "His knees ache on the spiral iron stairs now, and he dreads the day the Lighthouse Service insists he retire inland.",
            ties: "Hannah: Elias is Hannah's father; she grew up on this rock and trims the lamp as surely as he does, though he secretly fears he has kept her tied to the point too long.",
            looks: "Broad-shouldered 63-year-old man with a salt-grey beard, deep laugh lines, and sea-chapped knuckles.",
            wears: "Heavy navy wool Guernsey sweater, faded suspenders, and thick sea boots.",
            voice: "Deep, gravel-rough New England baritone, unhurried and warm underneath the gruffness.",
            habit: "Counts the seconds between blasts of the foghorn by tapping one thumb on the table.",
            depths: [
                "Elias Crane notices the spiral stairs taking his breath more each winter, though he refuses to complain in front of Hannah.",
                "Elias Crane still misses his wife Clara, who used to keep a small herb garden behind the sea wall before she passed ten years ago.",
                "Elias Crane has kept an unopened transfer inquiry from a school in Portland in his desk drawer, terrified that encouraging Hannah to go will leave him alone in the tower."
            ]
        )

        let hannah = personLore(
            name: "Hannah Crane",
            role: "the keeper's daughter",
            desc: "Practical, quick-witted woman who shares every watch on the tower and wonders what life looks like beyond the point.",
            wants: "keep her father steady through the fog while deciding whether to take a life on the mainland",
            privateLife: "She has been offered a teaching post in Portland next autumn and hasn't found the words to tell her father.",
            ties: "Elias: Hannah is Elias's grown daughter; she knows the lamp and foghorn by heart and quietly takes the midnight stair climb whenever his knees stiffen.",
            looks: "Clear-eyed 29-year-old woman with windblown auburn hair pinned back and capable hands.",
            wears: "Dark wool skirt, cream knit shawl, and a heavy linen apron.",
            voice: "Clear, brisk, warm alto with dry Maine humour.",
            habit: "Turns the brass lamp wick down a hair whenever it begins to smoke.",
            depths: [
                "Hannah Crane gets restless when the sea fog pins them indoors for three days running.",
                "Hannah Crane turned down a courtship from a harbour boatbuilder years ago because she couldn't bear leaving Elias right after her mother died.",
                "Hannah Crane has already written half an acceptance letter to a small schoolhouse in Portland, folded inside her Almanac upstairs."
            ]
        )

        let pElias = npcThing(elias.name, x: 2, y: 1, facing: .s, on: chairNorth.id, doing: "warming his hands over a tin mug across the pine table", wearing: elias.wears, expression: "weathered and welcoming", feeling: "steady", holding: ["tin mug"])
        let pHannah = npcThing(hannah.name, x: 1, y: 2, facing: .e, on: chairWest.id, doing: "trimming a spare wick beside the kerosene lamp", wearing: hannah.wears, expression: "alert and friendly", feeling: "warm", holding: ["cloth", "wick trimmer"])
        let pPlayer = playerThing(player.name, x: 3, y: 3, facing: .n, on: chairSouth.id, doing: "sitting at the pine table out of the sea fog", wearing: "damp wool coat and dusty walking boots")

        let room = Room(
            name: location,
            type: "kitchen",
            width: 7,
            depth: 6,
            inside: "The snug stone-walled kitchen at the foot of a Maine lighthouse: glowing cast-iron stove, scrubbed pine table lit by a brass kerosene lamp, yellow oilskins dripping by the door, and a spiral iron stair climbing up into the tower.",
            outside: "Thick white sea fog blanketing the wet coastal rocks while the foghorn booms at steady intervals.",
            sound: "The low boom of the foghorn every thirty seconds, surf muttering below the rocks, and the kettle hissing on the stove.",
            doors: [Opening(wall: .south, at: 3, width: 1, leadsTo: "wet coastal rocks and fog")],
            windows: [Opening(wall: .west, at: 2, width: 2, view: "thick white sea fog pressing against the panes")],
            things: [stove, kettle, stairs, cupboard, table, oilLamp, chairSouth, chairNorth, chairWest, hooks, pElias, pHannah, pPlayer],
            log: [
                "shell: The Keeper's Kitchen (7 × 6 m)",
                "place: cast-iron stove & spiral iron tower stair → north wall",
                "place: scrubbed pine table → centre",
                "enter: Elias Crane & Hannah Crane at the pine table; you seated across from Elias"
            ],
            built: true
        )

        let facts = [
            "Elias Crane uses he/him.",
            "Hannah Crane uses she/her.",
            "It is an October evening in 1910 on the coast of Maine, wrapped in thick sea fog.",
            "You are a traveller walking the coast road who was caught by the fog and taken in for the evening.",
            "Elias Crane is 63 years old.",
            "Elias Crane has lived and worked here for 40 years, since 1870.",
            "Elias Crane sailed coastal schooners out of Bath before taking the keeper's post at the point.",
            "Elias Crane kept the lamp burning through the great November gale of 1898 without missing a turn.",
            "Elias Crane is proud that not a single vessel has grounded on these ledges in his forty years.",
            "Hannah Crane is 29 years old.",
            "Hannah Crane has lived and worked here for 29 years, since 1881.",
            "Hannah Crane learned arithmetic and geography from books brought out on the supply tender.",
            "Hannah Crane once climbed the tower in sleet to clear an iced-over ventilator when her father had fever.",
            "Hannah Crane is proud that she can read a changing tide or barometer faster than any harbour captain."
        ]

        return finish(
            setup: setup,
            player: player,
            location: location,
            placeDesc: setup.place,
            bible: "October 1910, on the rocky coast of Maine. Thick sea fog has rolled in off the water, and the old lighthouse keeper and his grown daughter have taken you into the warm stone kitchen at the foot of the tower while the foghorn booms outside.",
            clock: 20 * 60 + 15,
            eraDate: "Evening (about 8:15 PM), October 1910",
            spot: "at the scrubbed pine kitchen table across from the old keeper",
            scene: "You sit at the scrubbed pine table while the cast-iron stove radiates dry heat and the tin kettle hisses. Across from you sits the old keeper with a tin mug, while his daughter sits by the window trimming a brass wick. Behind them, the spiral iron stair climbs up toward the lamp room.",
            things: ["cast-iron stove with steaming tin kettle", "scrubbed pine kitchen table", "brass kerosene oil lamp and tin mugs", "spiral iron stair up to the lamp room", "yellow oilskins dripping on wall hooks", "fog-blinded window onto the sea rocks"],
            ambience: "The deep foghorn booming steadily outside, surf muttering against the rocks, and the kettle hissing softly on the iron stove.",
            body: "chilled and salt-damp from the fog, thawing by the stove",
            feels: "grateful for the warmth and curious about life on the point",
            cast: [elias, hannah],
            whereabouts: [
                Whereabout(name: elias.name, at: "across the scrubbed pine kitchen table", doing: "warming his hands over a mug", here: true, engaged: true),
                Whereabout(name: hannah.name, at: "by the window side of the pine table", doing: "trimming a spare lamp wick", here: true, engaged: false),
            ],
            facts: facts,
            room: room
        )
    }

    // MARK: - 3. Two A.M. on Route 66

    private static func allNightDiner(setup: Experience, player: PlayerDetails) -> Adventure {
        let location = "The Highway Diner"

        let counter = obj("chrome diner counter", icon: "counter", x: 2, y: 2, w: 4, d: 1, blocks: .way, along: "wall", makeup: "speckled Formica with a gleaming chrome edge")
        let passWindow = obj("pass-through grill window", icon: "counter", x: 2, y: 0, w: 2, d: 1, blocks: .none, along: "wall", makeup: "stainless steel order shelf with heat lamps")
        let pieCase = obj("glass pie case and coffee pot", icon: "small", x: 3, y: 2, on: counter.id, makeup: "chrome and curved glass", state: "two slices of cherry pie left")
        let register = obj("cash register with Pacific postcard", icon: "small", x: 5, y: 2, on: counter.id, makeup: "heavy chrome register", state: "sun-faded Santa Monica postcard taped to the side")
        let stool1 = obj("red vinyl stool", icon: "stool", x: 3, y: 3, makeup: "chrome stem with cracked red vinyl")
        let stool2 = obj("red vinyl stool", icon: "stool", x: 2, y: 3, makeup: "chrome stem with cracked red vinyl")
        let stool3 = obj("red vinyl stool", icon: "stool", x: 4, y: 3, makeup: "chrome stem with cracked red vinyl")
        let jukebox = obj("glowing chrome jukebox", icon: "piano", x: 0, y: 1, w: 1, d: 1, blocks: .way, makeup: "chrome and glowing amber tubes", state: "quietly humming on standby")
        let booth = obj("red vinyl corner booth", icon: "sofa", x: 0, y: 4, w: 2, d: 1, facing: .n, blocks: .way, along: "wall", makeup: "tufted red vinyl")
        let boothTable = obj("Formica booth table", icon: "table", x: 0, y: 3, makeup: "chrome-edged Formica")

        let marlene = personLore(
            name: "Marlene Doyle",
            role: "the night waitress",
            desc: "Sharp-tongued, warm-hearted graveyard waitress who calls everyone 'hon' and keeps the coffee fresh.",
            wants: "keep the lone 2 A.M. customer fed and talk away the quiet desert hours",
            privateLife: "She keeps a faded postcard of Santa Monica taped to the register and saves her tips in a coffee tin to move west, though she has never seen the ocean.",
            ties: "Sal: She and Sal have held down the graveyard shift together for six years; Sal always saves her the corner slice of pie and pretends not to notice when she counts her California tip jar.",
            looks: "Lively 36-year-old woman with pinned-up auburn curls, tired laugh lines, and sharp hazel eyes.",
            wears: "Pale turquoise cotton waitress dress, starched white apron, and well-worn white loafers.",
            voice: "Bright, snappy, affectionate alto with an easy Southwestern drawl.",
            habit: "Balances a coffee pot on one hip and taps her pencil against her order pad.",
            depths: [
                "Marlene Doyle wonders if she waits too long to pack her suitcase, she'll wake up fifty and still pouring coffee off Route 66.",
                "Marlene Doyle came out to Arizona following a husband who drifted on to Nevada, and never felt like going back home to Oklahoma.",
                "Marlene Doyle has enough saved in her coffee tin to leave next month, but hasn't worked out how to tell Sal she's finally going to see the Pacific."
            ]
        )

        let sal = personLore(
            name: "Sal Moretti",
            role: "the cook",
            desc: "Big, quiet, gentle ex-Navy cook who whistles Sinatra over the griddle and names each special after his old ship.",
            wants: "keep the griddle clean and turn out honest food for tired highway drivers",
            privateLife: "He won this diner in a high-stakes card game years ago, a story he only shares if someone asks him straight.",
            ties: "Marlene: He and Marlene have held down the graveyard shift together for six years; he quietly keeps the pie case stocked and worries the place will feel too big if she ever heads west.",
            looks: "Broad-shouldered 48-year-old man with silver-flecked dark hair, thick forearms, and gentle brown eyes.",
            wears: "Faded white cook's tee, striped apron dusted with flour, and a paper cap.",
            voice: "Low, warm, easygoing baritone with a soft Brooklyn lilt.",
            habit: "Whistles old Sinatra tunes low under his breath while wiping down the steel pass-through.",
            depths: [
                "Sal Moretti misses the hum of a ship's galley when the desert highway goes dead silent after midnight.",
                "Sal Moretti still thinks about the old owner who lost the diner deed to him in a poker hand in Flagstaff, and made sure the man left with a fair stake.",
                "Sal Moretti has been quietly setting aside a bonus envelope for Marlene's move to Santa Monica, even though he dreads running the night shift without her."
            ]
        )

        let pMarlene = npcThing(marlene.name, x: 3, y: 1, facing: .s, doing: "pouring fresh coffee behind the chrome counter", wearing: marlene.wears, expression: "warm and wry", feeling: "friendly", holding: ["glass coffee pot"])
        let pSal = npcThing(sal.name, x: 4, y: 0, facing: .s, doing: "leaning his elbows on the pass-through grill window, whistling softly", wearing: sal.wears, expression: "easygoing", feeling: "relaxed", holding: ["spatula"])
        let pPlayer = playerThing(player.name, x: 3, y: 3, facing: .n, on: stool1.id, doing: "sitting at the chrome counter over coffee", wearing: "rumpled road shirt and light jacket")

        let room = Room(
            name: location,
            type: "café",
            width: 8,
            depth: 6,
            inside: "A gleaming little chrome-and-Formica diner beside Route 66: red vinyl stools along the counter, a glass pie case, a glowing jukebox in the corner, and a steel pass-through window to the sizzling grill.",
            outside: "Hot July night in the Arizona desert, with pink neon buzzing over an empty stretch of Route 66.",
            sound: "The low buzz of the outdoor neon sign, the soft hum of the pie cooler, and Sinatra whistled lightly from the grill.",
            doors: [Opening(wall: .south, at: 4, width: 1, leadsTo: "gravel lot and Route 66")],
            windows: [
                Opening(wall: .south, at: 1, width: 2, view: "empty Route 66 and the buzzing pink neon sign"),
                Opening(wall: .east, at: 2, width: 2, view: "dark desert highway and distant mesquite")
            ],
            things: [counter, passWindow, pieCase, register, stool1, stool2, stool3, jukebox, booth, boothTable, pMarlene, pSal, pPlayer],
            log: [
                "shell: The Highway Diner (8 × 6 m)",
                "place: chrome diner counter & pass-through grill window → north side",
                "place: jukebox & red vinyl booth → west wall",
                "enter: Marlene Doyle behind the counter; Sal Moretti at the grill window; you on a red vinyl stool"
            ],
            built: true
        )

        let facts = [
            "Marlene Doyle uses she/her.",
            "Sal Moretti uses he/him.",
            "It is a hot July night in 1957 at two in the morning on Route 66 in the Arizona desert.",
            "You are a driver halfway across the country, road-tired, and the only customer in the diner.",
            "Marlene Doyle is 36 years old.",
            "Marlene Doyle has lived and worked here for 6 years, since 1951.",
            "Marlene Doyle grew up in a small town in Oklahoma before heading west down Route 66.",
            "Marlene Doyle knows every regular trucker's coffee order before their headlights clear the gravel lot.",
            "Marlene Doyle is proud that nobody leaves her counter hungry or feeling like a stranger.",
            "Sal Moretti is 48 years old.",
            "Sal Moretti has lived and worked here for 9 years, since 1948.",
            "Sal Moretti learned to cook in the U.S. Navy aboard a destroyer in the Pacific.",
            "Sal Moretti names the diner's daily special after the Navy ship he served on.",
            "Sal Moretti is proud of his cherry pie crust, rolled out fresh every evening before midnight."
        ]

        return finish(
            setup: setup,
            player: player,
            location: location,
            placeDesc: setup.place,
            bible: "July 1957, two in the morning on Route 66 in the Arizona desert. You have pulled off the empty highway into a glowing chrome diner where you are the only customer, sitting on a red vinyl stool across from the sharp-tongued night waitress while the quiet cook leans through the pass-through grill window.",
            clock: 2 * 60 + 5,
            eraDate: "Late night (about 2:05 AM), July 1957",
            spot: "on a red vinyl stool at the chrome counter",
            scene: "You sit on a red vinyl stool at the chrome counter beneath fluorescent warmth and pink neon spill from the window. Across the counter stands the night waitress with a fresh coffee pot, a sun-faded postcard taped to her register, while the cook leans through the steel pass-through window whistling softly.",
            things: ["chrome counter with red vinyl stools", "glass pie case with cherry pie", "cash register with Santa Monica postcard", "pass-through order window to the grill", "glowing chrome jukebox", "buzzing pink neon sign outside the window"],
            ambience: "The soft buzz of pink neon outside, the hum of the pie case cooler, and low whistling from the grill.",
            body: "road-tired, glad to stretch your legs over hot coffee",
            feels: "easygoing and a little lonesome in the desert night",
            cast: [marlene, sal],
            whereabouts: [
                Whereabout(name: marlene.name, at: "behind the chrome diner counter", doing: "pouring coffee", here: true, engaged: true),
                Whereabout(name: sal.name, at: "at the pass-through grill window", doing: "whistling softly while wiping the steel shelf", here: true, engaged: false),
            ],
            facts: facts,
            room: room
        )
    }

    // MARK: - 4. Saturday at Hollis's Chair

    private static func barbershop(setup: Experience, player: PlayerDetails) -> Adventure {
        let location = "Hollis's Barbershop"

        let mirrorCounter = obj("long mirror and marble counter", icon: "counter", x: 0, y: 1, w: 1, d: 4, blocks: .way, along: "wall", makeup: "veined marble beneath a tall brass-framed mirror")
        let combs = obj("blue Barbicide jars and signed boxer photo", icon: "small", x: 0, y: 2, on: mirrorCounter.id, makeup: "glass jars of blue disinfectant and a framed glossy photograph")
        let radio = obj("tabletop radio playing the ballgame", icon: "small", x: 0, y: 4, on: mirrorCounter.id, makeup: "cream Bakelite radio", state: "crackling with Saturday baseball commentary")
        let chair1 = obj("Earl's leather barber chair", icon: "chair", x: 2, y: 2, facing: .w, makeup: "heavy chrome and oxblood leather")
        let chair2 = obj("second leather barber chair", icon: "chair", x: 2, y: 4, facing: .w, makeup: "heavy chrome and oxblood leather")
        let bench = obj("wooden waiting bench", icon: "bench", x: 5, y: 2, w: 1, d: 2, facing: .w, blocks: .way, along: "wall", makeup: "varnished oak stacked with magazines")
        let photoWall = obj("wall of signed photographs and towel cabinet", icon: "shelf", x: 2, y: 0, w: 2, d: 1, blocks: .way, along: "wall", makeup: "warm oak cabinet beneath framed neighbourhood photos")
        let fern = obj("potted fern by the window", icon: "plant", x: 5, y: 5, makeup: "ceramic pot with a lively green fern")

        let earl = personLore(
            name: "Earl Hollis",
            role: "the old barber",
            desc: "Unhurried, wise and teasing South Side barber who has run this shop since before the war.",
            wants: "give the new neighbour a proper cut and test whether Marcus is ready for more responsibility",
            privateLife: "He is quietly deciding whether to hand the shop over to his nephew Marcus next year, assuming Marcus wants to stay.",
            ties: "Marcus: Earl is Marcus's uncle who taught him to hold clippers at sixteen; he teases Marcus nonstop about his radio announcer voice while secretly being prouder of him than anyone.",
            looks: "Trim 59-year-old man with closely cropped salt-and-pepper hair, gold-rimmed glasses, and steady barber's hands.",
            wears: "Starched white barber smock over a neat collared shirt and dark slacks.",
            voice: "Rich, warm, unhurried baritone with an easy laugh and rhythmic cadence.",
            habit: "Snips the air twice with his shears before laying comb to hair.",
            depths: [
                "Earl Hollis feels the long Saturday shifts in his shoulders more than he lets on.",
                "Earl Hollis remembers the morning the heavyweight champion sat in his very first chair in 1941 and signed the photo still taped to the mirror.",
                "Earl Hollis already had his lawyer draft papers to pass the shop to Marcus, and hasn't considered that his nephew might dream of something outside these walls."
            ]
        )

        let marcus = personLore(
            name: "Marcus Hollis",
            role: "the young apprentice",
            desc: "Quick, funny young apprentice who sweeps between cuts and practises radio DJ patter in his head.",
            wants: "keep the shop lively and work up the nerve to tell his uncle about next week's radio audition",
            privateLife: "He has an audition at a radio station on the North Side next week and hasn't told his uncle Earl yet.",
            ties: "Earl: Marcus is Earl's nephew and apprentice; he loves the shop and hates the idea of letting Earl down, even as radio pulls at him.",
            looks: "Lean 23-year-old man with a crisp fade, bright amused eyes, and an infectious grin.",
            wears: "Crisp short-sleeved white shirt, slim dark tie, and a striped apron.",
            voice: "Lively, smooth, energetic tenor with natural radio-announcer warmth.",
            habit: "Turns the broom handle like a microphone stand whenever nobody is looking.",
            depths: [
                "Marcus Hollis practises late-night jazz introductions into his mirror at home until his neighbours knock on the wall.",
                "Marcus Hollis owes his steady footing to Earl taking him in after his father passed, which makes leaving the shop feel like betrayal.",
                "Marcus Hollis has a Tuesday audition slip for a North Side FM station tucked in his shirt pocket right now."
            ]
        )

        let pEarl = npcThing(earl.name, x: 2, y: 1, facing: .s, doing: "shaking out a striped barber cape beside your chair", wearing: earl.wears, expression: "amused and welcoming", feeling: "cheerful", holding: ["comb", "shears"])
        let pMarcus = npcThing(marcus.name, x: 4, y: 4, facing: .nw, doing: "sweeping hair clippings near the window while listening to the ballgame", wearing: marcus.wears, expression: "grinning", feeling: "upbeat", holding: ["push broom"])
        let pPlayer = playerThing(player.name, x: 2, y: 2, facing: .w, on: chair1.id, doing: "settled in the leather barber chair facing the long mirror", wearing: "spring jacket draped aside and casual Saturday shirt")

        let room = Room(
            name: location,
            type: "shop",
            width: 6,
            depth: 7,
            inside: "A bright, narrow neighbourhood barbershop: two oxblood leather barber chairs facing a long marble-countered mirror, blue comb jars, framed signed photographs along the wall, and a Bakelite radio playing Saturday baseball.",
            outside: "A sunny spring Saturday morning on Chicago's South Side, with the striped barber pole turning by the window.",
            sound: "Saturday baseball crackling on the tabletop radio, the crisp snip of barber shears, and the soft whisk of a broom.",
            doors: [Opening(wall: .south, at: 2, width: 1, leadsTo: "sunny South Side sidewalk")],
            windows: [Opening(wall: .south, at: 4, width: 2, view: "spinning striped barber pole and sunny street")],
            things: [mirrorCounter, combs, radio, chair1, chair2, bench, photoWall, fern, pEarl, pMarcus, pPlayer],
            log: [
                "shell: Hollis's Barbershop (6 × 7 m)",
                "place: long mirror & marble counter → west wall",
                "place: two leather barber chairs → centre aisle",
                "enter: Earl Hollis beside your chair; Marcus Hollis sweeping by the window; you in the barber chair"
            ],
            built: true
        )

        let facts = [
            "Earl Hollis uses he/him.",
            "Marcus Hollis uses he/him.",
            "It is a bright Saturday morning in May 1962 on the South Side of Chicago.",
            "You just moved into an apartment up the block and came in for a haircut.",
            "Earl Hollis is 59 years old.",
            "Earl Hollis has lived and worked here for 24 years, since 1938.",
            "Earl Hollis opened this shop in 1938 after ten years cutting hair in a hotel basement downtown.",
            "Earl Hollis keeps a signed photograph of a famous heavyweight boxer whose hair he cut right by the mirror.",
            "Earl Hollis is proud that three generations of South Side families have sat in his leather chairs.",
            "Marcus Hollis is 23 years old.",
            "Marcus Hollis has lived and worked here for 3 years, since 1959.",
            "Marcus Hollis grew up two streets over listening to late-night rhythm and blues on a battered transistor radio.",
            "Marcus Hollis learned how to give a clean taper from his uncle Earl before he could even drive.",
            "Marcus Hollis is proud of his smooth delivery whenever he imitates Chicago radio announcers."
        ]

        return finish(
            setup: setup,
            player: player,
            location: location,
            placeDesc: setup.place,
            bible: "May 1962, Saturday morning on the South Side of Chicago. You just moved into an apartment up the block and stepped into the narrow neighbourhood barbershop for a haircut. Seated in the leather chair facing the long mirror, you fall into easy talk with the teasing old barber and his quick-witted nephew as baseball plays on the radio.",
            clock: 10 * 60 + 15,
            eraDate: "Morning (about 10:15 AM), May 1962",
            spot: "in Earl's leather barber chair, facing the long mirror",
            scene: "You sit in the oxblood leather barber chair facing the long mirror lined with blue comb jars and a signed boxer's photograph. The old barber stands beside your chair snipping his shears lightly, while his young apprentice sweeps near the sunny front window as the ballgame crackles from the radio.",
            things: ["two oxblood leather barber chairs", "long mirror and marble counter", "blue Barbicide comb jars", "signed photograph of a famous boxer", "Bakelite radio playing the ballgame", "striped barber pole turning outside the window"],
            ambience: "Saturday baseball crackling warmly on the radio, brisk snips of shears, and sunlight streaming across the checkered floor.",
            body: "relaxed in the leather chair, ready for a trim",
            feels: "friendly and curious about your new neighbourhood",
            cast: [earl, marcus],
            whereabouts: [
                Whereabout(name: earl.name, at: "beside your leather barber chair", doing: "getting ready to cut your hair", here: true, engaged: true),
                Whereabout(name: marcus.name, at: "sweeping near the sunny front window", doing: "sweeping up while listening to the ballgame", here: true, engaged: false),
            ],
            facts: facts,
            room: room
        )
    }

    // MARK: - 5. Closing Time on the Left Bank

    private static func leftBankBookshop(setup: Experience, player: PlayerDetails) -> Adventure {
        let location = "The Left Bank Bookshop"

        let westShelves = obj("floor-to-ceiling bookshelves (west)", icon: "shelf", x: 0, y: 1, w: 1, d: 3, blocks: .way, along: "wall", makeup: "dark creaking oak packed with English and French editions")
        let eastShelves = obj("floor-to-ceiling bookshelves (east)", icon: "shelf", x: 6, y: 1, w: 1, d: 3, blocks: .way, along: "wall", makeup: "tall pine shelves stuffed with poetry pamphlets")
        let counter = obj("bookshop counter", icon: "counter", x: 2, y: 1, w: 3, d: 1, blocks: .way, along: "wall", makeup: "ink-stained walnut cluttered with wrapped parcels")
        let ledger = obj("lending-library ledger and brass bell", icon: "small", x: 3, y: 1, on: counter.id, makeup: "cloth-bound ledger and small brass counter bell")
        let stove = obj("little black iron stove", icon: "fireplace", x: 5, y: 0, w: 1, d: 1, blocks: .way, makeup: "pot-bellied black cast iron", state: "glowing warmly with coals")
        let armchair = obj("sagging velvet armchair", icon: "chair", x: 5, y: 2, facing: .w, makeup: "threadbare bottle-green velvet")
        let stacks = obj("tall stacks of books on the floor", icon: "crate", x: 1, y: 4, w: 1, d: 1, blocks: .way, makeup: "leaning columns of secondhand novels")
        let lamp = obj("shaded brass reading lamp", icon: "lamp", x: 5, y: 3, makeup: "tarnished brass with a cream parchment shade", state: "lit")

        let margot = personLore(
            name: "Margot Fairley",
            role: "the bookshop owner",
            desc: "Brisk, kind American expatriate who runs a beloved Left Bank English bookshop and lends books on trust.",
            wants: "tidy the shelves past closing and place the right book in a fellow newcomer's hands",
            privateLife: "She keeps an unanswered letter from her mother in Ohio begging her to come home, tucked under the counter beside her uncollected IOU tin.",
            ties: "Théo: She lets Théo sleep on a cot in the back room in exchange for sweeping and pretends not to notice when he slips new poems between her ledger pages.",
            looks: "Composed 35-year-old woman with dark bobbed hair, ink on her cuffs, and quick observant eyes.",
            wears: "Charcoal pleated skirt, soft ivory blouse, and a belted wool cardigan.",
            voice: "Crisp, warm, literate alto with quiet Midwestern clarity and easy French phrases.",
            habit: "Straightens the spine of any crooked book within arm's reach while talking.",
            depths: [
                "Margot Fairley worries every winter whether the shop's narrow margins will survive another coal bill.",
                "Margot Fairley keeps an IOU tin under the counter full of young writers' promises she knows she will never collect on.",
                "Margot Fairley has carried an unopened third letter from her mother in Ohio for a week, torn between duty at home and the only life that ever felt like hers in Paris."
            ]
        )

        let theo = personLore(
            name: "Théo Lambert",
            role: "the young poet",
            desc: "Shabby, funny, opinionated French poet who reads by the iron stove and sleeps in the back room.",
            wants: "trade literary opinions over the rain and finish his secret translation gift for Margot",
            privateLife: "He carries a dog-eared notebook of poems he has never shown anyone, and is secretly translating Margot's favourite novel into French as a gift.",
            ties: "Margot: Margot gave him a roof in the back room when his landlord locked him out; he sweeps the shop religiously and argues fiercely about every novel she recommends.",
            looks: "Lanky 24-year-old man with unruly dark curls, smudged spectacles, and bright restless eyes.",
            wears: "Elbow-patched tweed jacket, loose knit scarf, and ink-stained fingers.",
            voice: "Quick, expressive, lightly French-accented tenor full of dry amusement.",
            habit: "Marks his place in a book with whatever café receipt or torn slip is in his pocket.",
            depths: [
                "Théo Lambert jokes lightly about living on bread and ink, though he secretly fears he will never get a single collection printed.",
                "Théo Lambert fell out with his bourgeois family in Lyon when he refused to study law and moved to Paris with one suitcase.",
                "Théo Lambert has spent six months translating Margot's favourite American novel into French by candlelight in the back room, afraid she'll leave Paris before he finishes."
            ]
        )

        let pMargot = npcThing(margot.name, x: 3, y: 0, facing: .s, doing: "straightening returns behind the bookshop counter", wearing: margot.wears, expression: "warm and curious", feeling: "hospitable", holding: ["clothbound novel"])
        let pTheo = npcThing(theo.name, x: 5, y: 2, facing: .w, on: armchair.id, doing: "reading in the sagging velvet armchair beside the iron stove", wearing: theo.wears, expression: "amused and absorbed", feeling: "cozy", holding: ["open book", "pocket notebook"])
        let pPlayer = playerThing(player.name, x: 3, y: 2, facing: .n, doing: "standing by the counter, shaking rain from your coat", wearing: "rain-speckled trench coat and wool scarf")

        let room = Room(
            name: location,
            type: "shop",
            width: 7,
            depth: 6,
            inside: "A cramped, golden-lit English bookshop near the Seine: floor-to-ceiling shelves, leaning stacks of novels on the boards, a glowing iron stove, a walnut counter with a lending ledger, and a sagging velvet armchair.",
            outside: "A rainy November evening in 1926 Paris, with wet cobblestones and the gas lamps of the quay shining beyond the glass.",
            sound: "Soft rain tapping on the shop window, coals settling inside the iron stove, and the whisper of turning pages.",
            doors: [Opening(wall: .south, at: 3, width: 1, leadsTo: "rain-slicked Left Bank street")],
            windows: [Opening(wall: .south, at: 0, width: 2, view: "rain on the glass and the streetlamps along the Seine")],
            things: [westShelves, eastShelves, counter, ledger, stove, armchair, stacks, lamp, pMargot, pTheo, pPlayer],
            log: [
                "shell: The Left Bank Bookshop (7 × 6 m)",
                "place: floor-to-ceiling bookshelves → east and west walls",
                "place: bookshop counter & iron stove → north side; velvet armchair beside stove",
                "enter: Margot Fairley behind the counter; Théo Lambert in the armchair; you by the counter"
            ],
            built: true
        )

        let facts = [
            "Margot Fairley uses she/her.",
            "Théo Lambert uses he/him.",
            "It is a rainy November evening in 1926 on the Left Bank in Paris, just before closing time.",
            "You are an American a few weeks into Paris, still finding your feet and your French.",
            "Margot Fairley is 35 years old.",
            "Margot Fairley has lived and worked here for 6 years, since 1920.",
            "Margot Fairley moved to Paris from Ohio after working in a Cleveland bookshop.",
            "Margot Fairley opened her lending library so penniless writers could borrow books they couldn't afford to buy.",
            "Margot Fairley is proud that half the young novelists in the quarter found their first readers at her counter.",
            "Théo Lambert is 24 years old.",
            "Théo Lambert has lived and worked here for 4 years, since 1922.",
            "Théo Lambert came up to Paris from Lyon with one worn valise and a pocketful of poems.",
            "Théo Lambert sleeps on a cot in the back room of the bookshop in exchange for sweeping up each morning.",
            "Théo Lambert is proud of his razor-sharp ear for English cadence, learned almost entirely from Margot's shelves."
        ]

        return finish(
            setup: setup,
            player: player,
            location: location,
            placeDesc: setup.place,
            bible: "November 1926, a rainy evening on the Left Bank in Paris. You have ducked into a cramped English-language bookshop near the Seine right before closing, and the brisk, kind owner lets you linger while she tidies behind the counter and a young poet reads in the sagging armchair beside the iron stove.",
            clock: 19 * 60 + 50,
            eraDate: "Evening (about 7:50 PM), November 1926",
            spot: "standing by the bookshop counter, out of the rain",
            scene: "You stand beside the walnut counter surrounded by ceiling-high shelves and leaning stacks of books. Across the counter, the bookshop owner tidies returned volumes beside her lending ledger. Over by the glowing iron stove, a young poet lounges in a sagging green armchair with an open book.",
            things: ["floor-to-ceiling bookshelves", "walnut counter with lending-library ledger", "glowing black iron stove", "sagging velvet armchair", "tall stacks of secondhand books", "rain-streaked shop window onto the quay"],
            ambience: "Gentle Paris rain tapping against the shop window, quiet crackle from the iron stove, and the warm smell of old paper.",
            body: "lightly rained-on, warming up near the stove",
            feels: "curious, a bit of a dreamer, glad to find friendly English voices",
            cast: [margot, theo],
            whereabouts: [
                Whereabout(name: margot.name, at: "behind the walnut bookshop counter", doing: "tidying returned books", here: true, engaged: true),
                Whereabout(name: theo.name, at: "in the sagging velvet armchair beside the iron stove", doing: "reading with a notebook on his knee", here: true, engaged: false),
            ],
            facts: facts,
            room: room
        )
    }

    // MARK: - 6. Snowed In at the Lodge

    private static func skiLodge(setup: Experience, player: PlayerDetails) -> Adventure {
        let location = "The Lodge Great Room"

        let fireplace = obj("big stone fireplace", icon: "fireplace", x: 3, y: 0, w: 2, d: 1, blocks: .way, along: "wall", makeup: "rough-stacked river stone", state: "blazing with split pine logs")
        let rug = obj("woven wool hearth rug", icon: "rug", x: 3, y: 2, w: 2, d: 2, blocks: .none, makeup: "thick geometric mountain wool")
        let couch = obj("worn leather couch", icon: "sofa", x: 3, y: 4, w: 2, d: 1, facing: .n, blocks: .way, makeup: "deep saddle-brown leather")
        let chairJune = obj("leather fireside armchair", icon: "chair", x: 2, y: 2, facing: .se, makeup: "creaky tufted leather")
        let chairDanny = obj("timber fireside armchair", icon: "chair", x: 5, y: 2, facing: .sw, makeup: "pine-frame chair with plaid cushions")
        let barCart = obj("bar cart with cocoa pot", icon: "table", x: 6, y: 1, makeup: "brass and pine rolling cart")
        let cocoa = obj("enamel cocoa pot and tin mugs", icon: "small", x: 6, y: 1, on: barCart.id, makeup: "speckled blue enamel pot, mugs, and a bottle of whiskey", state: "steaming hot")
        let skiRack = obj("wall rack of wooden skis and snowshoes", icon: "shelf", x: 7, y: 3, w: 1, d: 2, blocks: .way, along: "wall", makeup: "varnished hickory skis and rawhide snowshoes")
        let floorLamp = obj("warm timber floor lamp", icon: "lamp", x: 1, y: 5, makeup: "turned pine stand with amber parchment shade", state: "lit")

        let june = personLore(
            name: "June Halvorsen",
            role: "the lodge owner",
            desc: "Tough, wry, generous lodge owner who has run this mountain timber lodge on her own since her husband passed.",
            wants: "make sure every snowed-in traveller is warm and fed while mulling a big decision",
            privateLife: "A big resort corporation just offered to buy the lodge, and she is quietly weighing whether to sell or hold on.",
            ties: "Danny: June has kept Danny in hot cocoa and dry socks for four winters; she treats him like a reckless nephew and relies on his weather calls more than she admits.",
            looks: "Sturdy 52-year-old woman with silver-streaked blonde hair braided back, wind-tanned cheeks, and steady blue eyes.",
            wears: "Thick cream Norwegian wool sweater, corduroy trousers, and fleece-lined boots.",
            voice: "Warm, weathered, steady contralto with dry mountain wit.",
            habit: "Turns her ceramic mug slowly between both palms whenever she's thinking hard.",
            depths: [
                "June Halvorsen hates how hard it gets every January to haul firewood and mend frozen pipes all by herself.",
                "June Halvorsen built half the timber framing of this great room alongside her late husband Erik, and every scratch in the floorboards carries his memory.",
                "June Halvorsen has a resort developer's buyout offer sitting on her office desk right now, with a Monday deadline and enough money to retire comfortably."
            ]
        )

        let danny = personLore(
            name: "Danny Reyes",
            role: "the ski patroller",
            desc: "Young, cheerful, fearless mountain patroller thawing out after closing the upper runs ahead of the blizzard.",
            wants: "thaw his frozen fingers by the fire and trade mountain stories while the pass stays shut",
            privateLife: "He keeps a dog-eared photo of the avalanche pup he is training in his parka pocket, and dreams of patrolling in the Swiss Alps.",
            ties: "June: Danny has worked the slopes above June's lodge for four seasons and always checks her roof snow load after a storm without being asked.",
            looks: "Lanky 25-year-old man with wind-chapped cheeks, tousled dark hair, and an easy grin.",
            wears: "Unzipped red ski-patrol parka over a thermal waffle shirt and heavy wool socks.",
            voice: "Bright, easygoing, upbeat tenor with a quick mountain grin.",
            habit: "Holds his reddened palms out toward the flames and bounces one heel to keep warm.",
            depths: [
                "Danny Reyes loves the adrenaline of storm mornings, though the mountain can turn deadly quiet when visibility drops to ten feet.",
                "Danny Reyes once dug a stranded backcountry skier out of a drift near timberline, which convinced him to start training an avalanche dog.",
                "Danny Reyes applied for a winter exchange with an Alpine rescue team in Zermatt, though he wonders if he'll ever scrape together the airfare."
            ]
        )

        let pJune = npcThing(june.name, x: 2, y: 2, facing: .se, on: chairJune.id, doing: "nursing a warm mug by the stone fireplace", wearing: june.wears, expression: "wry and welcoming", feeling: "relaxed", holding: ["ceramic mug"])
        let pDanny = npcThing(danny.name, x: 5, y: 2, facing: .sw, on: chairDanny.id, doing: "warming his chilled hands toward the roaring fire", wearing: danny.wears, expression: "grinning", feeling: "cheerful")
        let pPlayer = playerThing(player.name, x: 3, y: 4, facing: .n, on: couch.id, doing: "settled on the worn leather couch facing the fire", wearing: "heavy winter sweater and wool socks")

        let room = Room(
            name: location,
            type: "hall",
            width: 8,
            depth: 7,
            inside: "The snug timber great room of a small Rockies ski lodge: a roaring stone fireplace, a woven wool hearth rug, worn leather couch and fireside chairs, wooden skis racked on the log wall, and a bar cart steaming with cocoa.",
            outside: "A fierce January 1972 blizzard howling sideways past the tall windows, burying the mountain pass.",
            sound: "Pine logs popping and crackling in the stone fireplace while blizzard wind howls past the eaves.",
            doors: [Opening(wall: .south, at: 4, width: 1, leadsTo: "snowbound porch and closed mountain pass")],
            windows: [Opening(wall: .west, at: 2, width: 3, view: "blizzard snow blowing sideways through dark pines")],
            things: [fireplace, rug, couch, chairJune, chairDanny, barCart, cocoa, skiRack, floorLamp, pJune, pDanny, pPlayer],
            log: [
                "shell: The Lodge Great Room (8 × 7 m)",
                "place: big stone fireplace → north wall; hearth rug & fireside chairs around fire",
                "place: worn leather couch → south of hearth; bar cart & ski rack → east side",
                "enter: June Halvorsen & Danny Reyes by the fire; you on the leather couch"
            ],
            built: true
        )

        let facts = [
            "June Halvorsen uses she/her.",
            "Danny Reyes uses he/him.",
            "It is a January night in 1972 in the Colorado Rockies, and a blizzard has closed the mountain pass.",
            "You were driving through the mountains when the pass shut and took shelter at the lodge for the night.",
            "June Halvorsen is 52 years old.",
            "June Halvorsen has lived and worked here for 18 years, since 1954.",
            "June Halvorsen and her late husband Erik built this small log lodge together when the road up the valley was still gravel.",
            "June Halvorsen remembers the name of every guest who ever signed her timber register.",
            "June Halvorsen is proud that the lodge has never turned away a snowbound driver, pay or no pay.",
            "Danny Reyes is 25 years old.",
            "Danny Reyes has lived and worked here for 4 years, since 1968.",
            "Danny Reyes grew up skiing hand-me-down hickory boards in northern New Mexico.",
            "Danny Reyes came in half-frozen tonight after sweeping and closing the upper runs ahead of the storm.",
            "Danny Reyes is proud of the young shepherd pup he is training for avalanche rescue."
        ]

        return finish(
            setup: setup,
            player: player,
            location: location,
            placeDesc: setup.place,
            bible: "January 1972, a blizzard night in the Colorado Rockies. The mountain pass has closed behind you, stranding you in the firelit great room of a small log ski lodge. Settled on the worn leather couch facing the roaring stone fireplace, you share the evening with the wry lodge owner and a ski patroller thawing out from the upper runs.",
            clock: 21 * 60 + 30,
            eraDate: "Night (about 9:30 PM), January 1972",
            spot: "on the worn leather couch facing the stone fireplace",
            scene: "You sit on the worn leather couch across the woven hearth rug from the roaring stone fireplace while snow drives sideways against the tall west windows. To your left sits the lodge owner nursing a warm mug; to your right, a red-parka ski patroller holds his chilled hands toward the blaze near a bar cart steaming with cocoa.",
            things: ["big stone fireplace with crackling logs", "worn leather couch and fireside armchairs", "bar cart with steaming enamel cocoa pot", "wall rack of wooden skis and snowshoes", "woven wool hearth rug", "tall windows lashed by sideways blizzard snow"],
            ambience: "Crackling pine logs in the stone fireplace and high mountain wind howling against the timber eaves.",
            body: "warmed by the fire after coming in out of the snow",
            feels: "relaxed and glad for easy company on a stormbound night",
            cast: [june, danny],
            whereabouts: [
                Whereabout(name: june.name, at: "in the leather armchair left of the stone fireplace", doing: "nursing a warm mug", here: true, engaged: true),
                Whereabout(name: danny.name, at: "in the timber armchair right of the fireplace", doing: "thawing his hands by the blaze", here: true, engaged: false),
            ],
            facts: facts,
            room: room
        )
    }
}
