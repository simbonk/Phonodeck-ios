import SwiftUI
import UIKit

/// One scripted playthrough: a story to start and the player's lines, said one per turn.
struct PlayScript: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var story: Experience
    var lines: [String]
}

enum PlayScripts {
    /// The set-up keys a pasted script may use to describe its own world.
    private static let keys = ["story", "place", "goal", "feeling", "who", "world", "describe", "allies", "vibe", "avoid"]

    /// A curated story by a word from its name ("speakeasy", "ashore", "magician", "lighthouse").
    static func curated(_ word: String) -> Experience? {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return nil }
        if w.contains("atoll") || w.contains("island") { return CuratedExperiences.atoll }
        return CuratedExperiences.all.first { $0.title.lowercased().contains(w) }
    }

    /// Scripts typed or pasted as text. A script starts with "# its name". Lines like
    /// "story: speakeasy" or "place: ..." set the world up; every other line is said by the player.
    static func parse(_ text: String) -> [PlayScript] {
        var out: [PlayScript] = []
        var title = ""
        var story = Experience()
        var lines: [String] = []
        var custom = false
        func close() {
            if !lines.isEmpty {
                var e = story
                if custom {
                    e.simulator = true
                    e.minutes = 20
                    if e.title.isEmpty { e.title = title.isEmpty ? "Auto-play" : title }
                }
                out.append(PlayScript(title: title.isEmpty ? "Script \(out.count + 1)" : title, story: e, lines: lines))
            }
            title = ""; story = Experience(); lines = []; custom = false
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                close()
                title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                story = CuratedExperiences.speakeasy
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if keys.contains(key), !value.isEmpty {
                    if key == "story" {
                        if let e = curated(value) { story = e; custom = false }
                        continue
                    }
                    if !custom { story = Experience(); custom = true }
                    switch key {
                    case "place": story.place = value
                    case "goal": story.goal = value
                    case "feeling": story.feeling = value
                    case "who": story.who = value
                    case "world": story.world = value
                    case "describe": story.describe = value
                    case "allies": story.allies = value
                    case "vibe": story.vibe = value
                    default: story.avoid = value
                    }
                    continue
                }
            }
            if title.isEmpty && lines.isEmpty && !custom { story = CuratedExperiences.speakeasy }
            lines.append(line)
        }
        close()
        return out
    }

    /// The scripts that ship with the app. Each one leans on a part of the world-keeping that
    /// has gone wrong before: names, newcomers, leaving and coming back, things in hand, time.
    static let starters: [PlayScript] = parse(starterText)

    static let starterText = """
    # 01 Who do you mean
    I sit at the bar and nod to the bartender.
    I watch what the woman in the corner booth is doing.
    What are you making there?
    Why that colour?
    I turn back to the bar. What are you polishing?
    How long have you been doing that?
    I look over at the booth again. Is that for someone special?
    Who is here with me now?

    # 02 Asking a name by her or him
    I sit at the bar beside the bartender.
    I walk over to the woman and ask her what her name is.
    I tell her my name is Sam.
    I go back to the bar and ask him what his name is.
    I ask him what her name was again.
    Who is here with me now?

    # 03 Picking things up
    I pick up the empty glass from the bar.
    What am I holding?
    I pick up a stool and carry it over to the booth.
    What am I carrying now?
    I put the stool down and sit on it.
    I grab the umbrella by the door.
    What do I have with me?
    I hand the glass back to the bartender.
    What am I holding now?
    I get up and pick up every single barstool in my hands.
    What am I holding now?

    # 04 True to the year
    I sit at the bar. What year is it?
    I ask the bartender how long this place has been open.
    Do you have a radio in here?
    What is the newest car you have seen?
    I ask the woman what she thinks the city will look like in fifty years.
    What song is playing?
    What did you do before this?

    # 05 Straight questions
    I sit at the bar beside the nearest regular. Hello, my name is Simon.
    What are you working on there?
    Why are you doing that?
    I ask if she likes milk.
    I ask the bartender how long this place has been open.
    Who owns this place?
    I ask her where she grew up.
    What time do you close?
    I ask the bartender if the back room is open tonight.
    Why is it so quiet in here tonight?


    # 06 Back to the bar
    I sit at the bar and order a coffee.
    I tell them my name is Sam and I am a salesman from Chicago.
    I step out into the flower shop at the front for some air.
    I look at the flowers for a minute.
    I go back to the bar and take my old stool.
    Who is here with me?
    I ask the bartender if he remembers my name and where I am from.
    I go out to the street to look at the rain.
    I walk back to the speakeasy.
    I sit back down on my stool. Where am I?
    I ask the woman at the bar what she is working on.
    I ask them both what they know about me.

    # 07 Down to the cellar and up
    I sit at the bar and offer to help the bartender.
    I ask him what is down in the cellar.
    I follow him down to the cellar.
    I pick up a crate of bottles.
    I carry the crate upstairs.
    I put the crate down behind the bar.
    Where am I, and who is with me?
    I go back down to the cellar alone to get a bag of ice.
    I bring the ice up to the bar.
    I sit back down on my stool.
    I ask the woman at the bar if she saw me working.
    I ask the bartender if I have earned a drink.

    # 08 Someone walks in
    I sit at the bar and order a coffee.
    I tell them my name is Sam.
    I look to the door as a young man with a violin case comes in.
    I ask the young man his name.
    I invite him to sit with us.
    Who is in this room right now?
    A woman in a red coat walks in, shaking out her umbrella.
    I ask the woman in the red coat if she is waiting for someone.
    I ask the bartender if he knows either of them.
    Who is in this room now?

    # 09 Out and about
    I sit at the bar and tell the woman next to me my name is Sam.
    I ask her if she would like to take a walk with me.
    We leave together through the flower shop.
    We walk down the street in the rain.
    We stop under a streetlamp and talk for a while.
    Where are we, and who is with me?
    We walk back to the speakeasy together.
    I sit back down on my stool.
    Where am I, and who is here?
    I order a drink for both of us.

    # 10 Sitting back down
    I sit at the bar and order a coffee.
    I go out to the street to look at the rain.
    I walk back to the speakeasy.
    I sit back down on my stool.
    Where am I?
    I go down to the cellar with the bartender.
    I carry a crate back up to the bar.
    I sit back down on my stool.
    Where am I, and who is with me?
    I ask the bartender what time it is.

    # 11 Things left behind
    I take off my hat and put it on the bar next to me.
    I order a whiskey and put a dollar beside it.
    I step out into the flower shop and buy a single red rose.
    I go out to the street and look at the rain.
    I walk back to the speakeasy with the rose.
    Is my hat still on the bar where I left it?
    I give the rose to the woman at the bar.
    What am I carrying now?
    I put my hat back on.
    What is on the bar in front of me?


    # 12 Someone leaves
    I sit at the bar and say hello to both of them.
    I ask the woman what time she has to go home.
    The woman says goodnight, puts on her coat and leaves.
    Who is here with me now?
    I ask the bartender where she lives.
    I talk with the bartender about the rain for half an hour.
    I ask him if he thinks she will come back tonight.
    The woman comes back in, soaked, because she forgot her umbrella.
    I ask her what happened.
    Who is here with me now?


    # 13 A name given late
    I sit at the bar next to a quiet man in a grey suit.
    I nod to the man in the grey suit and say it is a rough night.
    I ask the bartender who the man in the grey suit is.
    I ask the man in the grey suit what his name is.
    I tell him my name is Sam.
    I ask him what he does for work.
    I ask the bartender if he knew the man's name.
    I buy the man in the grey suit a drink, and say his name.
    Who is here with me now?
    I ask the man what brought him out tonight.

    # 14 The hat I left behind
    I take off my hat and my wet coat and hang the coat on the hook by the door.
    I put my hat down on the bar next to me and order a whiskey.
    I take a notebook and a pencil out of my pocket and put them on the bar.
    I ask the bartender if he minds me writing here.
    I write a few lines in the notebook.
    I ask the woman at the bar what her name is.
    I tear a page out of the notebook and write my name, Sam, on it for her.
    I hand her the page.
    I move from the bar to the small table by the gramophone, with my drink.
    What did I leave on the bar?
    I go back to the bar and get my notebook.
    I ask the bartender to keep my hat behind the bar for me.
    I step out to the street for a cigarette, leaving my coat on its hook.
    I stand in the rain for a few minutes and then come back in.
    Is my coat still on the hook?
    I ask the bartender for my hat back.
    I put the hat on and the pencil in my pocket.
    What do I have on me now, and what is still lying around?
    I ask the woman if she still has the page I gave her.
    I put on my coat and sit back down for one more.

    # 15 A long evening
    I take a stool. What time is it?
    I order a drink and ask the bartender how his night is going.
    I talk with the bartender about the weather for a good half hour.
    I ask the woman at the bar what she is drinking.
    We talk for an hour about the pictures she has worked on.
    I ask what time it is now.
    I order some food if they have any.
    I eat slowly and listen to the rain.
    I doze off on my stool for a couple of hours.
    I wake up. Who is still here?
    I ask the bartender how long I was asleep.
    I ask if the rain has stopped.
    I stay until the small hours, talking about nothing much.
    I ask what time they close.
    I ask the woman how she is getting home at this hour.
    I look up at the skylight. What does the sky look like?
    I wait until dawn.
    I ask the bartender what he does when the sun comes up.
    I ask what day it is now.
    I pay and say good morning.

    # 16 Paying my way
    I sit at the bar and check my wallet. How much do I have?
    I ask what a drink costs here.
    I order a gin and put a dollar on the bar.
    I ask for my change.
    I offer to buy the woman at the bar a drink.
    I ask the bartender to put it on my tab.
    I ask how much I owe so far.
    I put the change in my coat pocket.
    I ask the bartender how much he has saved toward his dream.
    I slide a five dollar bill across the bar as a tip for him.
    I ask the woman what a costume like hers costs to make.
    I buy a round for everyone in the room.
    I ask who else is in here to drink it.
    I ask what I owe now.
    I pay the tab in full.
    I check my wallet again. What is left?
    I ask the bartender if he will take a cheque.
    I try to pay with a gold watch I do not have.
    I ask if there is anything else I owe.
    I count out what is in my pockets on the bar.

    # 17 A dance by the gramophone
    I come in and sit at the bar.
    I ask the bartender what record that is.
    I ask the woman at the bar if she likes this song.
    I tell her my name is Sam. What is hers?
    I ask her if she would like to dance.
    I take her hand and we go over to the gramophone.
    We dance slowly next to the gramophone.
    I ask her where she learned to dance.
    I spin her around.
    The record ends. I ask the bartender to put on another.
    I go to the gramophone and look through the records myself.
    I pick one and hand it to the bartender.
    I ask her for one more dance.
    We dance until the record ends.
    I walk her back to her stool.
    I sit down next to her. Where is everyone now?
    I ask her if she has ever sewn a dancing dress.
    I ask the bartender if he ever dances.
    I ask him to dance with her while I watch the bar.
    I go behind the bar and stand where he usually stands.

    # 18 A person of few words
    I sit.
    Coffee.
    Thanks.
    I nod at the woman.
    Sam.
    You?
    I listen.
    Hm.
    Go on.
    Why?
    I look around.
    I wait.
    Another.
    And you, bartender?
    Really.
    I laugh.
    I look at the door.
    What time is it?
    I stand up.
    Goodnight.

    # 19 A hand of cards
    I sit at the bar and ask if anyone plays cards.
    I ask the bartender if he has a deck.
    I shuffle the deck.
    I ask the woman at the bar to join us.
    I deal three hands of five cards.
    I look at my cards. What do I have?
    I ask the bartender if he wants to bet a nickel.
    I put a nickel on the bar.
    I ask the woman if she is in.
    I swap two of my cards.
    I show my hand.
    I ask who won.
    I gather the cards and hand the deck to the woman to deal.
    I look at my new hand.
    I bet a dime this time.
    I ask the bartender what he has.
    I fold and put my cards down.
    I ask how much I have lost tonight.
    I give the deck back to the bartender.
    I ask them who taught them to play.

    # 20 No names tonight
    I come in out of the rain and sit down.
    I ask for a drink without saying who I am.
    I ask the bartender not to ask my name.
    I ask him what he does when a customer wants to be left alone.
    I look at the woman down the bar but say nothing.
    She says something to me. What does she say?
    I answer her politely but give no name.
    I ask her what she does, without asking her name.
    I ask the bartender about the record playing.
    I ask them what they call each other.
    I ask what they would call me, if they had to.
    I tell them that will do.
    I ask the woman what she hopes for.
    I ask the bartender what he hopes for.
    I tell them what I hope for: a quiet life somewhere by the sea.
    I ask if anyone has asked my name tonight.
    I ask what they know about me.
    I finish my drink.
    I put on my coat.
    I say goodnight without telling them who I was.

    # 21 Things I cannot do
    I sit at the bar and order a drink.
    I take a pistol out of my coat and put it on the bar.
    I check my pockets. What do I actually have?
    I pay with a hundred dollar bill.
    I climb up through the skylight onto the roof.
    I look at the skylight. Could I even reach it?
    I tell the bartender I own this building.
    I ask him what he makes of that.
    I pick up the gramophone and carry it out to the street.
    I ask the woman to hand me her sewing kit.
    I ask her if she has it with her.
    I call for the waiter.
    I ask the bartender who else works here.
    I walk through the wall into the flower shop.
    I walk through the door into the flower shop instead.
    I pick up the telephone on the flower shop counter and call the mayor.
    I go back in to the bar.
    I tell them I can read minds, and ask the bartender to think of a number.
    I guess seven.
    I ask them if I have been a nuisance.

    # 22 When the lights go out
    I sit at the bar and listen to the storm.
    I ask the bartender if the storm is getting worse.
    I look up at the skylight.
    There is a loud crack of thunder. I ask if everyone is all right.
    The lights flicker. I ask the bartender if that happens often.
    The lights go out. I stay where I am. What can I see?
    I ask the bartender if he has candles.
    I help him light the candles along the bar.
    I ask the woman if she is afraid of storms.
    I ask the bartender if the gramophone still works without power.
    I ask him to wind it up.
    I look around the room by candlelight. What looks different?
    I pick up a candle and carry it to the door to check the flower shop.
    I look into the flower shop by candlelight.
    I come back to the bar and put the candle down.
    I ask how long these blackouts usually last.
    We sit and talk by candlelight for an hour.
    The lights come back on. I ask the bartender to leave the candles lit.
    I ask what time it is.
    I ask them what they will remember about tonight.

    # 23 Something to give
    I sit at the bar with a small parcel under my arm.
    I put the parcel on the bar.
    I ask the bartender for a drink.
    The woman asks what is in the parcel. I tell her it is a photograph of my mother.
    I unwrap it and show them the photograph.
    I ask the bartender if he has a photograph of anyone.
    I ask the woman if she keeps anything from home.
    I take a letter out of my coat pocket.
    I ask the bartender if he would post it for me in the morning.
    I hand him the letter.
    I ask where he has put it.
    I wrap the photograph up again.
    I ask the woman if she would sew a button back on my coat.
    I hand her my coat.
    I ask her how long it will take.
    I wait while she sews.
    I take my coat back and thank her.
    I give her a dollar for her trouble.
    What do I have with me now, and what have I given away?
    I ask the bartender not to forget the letter.

    # 24 The records
    I sit at the bar and listen. What is playing?
    I ask the bartender whose records these are.
    I go over to the gramophone and look at it closely.
    I look through the stack of records. What is there?
    I pick one out and ask the bartender if I can put it on.
    I put the record on.
    I go back to my stool with the old record in my hand.
    I give the old record to the bartender.
    I ask the woman what music she works to.
    I ask her to pick the next one.
    I ask the bartender what his favourite is.
    I ask him where he got the gramophone.
    The record skips. I go and fix it.
    I ask what song this is.
    I turn the volume down a little.
    I ask the woman if she sings.
    I ask her to sing a line.
    I clap.
    I ask the bartender what was playing when I came in.
    I ask which record is on the gramophone right now.

    # 25 Closing time and tomorrow
    I sit at the bar and ask what time they close.
    I order a last drink.
    I ask the bartender what he does after closing.
    I ask the woman if she will be here tomorrow.
    I tell them I will come back tomorrow night.
    I pay and put on my coat.
    I say goodnight and leave through the flower shop.
    I walk to my hotel.
    I go up to my room and go to sleep.
    I wake up the next morning. What is the weather like?
    I spend the day walking around downtown.
    In the evening I walk back to the flower shop.
    I go through to the speakeasy.
    I look around. Is it the same as last night?
    I take the same stool.
    I ask the bartender if he remembers me.
    I ask what he did after closing last night.
    I ask if the woman from last night has been in.
    I ask what has changed since yesterday.
    I order the same drink as last night.

    # 26 Thinking out loud
    So I come in and, uh, I shake off my coat, and I guess I just kind of look around for a second before I sit down at the bar.
    I ask the bartender, you know, what's good here, and I tell him I don't really know what I want, maybe something warm, maybe not.
    I kind of turn to the lady next to me and say hi, and then I ask her if she comes here a lot or if tonight is special.
    I tell her my name's Sam, and I say I'm sorry if I'm talking too much, I've been on a train all day with nobody to talk to.
    I ask the bartender, wait, what was your name again, did you tell me, I don't think you told me.
    I'm gonna get up and go look at the gramophone, and while I'm there I ask over my shoulder who picks the music.
    I come back and sit down, actually no, I sit at the table by the wall instead, and I bring my drink.
    I ask the lady if she wants to come sit at the table, and if she says no that's fine too.
    I ask them both, like, what's the one thing they'd do if money didn't matter.
    I tell them mine would be a boat, a little one, nothing fancy, and I'd just go.
    I ask the bartender if he's ever been on a boat, and then I ask the lady the same thing.
    I go back to the bar because the table is too far from the conversation.
    I ask what time it is, and how long I've been here, because I've lost track.
    I say I should probably go soon but I don't really want to, and I ask if it's still raining.
    I ask the lady to tell me more about that thing she was saying before, about her work.
    I ask the bartender if he heard that, and what he thinks.
    I order another one of whatever I had, and I ask what it was I had.
    I ask if anyone's hungry, and if there's anywhere to eat around here this late.
    I say okay, okay, one more song and then I'm going, and I ask them to pick it.
    I say goodnight to both of them, by name, and I tell them I'll remember tonight.

    # 27 People who are not here
    I sit at the bar and order a drink.
    I ask the bartender who owns this place.
    I ask him when the owner comes in.
    I ask the woman at the bar who she works for at the studio.
    I ask her what her boss is like.
    I ask the bartender if he has a brother or sister.
    I ask where they are tonight.
    I ask the woman about her mother.
    I ask who runs the flower shop out front.
    I ask if the florist is there now.
    I ask the bartender who the regulars are that are not here tonight.
    I ask about the one he likes least.
    I ask the woman if she has a sweetheart.
    I ask where he is.
    I tell them about my brother Tom, who is a sailor.
    I ask the bartender what I told him my brother's name was.
    I ask if any of these people might come in tonight.
    I ask the bartender to describe the owner to me.
    Who have we talked about that is not in this room?
    Who is actually in this room?

    # 28 Never sitting still
    I sit at the bar.
    I get up and go to the gramophone.
    I go to the door and look into the flower shop.
    I step into the flower shop.
    I go out to the street.
    I cross the street and look back at the flower shop.
    I come back to the flower shop.
    I go through to the speakeasy.
    I walk to the back hallway.
    I come back and sit at the table by the wall.
    I move to the stool next to the woman.
    I ask her if I am making her dizzy.
    I go behind the bar.
    The bartender asks me to come out. I come out.
    I go back out to the street for one minute.
    I come straight back in to the bar.
    I sit down on my first stool.
    Where am I?
    Where have I been, in order?
    I promise the bartender I will stay put.

    # 29 Promises
    I sit at the bar and order a drink.
    I ask the bartender what he is saving for.
    I promise I will be his first customer when he opens his own place.
    I ask the woman what her big break would look like.
    I promise to introduce her to a director I know.
    I ask her to write down her address for me.
    I put the address in my pocket.
    I ask the bartender to remind me before I go to pay my tab.
    I ask the woman to promise me a dance later.
    I ask the bartender a question: what is the secret of a good drink?
    I ask him to tell me before the night is over.
    I tell the woman a secret: I am afraid to go home.
    I ask her to keep it to herself.
    I ask the bartender if she told him.
    I ask the woman for that dance she promised.
    We dance.
    I ask the bartender for the secret he promised.
    I ask what promises I have made tonight.
    I ask what I still owe anybody.
    I pay my tab and check that I still have her address.

    # 30 A bit of everything
    I duck in from the storm, hang my coat by the door and sit at the bar.
    I order something warm and tell the bartender my name is Sam.
    I ask his name and the name of the woman down the bar.
    I ask her what she is sewing this week.
    I put a dollar on the bar and ask for change for the telephone.
    I walk to the back to make a call, then come back.
    I look to the door as a young man with a violin case comes in.
    I ask the young man his name and if he plays.
    I ask him to play something.
    I listen, then clap and buy him a drink.
    I step out to the flower shop to buy a flower for the woman.
    I come back in and give it to her.
    We talk for an hour, all four of us, about what we want from life.
    I ask each of them, by name, what they said.
    I ask the violin player to walk with me to the street for some air.
    We stand under the awning. I ask him where he is staying.
    We go back in together.
    I ask the bartender what time it is and what I owe.
    I pay, put on my coat, and check my pockets.
    I say goodnight to each of them by name.
    """
}

/// Plays scripted stories on the phone itself, with the voice off, and saves each story's export.
@Observable
@MainActor
final class AutoPlay {
    private let engine: StoryEngine
    private(set) var running = false
    private(set) var status = ""
    private(set) var log: [String] = []
    private(set) var exports: [URL] = []
    private(set) var combined: URL?
    /// The short version of every play, for reading many at once.
    private(set) var digest: URL?
    private var job: Task<Void, Never>?

    /// Starter scripts switched off, by name.
    var skipped: Set<String> { didSet { UserDefaults.standard.set(Array(skipped), forKey: "autoPlaySkipped") } }
    /// The player's own scripts, as text.
    var custom: String { didSet { UserDefaults.standard.set(custom, forKey: "autoPlayCustom") } }
    /// How many times each script is played (the model answers differently each time).
    var repeats: Int { didSet { UserDefaults.standard.set(repeats, forKey: "autoPlayRepeats") } }

    init(engine: StoryEngine) {
        self.engine = engine
        let d = UserDefaults.standard
        skipped = Set(d.stringArray(forKey: "autoPlaySkipped") ?? [])
        custom = d.string(forKey: "autoPlayCustom") ?? ""
        repeats = max(1, d.integer(forKey: "autoPlayRepeats"))
    }

    var queue: [PlayScript] {
        let chosen = PlayScripts.starters.filter { !skipped.contains($0.title) } + PlayScripts.parse(custom)
        var out: [PlayScript] = []
        for _ in 0..<max(1, repeats) { out += chosen }
        return out
    }

    /// A rough guess at how long the queue takes, in minutes (about a minute and a half a turn).
    var estimate: Int {
        let turns = queue.reduce(0) { $0 + $1.lines.count + 2 }
        return Int((Double(turns) * 1.5).rounded())
    }

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "AutoPlay")
    }

    func start() {
        let scripts = queue
        guard !running, !scripts.isEmpty else { return }
        running = true
        log = []
        exports = []
        combined = nil
        digest = nil
        let narrated = engine.narrate
        engine.setHandsFree(false)
        engine.holdNarrate = true
        engine.narrate = false
        UIApplication.shared.isIdleTimerDisabled = true
        let stamp = Self.stamp()
        let dir = folder.appending(path: stamp)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        job = Task {
            var all: [String] = []
            var short: [String] = []
            for (n, script) in scripts.enumerated() {
                if Task.isCancelled { break }
                let (text, brief) = await self.play(script, number: n + 1, of: scripts.count)
                let plain = script.title.filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
                let name = "Play " + String(format: "%02d ", n + 1) + plain + ".txt"
                let url = dir.appending(path: name)
                if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { self.exports.append(url) }
                all.append(text)
                // The whole set so far, so a run that is stopped (or the app closing) still leaves a file.
                let whole = dir.appending(path: "Phonodeck auto-play " + stamp + ".txt")
                let joined = all.joined(separator: "\n\n\n==================================================\n\n\n")
                if (try? joined.write(to: whole, atomically: true, encoding: .utf8)) != nil { self.combined = whole }
                short.append(brief)
                let small = dir.appending(path: "Phonodeck auto-play digest " + stamp + ".txt")
                let lead = "PHONODECK AUTO-PLAY DIGEST · " + StoryEngine.build + " · \(short.count) of \(scripts.count) plays\n"
                    + "Each turn: what the player said, the start of the reply, the world as the app held it afterwards, and anything the checks caught.\n\n"
                if (try? (lead + short.joined(separator: "\n\n")).write(to: small, atomically: true, encoding: .utf8)) != nil { self.digest = small }
            }
            self.engine.stopAll()
            self.engine.close()
            self.engine.narrate = narrated
            self.engine.holdNarrate = false
            UIApplication.shared.isIdleTimerDisabled = false
            self.status = Task.isCancelled ? "Stopped." : "Finished \(scripts.count) " + (scripts.count == 1 ? "story." : "stories.")
            self.running = false
        }
    }

    func stop() {
        guard running else { return }
        status = "Stopping after saving what was played"
        job?.cancel()
        engine.stopAll()
    }

    /// Removes every saved export.
    func clear() {
        guard !running else { return }
        try? FileManager.default.removeItem(at: folder)
        exports = []
        combined = nil
        digest = nil
        log = []
        status = ""
    }

    /// Plays one script from a fresh world and gives back its export.
    private func play(_ script: PlayScript, number: Int, of count: Int) async -> (String, String) {
        let began = Date()
        let label = "Story \(number) of \(count): " + script.title
        var notes: [String] = []
        var played = 0
        engine.stopAll()
        engine.close()
        engine.error = nil
        status = label + " · building the world"
        engine.create(script.story, player: PlayerDetails.saved)
        let built = await engine.waitUntilIdle(limit: 900)
        let opened = (engine.adventure?.transcript.isEmpty == false)
        if !built || !opened {
            let why: String = engine.error ?? (Task.isCancelled ? "stopped" : built ? "no opening was written" : "it took more than 15 minutes")
            notes.append("The world did not build: " + why)
            engine.stopAll()
        } else {
            for (i, line) in script.lines.enumerated() {
                guard !Task.isCancelled, let a = engine.adventure, !a.ended else { break }
                status = label + " · turn \(i + 1) of \(script.lines.count)"
                let before = a.transcript.count
                engine.error = nil
                engine.send(line)
                let done = await engine.waitUntilIdle(limit: 480)
                if !done {
                    if !Task.isCancelled { notes.append("Turn \(i + 1) took more than 8 minutes and was stopped: " + line) }
                    engine.stopAll()
                    break
                }
                if let e = engine.error { notes.append("Turn \(i + 1) error: " + e) }
                if (engine.adventure?.transcript.count ?? 0) <= before {
                    if Task.isCancelled { break }
                    notes.append("Turn \(i + 1) got no reply: " + line)
                    continue
                }
                played += 1
            }
        }
        let mins = String(format: "%.1f", Date().timeIntervalSince(began) / 60)
        var head = ["AUTO-PLAY · " + script.title + " · " + StoryEngine.build,
                    "Played \(played) of \(script.lines.count) lines in \(mins) minutes."]
        head += notes.map { "PROBLEM: " + $0 }
        let story = engine.storyText()
        log.append(script.title + ": \(played) of \(script.lines.count) lines, \(mins) min" + (notes.isEmpty ? "" : ", \(notes.count) " + (notes.count == 1 ? "problem" : "problems")))
        var brief = "=== PLAY \(number): " + script.title + " · \(played) of \(script.lines.count) lines · \(mins) min ==="
        for n in notes { brief += "\nPROBLEM: " + n }
        if let a = engine.adventure { brief += "\n" + Self.brief(a) }
        engine.discard()
        return (head.joined(separator: "\n") + "\n\n" + (story.isEmpty ? "(no story)" : story), brief)
    }

    private static func cut(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    /// The short version of one play: a few lines a turn.
    static func brief(_ a: Adventure) -> String {
        var out: [String] = []
        let replies = a.transcript.filter { $0.role == .gm }.count
        let offset = a.frames.count - replies
        let flags = ["REPLY CHECK", "NAME CHECK", "SETTLED IN CODE", "THE PLAYER CANNOT DO THAT AS SAID", "A NEW PERSON COMES IN", "SINCE YOU WERE LAST HERE"]
        var g = 0
        var turn = 0
        for t in a.transcript {
            if t.role == .player {
                turn += 1
                out.append("T\(turn) YOU: " + cut(t.text, 220))
                continue
            }
            out.append((turn == 0 ? "OPENING: " : "  GM: ") + cut(t.text, turn == 0 ? 400 : 300))
            let notes: [String] = (t.before ?? "").components(separatedBy: "\n")
            for line in notes {
                if flags.contains(where: { line.hasPrefix($0) }) { out.append("  ! " + cut(line, 220)) }
                if line.hasPrefix("TIMES:"), let r = line.range(of: "total ") { out.append("  took " + cut(String(line[r.upperBound...]), 40)) }
            }
            let i = g + offset
            g += 1
            guard i >= 0, i < a.frames.count else { continue }
            let f = a.frames[i]
            var now: [String] = [f.place.isEmpty ? "no place" : f.place]
            if !f.time.isEmpty { now.append(f.time) }
            if let s = f.spot, !s.isEmpty { now.append("spot: " + s) }
            out.append("  NOW: " + cut(now.joined(separator: " · "), 200))
            if !f.with.isEmpty { out.append("  WITH: " + cut(f.with.joined(separator: "; "), 240)) }
            if !f.room.isEmpty { out.append("  ROOM: " + cut(f.room.joined(separator: "; "), 200)) }
            if !f.away.isEmpty { out.append("  AWAY: " + cut(f.away.joined(separator: "; "), 160)) }
            if !f.have.isEmpty { out.append("  HAVE: " + cut(f.have.joined(separator: "; "), 200)) }
            if !f.around.isEmpty { out.append("  AROUND: " + cut(f.around.joined(separator: "; "), 200)) }
            let knows: [String] = f.knows ?? []
            if !knows.isEmpty { out.append("  KNOW: " + cut(knows.joined(separator: "; "), 240)) }
            let hanging: [String] = f.pending ?? []
            if !hanging.isEmpty { out.append("  HANGING: " + cut(hanging.joined(separator: "; "), 240)) }
            if !f.changed.isEmpty { out.append("  CHANGED: " + cut(f.changed.joined(separator: "; "), 300)) }
            if !f.notes.isEmpty { out.append("  NOTES: " + cut(f.notes.joined(separator: "; "), 240)) }
        }
        let people: [String] = a.lore.filter { $0.kind == .person && !$0.isPlayer }.map(\.name)
        let places: [String] = a.lore.filter { $0.kind == .place }.map(\.name)
        out.append("END: player name \"" + a.playerName + "\" · people: " + people.joined(separator: ", ") + " · places: " + places.joined(separator: ", "))
        if !a.facts.isEmpty { out.append("FACTS (\(a.facts.count)): " + a.facts.suffix(25).map { cut($0, 120) }.joined(separator: " | ")) }
        return out.joined(separator: "\n")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f.string(from: Date())
    }
}

/// The test screen: pick scripts, run them, share the exports.
struct AutoPlayView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var auto = app.autoPlay
        Form {
            Section {
                if auto.running {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(auto.status).font(.subheadline)
                    }
                    Button("Stop", role: .destructive) { auto.stop() }
                } else {
                    Button {
                        auto.start()
                    } label: {
                        Label("Run \(auto.queue.count) " + (auto.queue.count == 1 ? "story" : "stories"), systemImage: "play.fill")
                    }
                    .disabled(auto.queue.isEmpty || app.engine.busy || app.benchmark.running)
                    if !auto.status.isEmpty { Text(auto.status).font(.subheadline).foregroundStyle(.secondary) }
                }
                ForEach(Array(auto.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Plays each script by itself with the voice off, waits for every question to finish, and saves the story export. About \(auto.estimate >= 120 ? "\(auto.estimate / 60) hours" : "\(auto.estimate) minutes") for this set, and each play is saved as it finishes, so you can stop early. Keep Phonodeck open and the phone plugged in: the screen stays on while it runs. You can watch the story on the Phonodeck tab. Uses the storyteller and engine chosen in Settings.")
            }

            if let all = auto.combined {
                Section {
                    if let small = auto.digest {
                        ShareLink(item: small) { Label("Share the digest (send this one)", systemImage: "square.and.arrow.up") }
                    }
                    ShareLink(item: all) { Label("Share the full exports (one big file)", systemImage: "doc.on.doc") }
                    ForEach(auto.exports, id: \.self) { url in
                        ShareLink(item: url) { Text(url.deletingPathExtension().lastPathComponent).font(.subheadline) }
                    }
                    if !auto.running {
                        Button("Delete saved exports", role: .destructive) { auto.clear() }
                    }
                } header: {
                    Text("Exports")
                }
            }

            Section {
                ForEach(PlayScripts.starters) { s in
                    Toggle(isOn: Binding(get: { !auto.skipped.contains(s.title) },
                                         set: { on in if on { auto.skipped.remove(s.title) } else { auto.skipped.insert(s.title) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title)
                            Text(s.story.title + " · \(s.lines.count) lines").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(auto.skipped.isEmpty ? "Turn all off" : "Turn all on") {
                    auto.skipped = auto.skipped.isEmpty ? Set(PlayScripts.starters.map(\.title)) : []
                }
                Stepper("Play each one \(auto.repeats) " + (auto.repeats == 1 ? "time" : "times"), value: $auto.repeats, in: 1...10)
            } header: {
                Text("Scripts (\(PlayScripts.starters.count - auto.skipped.count) on)")
            }
            .disabled(auto.running)

            Section {
                TextEditor(text: $auto.custom)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 160)
                    .autocorrectionDisabled()
                let mine = PlayScripts.parse(auto.custom)
                if !mine.isEmpty {
                    Text(mine.map { $0.title + " (\($0.lines.count) lines)" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Your own scripts")
            } footer: {
                Text("Start each script with \"# its name\". Add \"story: speakeasy\" (or ashore, magician, lighthouse) to pick a story, or describe your own world with lines like \"place: ...\", \"goal: ...\", \"feeling: ...\", \"who: ...\" and \"allies: ...\". Every other line is said by the player, one per turn.")
            }
            .disabled(auto.running)
        }
        .navigationTitle("Auto-play")
        .navigationBarTitleDisplayMode(.inline)
    }
}
