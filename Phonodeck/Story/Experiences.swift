import Foundation

/// Curated experiences offered in the set-up. Each is an `Experience`, the same format people
/// can export and share.
enum CuratedExperiences {
    static let all: [Experience] = [speakeasy, foggyLight, allNightDiner, barbershop]

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
        return e
    }

    static var allNightDiner: Experience {
        var e = Experience()
        e.id = UUID(uuidString: "6B1F0A52-0D52-4B3B-9E47-1A0000000008")!
        e.title = "Two A.M. on Route 66"
        e.simulator = true
        e.minutes = 20
        e.feeling = "Easy, neon-lit, a little lonesome"
        e.describe = "It is a hot summer night in 1957, somewhere in the Arizona desert on Route 66. I have pulled off the highway at an all-night diner, and at two in the morning I am the only customer, sitting at the counter over coffee and pie, talking with the waitress and the cook through the order window."
        e.world = "The Arizona desert, 1957, on Route 66"
        e.vibe = "Warm, quiet, a little lonesome, wholesome"
        e.who = "A driver halfway across the country, road-tired, in no hurry to get back behind the wheel"
        e.traits = "Easygoing and friendly, a good listener with a dry sense of humour"
        e.place = "A small chrome diner by the highway: red vinyl stools along a long counter, a pie case under glass, a jukebox in the corner, a pass-through order window to the grill, and big windows onto the empty road and the neon sign buzzing outside"
        e.goal = "Sit at the counter, take your time over coffee and pie, and get to know the waitress and the cook on a slow night"
        e.allies = "Marlene Doyle, the night waitress: sharp-tongued and warm, calls everyone 'hon', keeps a postcard of the Pacific Ocean taped to the register and is saving her tips to move to Santa Monica, though she has never seen the sea; Sal Moretti, the cook: big, quiet and gentle, learned to cook in the Navy, names the daily special after the ship he served on, whistles Sinatra over the grill, and won the diner in a card game, a story he only tells if you ask him straight"
        e.play = "Lots of dialogue, forgiving"
        return e
    }

    static var barbershop: Experience {
        var e = Experience()
        e.id = UUID(uuidString: "6B1F0A52-0D52-4B3B-9E47-1A0000000009")!
        e.title = "Saturday at Hollis's Chair"
        e.simulator = true
        e.minutes = 20
        e.feeling = "Lively, neighbourly, belonging"
        e.describe = "It is a Saturday morning in spring 1962 on the South Side of Chicago. I have come into the neighbourhood barbershop for a haircut, and while I sit in the chair the old barber and his young apprentice keep up the talk: the ballgame, the neighbourhood and their own plans."
        e.world = "The South Side of Chicago, 1962"
        e.vibe = "Warm, funny, lively, wholesome"
        e.who = "A newcomer to the neighbourhood who just moved into an apartment up the block and needs a haircut"
        e.traits = "Friendly and quick to laugh, curious about the neighbourhood"
        e.place = "A narrow barbershop: two old leather barber chairs facing a long mirror, a radio on the shelf playing the ballgame, a striped pole turning outside the window, jars of combs in blue liquid, and a wall covered in signed photographs"
        e.goal = "Get a haircut, settle into the neighbourhood, and hear the barber and his apprentice talk about their lives and plans"
        e.allies = "Earl Hollis, the barber: unhurried, wise and teasing, has cut hair in this shop since before the war, keeps a signed photograph of a famous boxer whose hair he cut by the mirror and won't let anyone else touch it, and is quietly deciding whether to hand the shop over; Marcus Hollis, his nephew and apprentice: quick and funny, sweeps up between customers, practises being a radio disc jockey in his head between haircuts, and hasn't yet told his uncle he has an audition at a station on the North Side next week"
        e.play = "Lots of dialogue, forgiving"
        return e
    }

    static var foggyLight: Experience {
        var e = Experience()
        e.id = UUID(uuidString: "6B1F0A52-0D52-4B3B-9E47-1A0000000007")!
        e.title = "Fog at the Light"
        e.simulator = true
        e.minutes = 20
        e.feeling = "Snug, salty, companionable"
        e.describe = "It is 1910 on the coast of Maine. A thick fog has rolled in off the sea, and I am sheltering in the kitchen at the foot of a lighthouse with the old keeper and his grown daughter while the foghorn sounds."
        e.world = "The coast of Maine, 1910"
        e.vibe = "Cozy, weathered, wholesome"
        e.who = "A traveller walking the coast road who was caught by the fog and taken in for the evening"
        e.traits = "Easygoing and curious, happy to lend a hand"
        e.place = "The keeper's kitchen at the foot of the tower: a cast-iron stove, a scrubbed pine table, oilskins on hooks, a spiral iron stair climbing up to the lamp room, and a door out onto the wet rocks where the fog sits thick"
        e.goal = "Wait out the fog with the keeper and his daughter, hear their stories, and maybe climb up to see the lamp"
        e.allies = "Elias Crane, the old keeper: gruff, weathered and kind, forty years tending this light and proud of every one; Hannah Crane, his grown daughter: practical and quick-witted, who runs the light as much as he does and wonders about a life beyond the point"
        e.play = "Lots of dialogue, a little exploring, forgiving"
        return e
    }
}
