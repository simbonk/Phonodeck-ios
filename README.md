# Phonodeck for iPhone

An audio storytelling app that runs entirely on your iPhone. You download a language model once, and from then on it works in Airplane Mode: nothing you say or write leaves the phone.

- **Phonodeck tab:** the same flow as the web app. A set-up wizard asks how long you have, then offers curated worlds or walks you through building your own (the storyteller suggests answers if you pause). A build screen shows the world being made: story, map, characters and lore, the Game Master and the Director. Then the Game Master tells it aloud, keeps an eye on the clock, lands a real ending, and grades the result with a report card. Play by typing, or tap **hands-free** and just talk (say **"make it so"** to send).
- **World button:** the globe in a story opens the Mission (feeling meter, mission track, events), the Story bible, and the World: every character, place, item and faction the story has collected. Edit or add anything; your words always win.
- **Chat tab:** a plain conversation with the same on-device model.
- **Models tab:** download the storyteller, narrator voice and listening models from Hugging Face. Every model shows whether it will run comfortably on *this* phone before you download it. Paste a link to add any other MLX model.
- **Share experiences:** export a set-up as a small `.phonodeck` file and send it to someone; they tap it to import.
- **Optional passcodes:** a secret passcode (or Face ID) opens your own chats and stories; a demo passcode opens an empty Phonodeck to show people.

This is the on-device sibling of the [Phonodeck web app](https://github.com/simbonk/phonodeck), which uses Gemini in the cloud.

## The models

All are free, and all run offline once downloaded.

| Job | Fast | Medium | Good, slower |
|---|---|---|---|
| **Storyteller** | Llama 3.2 3B (1.8 GB), Gemma 4 E2B (3.6 GB download) | **Qwen3.5 4B (2.9 GB, recommended)**, Gemma 4 E4B (5.1 GB download, about 4 GB in memory) | Qwen3.5 9B (5.9 GB, 12 GB phones) |
| **Narrator voice** | Apple's built-in voices (no download) | Kokoro (0.35 GB) | Qwen3-TTS (1.9 GB) |
| **Listening** | Apple dictation (no download) | Parakeet Small (0.45 GB) | Parakeet 0.6B (2.5 GB) |

Small on-device models tell shorter, simpler stories than Gemini Pro, so the prompts here are a lighter version of the web app's.

## How a turn works

The iPhone follows the same flow as the web app's [How the Phonodeck Works](https://github.com/simbonk/phonodeck/blob/main/how-it-works.html) page:

1. **Recall.** Before each reply it searches the lore, older turns and older chapter summaries for what bears on what you just said, and puts the best few into the Game Master's private briefing. Like the web app it merges two rankings: a keyword search (BM25) and a meaning search. The web app's meaning search uses Google's embedding model; the phone uses the English sentence embedding built into iOS, which runs on the CPU with no download and a few megabytes of memory. Lore you name always comes first.
2. **The plan.** The web app's Gemini model thinks before it writes. On the phone the Game Master makes a separate planning call first, using the model's own reasoning mode (Qwen's thinking) when "Game Master reasons first" is on: it reads the bible, the set-up limits, the facts, its look-ahead from last turn, the clock, the roadmap, the feeling reading and the recalled memories, reasons it through, and writes six private lines (what you are doing, the concrete answer to any question, the one beat of this reply, who is in the scene with their pronouns, one memory to bring back, one thing to avoid). With reasoning this can take up to about a minute; without it, a few seconds. Models without a thinking mode fall back to the quick plan.
3. **The Game Master** writes the reply from the rules, the story bible, your hand-set facts, the chapter summaries and the showrunner's notes, plus a briefing that leads with the plan, then the mission map, the memories, the director's notes and the time left. The opening scene gets its own direction (where you are, what you are doing, what you see, hear and smell) and more room than an ordinary reply.
4. **The look-ahead and the memory pass** run while the reply is read aloud, after the voice has made its speech so it never stalls. The memory pass records new people and places, events, where you are, which story steps are done, and how well the feeling is landing. Then the Game Master reviews the reply against the bible, the facts and the limits you set: it keeps a list of facts that must stay true (pronouns, what you have with you, who is present), notes slips to correct from the next reply on, flags a question that wasn't really answered, proposes the next move, and keeps the continuity: the story time, a timeline of what happened when ("Last night: the storm wrecked your boat"), and where each named person is, what they are doing and where they are heading. That continuity check goes last in the briefing and the plan, right before your words, where a small model pays the most attention, along with who may use your name (nobody, until you say it). You can see it under Right now and Timeline in the World panel. The next turn's plan realigns that move to what you actually say. Experiences (no plot) get a gentle arc too, so the time feels like it is going somewhere. The memory pass also runs after the reply: new people and places, events, where you are (and the route you took, for the mission map), which story steps are done, and how well the feeling is landing. Every 6 turns older turns fold into a chapter summary.
5. **Housekeeping**, at most one extra call per turn and only every few turns: the hidden **showrunner's notes** (each character's wants, fears, secret and next move, open threads and a big reveal) are made after turn 2 and revised every 10 turns or after you edit the world by hand, and the **story bible** is rewritten at turns 10, 20, 30 so it stays current. When the notes exist, the director sometimes asks a character to act on their agenda.

**Same cast, new story.** A saved story's menu can start a new story with its cast and world, as a sequel, years later, a fresh start or a prequel. The returning people, places and hand-set facts carry over, and for a sequel or years later, recall also searches the earlier stories' chapters and turns (following the chain back through every sequel), so asking about something from a past story finds it. This is all plain code, with no extra model call.

Not on the phone yet: the photo reader and Gemini's dictation clean-up.

**Memory.** None of this loads anything new. Only one model call runs at a time, and every prompt (the plan, the Game Master's, the memory pass, the notes, the bible, and the Chat tab) is checked against the 4,096-token conversation size the fit check below budgets for. If a prompt would go over, the oldest turns are dropped first (recall can still find them), so the extra steps never raise peak memory above a normal turn.

## How it decides whether a model fits

iOS lets each app use only part of the phone's memory. The app asks iOS how much it may use (`os_proc_available_memory`), then adds up what a model needs: its weights, the memory for a 4,000-token conversation (worked out from the model's own `config.json`, counting only the layers that remember the whole conversation), and some working room, plus whatever voice or listening model stays loaded beside it. Gemma 4 and Qwen3.5 ship with image and sound encoders the storyteller never loads, so the app reads the weight files' headers and leaves those out. Under 70% of the budget is **Runs comfortably**, under 92% is **Will run, but tight**, and above that is **Too big for this phone**. It also estimates speed (memory bandwidth divided by model size) so you know whether narration will keep up.

---

## Put it on your iPhone: step by step

You need a Mac, an iPhone or iPad on iOS 26 or later, and a USB cable. You've never built an app before? That's fine; these steps are all of it. The first build takes 10 to 20 minutes because Xcode downloads and compiles the AI libraries.

### 1. Install Xcode (once)

1. On the Mac, open the **App Store**, search for **Xcode**, and install it (it is free and large, about 10 GB). It needs a recent macOS; if the App Store says your Mac is too old, update macOS first in **System Settings > General > Software Update**.
2. Open Xcode once. It may ask to install extra components; say yes. When it asks which platforms you want, make sure **iOS** is ticked.
3. In Xcode's menu choose **Xcode > Settings > Accounts**, press **+**, choose **Apple ID**, and sign in with your normal Apple ID. This is free. (A paid Apple Developer account, $99/year, is only needed to share the app through TestFlight or keep it installed longer than 7 days at a time.)

### 2. Get the code (once)

1. Open the **Terminal** app on the Mac (press Cmd+Space, type Terminal, press Return).
2. Paste this and press Return:
   ```
   git clone https://github.com/simbonk/phonodeck-ios.git ~/phonodeck-ios
   open ~/phonodeck-ios/Phonodeck.xcodeproj
   ```
   If the Mac asks to install "command line developer tools", say yes, then paste the two lines again.

Xcode opens the project and starts fetching packages (you'll see "Resolving Package Graph" at the top). Wait for it to finish.

### 3. Get your iPhone ready (once)

1. Plug the iPhone into the Mac. On the phone, tap **Trust** and enter your passcode.
2. On the iPhone, open **Settings > Privacy & Security > Developer Mode**, turn it on, and let the phone restart. (If you don't see Developer Mode, do step 4 first; it appears after Xcode has seen the phone once.)

### 4. Sign and run

1. In Xcode's left sidebar, click the blue **Phonodeck** project icon at the top, then the **Phonodeck** target, then the **Signing & Capabilities** tab.
2. Tick **Automatically manage signing**, and choose your name under **Team** (it says "Personal Team").
3. If Xcode says the bundle identifier is not available, change **Bundle Identifier** to something unique, such as `com.yourname.phonodeck`.
4. At the top of the window, click the device menu (next to the Phonodeck scheme) and choose **your iPhone**.
5. Press the **Run** button (the ▶ triangle) or Cmd+R.
6. The first time, Xcode asks whether to **Trust & Enable** a package macro ("MLXHuggingFaceMacros"). Choose **Trust & Enable**; it's part of Apple's open-source MLX library and only generates code at build time.
7. The first time it installs, the iPhone may refuse to open the app. On the phone go to **Settings > General > VPN & Device Management**, tap your Apple ID under Developer App, and tap **Trust**. Then open Phonodeck.

### 5. First launch

1. A short welcome explains hands-free play, confirms you are 18 or over (Phonodeck is adults only), and offers the recommended storyteller. On Wi-Fi, tap **Download** (green "Runs comfortably" means it fits).
2. On the same screen, tap **Listen** to hear each narrator voice. Apple's is ready at once; download **Kokoro** (medium) or **Qwen3-TTS** (good, slower) and listen again. Below that, pick how it hears you and tap **Try listening** to test it.
3. On the **Phonodeck** tab, tap **Set up a new experience** and follow the wizard. The first scene takes about a minute while the model loads and designs the world.

### Updating later

When there are new changes, in Terminal run:
```
cd ~/phonodeck-ios && git pull
```
then press Run in Xcode again. Your stories and downloaded models stay on the phone.

### The 7-day limit

With a free Apple ID, apps you install yourself stop opening after 7 days. Just plug the phone in and press Run in Xcode again; nothing is lost. A paid developer account removes this limit (and lets you add the **Increased Memory Limit** capability in Signing & Capabilities, which helps the bigger models; the entitlement is ready in `Config/Phonodeck.entitlements`).

### If something goes wrong

- **"No such module 'MLX…'"** or package errors: **File > Packages > Reset Package Caches**, then build again.
- **Metal toolchain missing** (Xcode 26 and later): in Terminal run `xcodebuild -downloadComponent MetalToolchain`, then build again.
- **"CodeSign failed" with "unable to build chain to self-signed root":** pull the latest code (`git pull`); the app now targets iOS 26, which avoids the extra library whose signing step trips over this.
- **"errSecInternalComponent" on a work or managed Mac:** the login keychain won't let `codesign` use the key. Put the signing certificate in its own keychain (for example `phonodeck-signing.keychain-db`) and, after a restart, unlock it with `security unlock-keychain ~/Library/Keychains/phonodeck-signing.keychain-db`.
- **`git pull` says local changes to project.pbxproj would be overwritten:** run `git checkout -- Phonodeck.xcodeproj`, pull, then pick your Team again in Signing & Capabilities.
- **The app freezes while Xcode is attached, and Xcode shows "failed assertion `bytes argument cannot be nil`":** that is Xcode's Metal checker, not a real fault. The shared scheme turns it off; if your copy still has it on, go to **Product > Scheme > Edit Scheme > Run > Diagnostics** and untick **Metal API Validation**. Press Stop in Xcode and run again.
- **Replies get strange or slow:** in the **Models** tab, under **In memory**, tap **Restart** next to the storyteller (or Unload to free memory).
- **The app closes while loading a model:** the model is too big for the phone's memory; pick a smaller one in the Models tab.
- **Silent narrator:** check the volume. Apple voices sound much better after you download a Premium or Enhanced voice in **Settings > Accessibility > Spoken Content > Voices**.

## Where things live

`Phonodeck/` is the app (Xcode picks up every file in it automatically).

- `LLM/`: the model catalog, Hugging Face downloads and the memory fit check (`DeviceFit.swift`), and running the language model with MLX (`LLMService.swift`).
- `Voice/`: the narrator (Apple, Kokoro, Qwen3-TTS) and listening (Apple dictation or Parakeet), including "make it so".
- `Story/`: the prompts (`Prompts.swift`, tune the storytelling here), curated experiences, the story engine (clock, director, memory, chapters, report card), saving and sharing.
- `Chat/`, `Models/`, `Settings/`: the other tabs, the lock screen and passcodes.
- `.github/workflows/build.yml`: GitHub checks that the app compiles on every push.

Built on [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) and [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift).
