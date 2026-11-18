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
enum TestScenarios {
    static let bank = #"""
# newcomer-violin | Someone walks in
> I look over to the door as a young man with a violin case comes in out of the weather. ||
? newcomer violin|young man|musician
> I nod to the young man with the violin case. || Come on in, get warm.
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
> I sit quietly for a minute and listen. ||
? clock 0 15

# time-hour | An hour goes by
> I talk with {host} for about an hour about nothing much. ||
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

    struct Line {
        var did: String
        var said: String
        var checks: [String] = []
    }
    struct Scenario {
        var id: String
        var title: String
        var lines: [Line]
    }

    static let all: [Scenario] = parse(bank)

    static func parse(_ text: String) -> [Scenario] {
        var out: [Scenario] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).components(separatedBy: "|")
                out.append(Scenario(id: parts[0].trimmingCharacters(in: .whitespaces),
                                    title: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "", lines: []))
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
