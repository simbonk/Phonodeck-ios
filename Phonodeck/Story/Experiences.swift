import Foundation

/// Curated experiences offered in the set-up. Each is an `Experience`, the same format people
/// can export and share.
enum CuratedExperiences {
    static let all: [Experience] = [speakeasy, atoll, magician, lighthouse]

    static var speakeasy: Experience {
        var e = Experience()
        e.id = UUID(uuidString: "6B1F0A52-0D52-4B3B-9E47-1A0000000001")!
        e.title = "A Speakeasy in the Rain"
        e.simulator = true
        e.minutes = 20
        e.feeling = "Warm, nostalgic comfort"
        e.describe = "It is a stormy night in Los Angeles in 1925, and I have ducked into a hidden speakeasy to wait out the rain. I take a stool at the bar and talk with the serious, quiet bartender and a friendly regular about their hopes and dreams for the future."
        e.world = "Los Angeles, 1925, during Prohibition"
        e.vibe = "Cozy, melancholic, wholesome"
        e.who = "A traveller new in town, soaked from the storm, with time to kill and a good ear for other people's stories"
        e.traits = "Curious and easy to talk to, but a little homesick"
        e.place = "A small speakeasy hidden behind a flower shop downtown: rain drumming on the skylight, a jazz record crackling on the gramophone, a warm lamp over a long mahogany bar"
        e.goal = "Sit at the bar, wait out the storm, and hear the bartender and the regular talk about their hopes and dreams for the future"
        e.allies = "Walter Pruitt, the bartender: serious, precise and quietly kind, saving every nickel for a dream he rarely mentions; Dolores Vega, a regular who sews costumes for the movie studios and is sure her big break is just around the corner"
        e.play = "Lots of dialogue, forgiving"
        e.avoid = "Keep it PG-13; no danger and no police raid, just warm conversation"
        return e
    }

    static var atoll: Experience {
        var e = Experience()
        e.id = UUID(uuidString: "6B1F0A52-0D52-4B3B-9E47-1A0000000002")!
        e.title = "Washed Ashore"
        e.simulator = true
        e.minutes = 20
        e.feeling = "Deep connection and friendship"
        e.describe = "My cruise ship has sunk, and I have washed up on Suwarrow, a tiny coral atoll in the Cook Islands, hundreds of miles from anywhere. There is no danger and no race to be rescued. On the island I meet a stranger, and slowly we become good friends."
        e.world = "Suwarrow atoll, the Cook Islands, today"
        e.vibe = "Wholesome, cozy, whimsical"
        e.who = "A cruise passenger who has just washed ashore with nothing but the clothes I am wearing and a waterproof watch"
        e.traits = "Resourceful and good-humoured, but used to being busy and not sure what to do with stillness"
        e.place = "A white coral beach at sunrise, a calm turquoise lagoon, coconut palms leaning over the water, and a line of footprints in the sand that are not mine"
        e.goal = "Meet the stranger on the island, get to know them, and become good friends"
        e.allies = "Teina, the stranger on the island: the soft-spoken caretaker of the atoll, who has lived here alone for years and knows every tide, reef and star"
        e.play = "Lots of dialogue, exploration, forgiving"
        e.avoid = "Keep it PG; no danger, no injuries and no rescue drama"
        return e
    }

    static var magician: Experience {
        var e = Experience()
        e.id = UUID(uuidString: "6B1F0A52-0D52-4B3B-9E47-1A0000000003")!
        e.title = "The Magician's Last Trick"
        e.minutes = 30
        e.feeling = "Cosy delight with a puzzle"
        e.describe = "I am a travelling stage magician on a luxury night train from Paris to Istanbul in 1931. On the first night a duchess's diamond vanishes in the middle of my act. Everyone assumes it is part of the show, including me, until I realise I did not do it. I have three snowbound days and a carriage of eccentric suspects to find out who did."
        e.world = "A luxury night train, winter 1931, snowbound in the Balkan mountains"
        e.vibe = "Cozy, mysterious, funny"
        e.who = "The Great Marvello, a travelling stage magician: sleight of hand, a velvet cape and a carefully hidden past as a pickpocket"
        e.traits = "Quick hands and a quicker eye for a lie, but a show-off who cannot resist an audience"
        e.place = "The gleaming dining car at midnight, chandeliers swaying, snow piling against the windows as the train grinds to a halt in a mountain pass"
        e.hook = "Find the Duchess's stolen diamond, the Star of Odessa, before the train reaches Istanbul and the police arrest the obvious suspect: me"
        e.allies = "Pip, my teenage assistant who is braver than me; Inspector Kova, a sleepy policeman who is much sharper than he looks; Duchess Anastasia, who seems strangely unbothered by her loss"
        e.threat = "A thief hidden among the passengers (a nervous honeymooning couple, a famous novelist, a chess grandmaster and a very polite conductor), and my own past catching up with me"
        e.play = "Puzzles and clues, lots of dialogue, forgiving"
        e.avoid = "Keep it PG-13; no murder, a cosy mystery"
        e.beats = "The theft happens during the magician's vanishing trick, so every clue is hidden in the act itself. Each suspect has a harmless secret that looks guilty. The novelist is secretly writing the whole thing down. The Duchess hid the diamond herself to test who could be trusted, but a real thief then took it from her hiding place. The magician solves it with one last trick in the dining car. End with the train pulling into Istanbul at sunrise."
        return e
    }

    static var lighthouse: Experience {
        var e = Experience()
        e.id = UUID(uuidString: "6B1F0A52-0D52-4B3B-9E47-1A0000000004")!
        e.title = "The Last Lighthouse Keeper"
        e.minutes = 15
        e.feeling = "Quiet awe and a small, brave kindness"
        e.describe = "I am the keeper of a remote lighthouse on the Scottish coast in 1962, the last winter before it is automated. Tonight a storm is rising, the lamp is failing, and a small fishing boat is still out there."
        e.world = "A lighthouse on a rocky Scottish headland, December 1962"
        e.vibe = "Atmospheric, tender, a little tense"
        e.who = "The lighthouse keeper: patient, practical, and secretly dreading the day the light no longer needs anyone"
        e.place = "The lamp room at the top of the tower at dusk, brass gleaming, the great lens turning, sleet rattling the glass"
        e.hook = "Keep the light burning through the storm and guide the last boat home"
        e.allies = "Morag, the radio operator in the village who keeps the keeper company over the crackling set"
        e.threat = "The storm, a failing lamp mechanism, and the fisherman's pride, which won't let him turn back"
        e.play = "Problem solving, atmosphere, forgiving"
        e.avoid = "Keep it PG; nobody dies"
        return e
    }
}
