import Foundation

/// The scenario bank for the overnight tests. Plain text, so it is easy to add to:
///
///     # id | What it tests
///     > what the player does || what they say      (either side may be empty)
///     ? check arguments                            (checked after the turn above)
///
/// Words in braces are filled in from each story's opening room, so one scenario runs in all six:
/// {host} and {other} are the two people there ("the bartender", or their name once known),
/// {otherposs} is his or her (for {other}), {seat} is something to sit on, {thing} is a small thing to pick up,
/// {outside} is where the door leads. A scenario that needs something the room hasn't got is
/// skipped in that story.
///
/// <<a|b|c>> picks one option each time the scenario runs; every <<...>> in a scenario picks at the
/// same place, so a check can follow its line: "> <<an old man with a cane|a girl with a basket>> comes in"
/// with "? newcomer <<cane|basket>>". Some turns are also loosened the way people talk ("um, so I...").
/// The core set below stays fixed so runs compare fairly; `wide` adds new situations ("| wide").
///
/// Checks (see `TestRunner.expect`):
///   newcomer a|b|c      someone matching one of the words is on the map and has a card
///   gone {ref}          that person is not in the room with you
///   here {ref}          that person is in the room with you
///   moved               you are in a different room from the opening one
///   back                you are back in the opening room
///   holding word|word   you have it (your hands, or what you carry)
///   not-holding word    you don't
///   seated / standing   you are on a seat, or not
///   near {ref}          you are within a step or so of them
///   facing {ref}        you are turned toward them
///   clock MIN MAX       the story clock moved between MIN and MAX minutes this turn
///   long-turn           this turn may move the clock a lot (turns off the 2-hour limit)
///   player-named Name   the story knows your name is Name
///   known {ref}         their name is known now
///   mentions a|b        the reply says one of the words
///   mentions-present    the reply mentions everyone in the room with you
///   recalls N           the reply shares a telling word with the reply N turns back
///   stayed              you stayed in the same room as before this turn (no accidental exit)
///   room-furnished      current indoor room has real furniture (at least 2 placed objects)
///   no-cloned-room      new room is distinct from opening room (different name and furniture)
///   outdoor-clean       outdoor room is open air with no indoor-only fixtures (bars, beds, counters)
///   voice-cast-ok       quoted dialogue in the reply matched real character voices (not narrator)
///   opened {ref}        they opened up at least once (one more of what they keep close)
enum TestScenarios {
    static let bank = #"""
# newcomer-violin | Someone walks in
> I look over to the door as a young man with a violin case comes in out of the weather. ||
? newcomer violin|young man|musician
> I nod to the young man with the violin case. || <<Come on in, get warm.|Rough night out there?|There's room over here.>>
? here violin|young man|musician
> || Who is here with us now?
? mentions-present

# newcomer-redcoat | A woman in a red coat arrives
> The door opens and a woman in a red coat steps in, shaking off the wet. ||
? newcomer red coat|woman
> I turn toward the woman in the red coat. || Are you waiting for someone?
? facing red coat|woman

# newcomer-twice | Two people arrive, one after the other
> An old man with a cane shuffles in and looks around for a place to sit. ||
? newcomer cane|old man
> || Evening, sir.
> A girl selling newspapers pokes her head in the door and comes inside. ||
? newcomer newspaper|girl
? here cane|old man

# leave-return | Leaving and coming back
> I get up and step out through the door to {outside} for some air. ||
? moved
? standing
> I stand there a minute and look around. ||
> I go back inside to where I was before. ||
? back
? here {host}

# leave-return-sit | Leaving, coming back and sitting down again
> I sit down on {seat}. ||
? seated
> I get up and go out to {outside}. ||
? moved
> I come back in and sit down on {seat} again. ||
? back
? seated

# ask-name | Asking a name
> I turn to {host}. || I'm sorry, I never asked. What's your name?
? facing {host}
? known {host}
> || And how long have you worked here?

# ask-name-by-pronoun | Asking a name by him or her
> I nod at {other}. ||
> I turn to {host}. || What's {otherposs} name, the one over there?
? mentions {other}

# tell-name | Telling my name
> || My name is Sam, by the way.
? player-named Sam
> || Do you remember my name?
? mentions Sam

# pick-up | Picking things up and putting them down
> I pick up {thing}. ||
? holding {thing}
> || What is this for?
> I put {thing} back down. ||
? not-holding {thing}

# pick-up-give | Picking something up and giving it away
> I pick up {thing} and look at it. ||
? holding {thing}
> I hand {thing} to {host}. || Here, this is yours.
? not-holding {thing}

# time-short | A short wait
> <<I sit quietly for a minute and listen.|I take a sip and wait a moment.|I close my eyes for a few seconds.|I watch the room for a minute or two.>> ||
? clock 0 15

# time-hour | An hour goes by
> <<I talk with {host} for about an hour about nothing much.|An hour slips by while {host} and I swap stories.|We pass the next hour or so just chatting.>> ||
? long-turn
? clock 40 120
> || What time is it now?

# time-skip | A long wait
> I doze off in my seat and wake up a few hours later. ||
? long-turn
? clock 120 480

# do-and-say | Doing and saying at once
> I lean on the counter and smile at {host}. || You look like you've had a long day.
? facing {host}
> I take off my coat and hang it up. || That's better.
> || So what brings everyone here tonight?

# say-only | Just talking
> || What do you hope to be doing in ten years?
> || Why that?
> || Have you told anyone else that?

# do-only | Just doing
> I look around the room slowly. ||
> I walk over to {other}. ||
? near {other}
> I stretch and yawn. ||

# walk-over | Walking from one person to another
> I walk over to {host}. ||
? near {host}
? facing {host}
> I walk over to {other}. || Mind if I join you?
? near {other}
? facing {other}

# someone-leaves | Someone leaves and comes back
> || Do you have to be anywhere tonight?
> {other} says goodnight, puts on a coat and leaves. ||
? gone {other}
> || Do you think they'll be back?
> {other} comes back in, having forgotten something. ||
? here {other}

# who-here | Who is here
> || Who all is here right now?
? mentions-present
> I sit down on {seat}. ||
? seated
> || Where exactly am I sitting?

# stand-up | Standing up and sitting down
> I sit down on {seat}. ||
? seated
> I stand up and stretch my legs. ||
? standing
> I sit back down. ||
? seated
"""#

    /// Targeted scenarios covering the real bugs hit in live play: false door exits on spoken questions,
    /// sliding objects without false movement, templated & unknown ("other") new rooms, outdoor transitions
    /// with a companion, distinct staff newcomers, seating next to someone, and multi-voice banter.
    static let regressions = #"""
# r-stay-on-question | Asking to step out should not move you yet | regressions
> I smile at {host}. || <<Want to step outside for some fresh air with me?|Should we head down to the bakery down the street?|Feel like taking a walk outside for a minute?>>
? stayed
? here {host}

# r-slide-no-move | Sliding something across to someone should not move you | regressions
> I sit down on {seat}. ||
? seated
> I slide a folded note over to {host}. || Keep this for me, would you?
? stayed
? seated

# r-visit-templated | Visiting a new named indoor room with a companion and meeting staff | regressions
> {host} and I head out the door and walk into <<the little bakery down the street|the corner café|the quiet library across the street|the old workshop next door>>. ||
? moved
? room-furnished
? no-cloned-room
? here {host}
> I look around and nod to the <<baker|barista|librarian|craftsman>> behind the counter. || Good evening, busy night?
? newcomer <<baker|barista|librarian|craftsman>>
? here {host}
> {host} and I head back to where we started. ||
? back
? here {host}

# r-visit-unknown | Stepping into an untemplated room that the AI must furnish itself | regressions
> I step through a side door into <<the rooftop observatory|the photo darkroom|the clockmaker's attic|the wine vault>>. ||
? moved
? room-furnished
? no-cloned-room
> I look slowly around the room. || Well, look at this place.
? room-furnished
> I head back to where I came from. ||
? back

# r-outside-together | Asking first, then stepping outside together and returning | regressions
> I turn to {other}. || Do you want to step outside for a minute?
? stayed
> {other} and I step out through the door to {outside}. ||
? moved
? outdoor-clean
? here {other}
> {other} and I head back inside together. ||
? back
? here {other}
? room-furnished

# r-sit-beside-other | Walking over and sitting down near the second character | regressions
> I walk over and sit down beside {other}. || Mind if I join you?
? near {other}
? seated

# r-two-voice-banter | Getting both characters speaking to verify multi-voice attribution | regressions
> I look from {host} to {other}. || How did you two end up here tonight? Tell me both sides.
? voice-cast-ok
> I grin and look straight at {other}. || Is that really how it happened?
? facing {other}
? voice-cast-ok

# r-return-intact | Leaving alone and verifying the opening room is intact on return | regressions
> I step out to {outside} by myself to get some air. ||
? moved
? outdoor-clean
> I stand quietly for a minute, then go back inside. ||
? back
? room-furnished
? here {host}
"""#

    static let wide = #"""
# w-newcomer-any | Someone new arrives, described every which way | wide
> <<An old man with a cane|A girl with a basket of flowers|A tall man in a wet hat|A woman carrying a sleeping baby|A boy with a dog on a rope|A sailor with a duffel bag|A nurse still in her uniform>> comes in from outside. ||
? newcomer <<cane|basket|hat|baby|dog|sailor|nurse>>
> I nod toward the newcomer. || <<Evening.|Come in, come in.|You picked a night for it.|There's a free spot here.>>
? here <<cane|basket|hat|baby|dog|sailor|nurse>>
> || <<Who else is here right now?|Who's around tonight?|So who all is in here with us?>>
? mentions-present

# w-two-at-once | Talking to two people at once | wide
> I look from {host} to {other}. || <<How do you two know each other?|Have you two been friends long?|Which of you has been here longer?>>
? voice-cast-ok
> || <<And what about you, {other}?|What do you think, {other}?>>
> I turn back to {host}. || <<Is that true?|Do you agree?|Is that how you remember it?>>
? facing {host}

# w-memory | Asking about something said earlier | wide
> I turn to {host}. || <<Tell me about your family.|Where did you grow up?|What did you do before this?>>
> || Huh. Go on.
> || <<Sorry, what was that you said a minute ago about where you grew up?|Wait, say that first part again?|What was it you told me earlier?>>
? recalls 2

# w-order | Ordering, waiting and getting it | wide
> I catch {hostposs} eye. || <<Could I get something hot to drink?|What do you have to eat?|Can I have a glass of water?|Anything warm to eat around here?>>
? stayed
> I wait for it, drumming my fingers. ||
? clock 0 20
> || <<Thanks, that looks good.|Thank you.|Perfect.>>
> || <<What did I order again?|Remind me what this was?>>

# w-give-take | Handing something over and getting it back | wide
> I pick up {thing}. ||
? holding {thing}
> I hand {thing} to {other}. || <<Could you hold this a second?|Have a look at this.|What do you make of it?>>
? not-holding {thing}
> || <<Can I have that back?|I'll take that back now, thanks.>>
? holding {thing}

# w-world-event | The player narrates something happening | wide
> <<The lights flicker and go out for a moment.|A dog barks somewhere outside.|Thunder cracks right overhead.|Someone knocks twice on the door.|A glass falls and breaks somewhere.>> ||
> || <<What was that?|Did you hear that?|Is that normal around here?>>
? mentions <<light|dog|thunder|door|glass>>

# w-speech | Rambling, half-finished speech | wide
> || <<So, um, I was wondering, like, do you ever, you know, think about leaving?|Okay this is kind of a weird question but, uh, are you happy here?|I mean, I guess what I'm asking is, what's the best part of your day?>>
? stayed
> || <<Sorry, that came out wrong.|Never mind, forget I asked.|No, really, I want to know.>>

# w-lean | A small physical action while talking | wide
> <<I lean on the counter.|I rub my hands together to warm them.|I take off my hat.|I stretch my back.|I fold my arms.>> || <<Long day?|Quiet tonight, huh?|What's the story with this place?>>
? stayed
> || <<Really?|No kidding.|Huh, I didn't know that.>>

# w-wrong-thing | Asking for something the place doesn't have | wide
> || <<Do you have a telephone I could use?|Can I pay with a card?|Is there a television around here?|Got any of those new radios?>>
? stayed
> || <<Never mind then.|That's all right.>>

# w-outside-with | Going outside with someone and coming back | wide
> I turn to {other}. || <<Want to step outside for some air with me?|Come out with me for a minute?>>
? stayed
> {other} and I go out to {outside}. ||
? moved
? outdoor-clean
? here {other}
> We come back inside together. ||
? back
? here {other}

# w-sit-near | Sitting down next to someone | wide
> I walk over and sit down next to {host}. || <<Mind if I sit?|Is this seat taken?|Room for one more?>>
? near {host}
? seated

# w-time-question | Asking the time and the date | wide
> || <<What time is it?|How late is it getting?|Is it morning yet?>>
? clock 0 15
> || <<What day is it today?|What's the date?|What year did you say it was?>>

# w-wait-short | Different short waits | wide
> <<I finish my drink slowly.|I wait for the noise to die down.|I watch the rain for a few minutes.|I take a moment to read the sign on the wall.>> ||
? clock 0 20

# w-wait-long | Different long waits | wide
> <<We talk well into the night, a good two hours.|Two hours pass before I notice.|I nap for about three hours.>> ||
? long-turn
? clock 90 240

# w-name-both | Learning both names | wide
> I turn to {host}. || <<I'm Sam, by the way. And you are?|We haven't been introduced. I'm Sam.>>
? player-named Sam
? known {host}
> I turn to {other}. || <<And what's your name?|I didn't catch your name.>>
? known {other}

# w-pick-describe | Picking something up and asking about it | wide
> I pick up {thing} and turn it over in my hands. ||
? holding {thing}
> || <<Where did this come from?|How old is this?|Is this yours?>>
> I put {thing} down where I found it. ||
? not-holding {thing}

# w-leave-alone | Leaving alone and finding things changed | wide
> I head out to {outside} on my own. ||
? moved
> I wait out there <<a few minutes|a little while|until I'm cold>>. ||
> I go back inside. ||
? back
> || <<Did I miss anything?|What happened while I was gone?>>

# w-who-is-here-loose | Asking who is here in other words | wide
> I look around the room. || <<Is anyone else here?|Who else is in the room?|Who are all these people?|Is there anybody else around?>>
? mentions-present
> I turn to {host}. || <<And who's that over there?|Who's that, then?>>
? mentions {other}

# w-ask-by-name | Asking after someone by name, then about them | wide
> I turn to {host}. || <<Where's {other} got to?|What's {other} up to?|Is {other} all right?>>
? mentions {other}
> || <<Tell me about {other}.|How long have you known {other}?>>
? mentions {other}

# w-remembers-thread | Coming back to something said earlier in a talk | wide
> I turn to {host}. || <<What did you do before you worked here?|Where did you grow up?|Who taught you this trade?>>
> || Huh. And do you like it here?
> || What's the busiest night you've had?
> || <<What do you do when it's quiet?|Do you ever close early?>>
> || Going back to what you said earlier, about before. Tell me more about that.
? recalls 4

# w-opens-up | Showing real interest, turn after turn | wide
> I turn to {host}. || How long have you been here?
> || That sounds like a long time. Do you ever miss anything about before?
> || Go on.
> || I'm sorry. That must have been hard.
> || What keeps you going, then?
? opened {host}
"""#

    struct Line {
        var did: String
        var said: String
        var checks: [String] = []
    }
    struct Scenario {
        var id: String
        var title: String
        var lines: [Line]
        /// "core" (fixed baseline), "regressions" (room transitions, voices, movement), or "wide".
        var set = "core"
    }

    static let coreScenarios: [Scenario] = parse(bank)
    static let regressionScenarios: [Scenario] = parse(regressions)
    static let wideScenarios: [Scenario] = parse(wide)
    static let all: [Scenario] = coreScenarios + regressionScenarios + wideScenarios

    static func scenarios(for suite: String) -> [Scenario] {
        switch suite {
        case "regressions": return regressionScenarios
        case "core": return coreScenarios
        default: return all
        }
    }

    /// Which set a scenario belongs to, by id ("improvised" for the simulated player's turns).
    static func set(of id: String) -> String {
        all.first { $0.id == id }?.set ?? (id == "improvised" ? "improvised" : "other")
    }

    static func parse(_ text: String) -> [Scenario] {
        var out: [Scenario] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).components(separatedBy: "|")
                out.append(Scenario(id: parts[0].trimmingCharacters(in: .whitespaces),
                                    title: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "", lines: [],
                                    set: parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : "core"))
            } else if line.hasPrefix("> "), !out.isEmpty {
                let parts = line.dropFirst(2).components(separatedBy: "||")
                out[out.count - 1].lines.append(Line(did: parts[0].trimmingCharacters(in: .whitespaces),
                                                     said: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""))
            } else if line.hasPrefix("? "), !out.isEmpty, !out[out.count - 1].lines.isEmpty {
                let n = out[out.count - 1].lines.count - 1
                out[out.count - 1].lines[n].checks.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        return out.filter { !$0.lines.isEmpty }
    }
}
