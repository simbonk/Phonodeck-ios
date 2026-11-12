import Foundation

/// Checks for what the player picks up, run once at launch in debug builds. Each case is a line a
/// player really typed; a failure is printed to the console and kept in `failures`.
@MainActor
enum PickUpChecks {
    static private(set) var failures: [String] = []

    static func run() {
        var bad: [String] = []
        func expect(_ input: String, _ want: String?) {
            let got = StoryEngine.pickedUp(input)
            if got != want { bad.append("pickedUp(\"\(input)\") gave \(got ?? "nil"), wanted \(want ?? "nil")") }
        }
        // Build s: "every single" wasn't a word the check knew, so nothing reached your hands.
        expect("I get up and walk around the bar and pick up every single barstool in my hands", "the barstools")
        expect("I pick up all of the stools and hold them", "the stools")
        expect("I pick up the empty glass from the bar.", "the empty glass")
        expect("I pick up a stool and carry it over to the booth.", "the stool")
        expect("I pick the glass up", "the glass")
        expect("I grab a couple of glasses", "the glasses")
        expect("I take every one of the bottles", "the bottles")
        expect("pick up barstools", "the barstools")
        // Saying no, people, and things that aren't things.
        expect("I can't take this what's it for", nil)
        expect("I don't want to pick up the glass", nil)
        expect("I take the bartender with me", nil)
        expect("I take her hand", nil)
        expect("I take a seat at the bar", nil)
        expect("I take a sip of my whiskey", nil)
        expect("I pick up where we left off", nil)

        // A joined word counts against its parts: the premise says "stool", the player says "barstool".
        let checks: [(String, String, Bool)] = [
            ("barstool", "I take a stool at the bar", true),
            ("barstools", "she watches as you lift the stools", true),
            ("stool", "a barstool by the window", true),
            ("umbrella", "a stool at the bar", false),
        ]
        for (thing, story, want) in checks where Continuity.grounded(thing, in: Continuity.wordSet(story)) != want {
            bad.append("grounded(\"\(thing)\") in \"\(story)\" should be \(want)")
        }

        // "Keep it safe" → "I'll keep it": the watch she just set down.
        let reply = "Her fingers gently place a small, silver pocket watch on the bar between you two. \"Keep it safe.\""
        let props = ["an oil lamp", "a jazz record", "silver pocket watch"]
        if StoryEngine.pickedUpIt("Okay, I'll keep it", lastReply: reply, props: props) != "silver pocket watch" { bad.append("pickedUpIt didn't find the watch") }
        if StoryEngine.pickedUpIt("I can't take it", lastReply: reply, props: props) != nil { bad.append("pickedUpIt took the watch after a no") }

        failures = bad
        for b in bad { print("PickUpChecks failed: " + b) }
    }
}
