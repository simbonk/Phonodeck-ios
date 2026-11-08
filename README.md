# Phonodeck for iPhone

An audio storytelling app that runs entirely on your iPhone. You download a language model once, and from then on it works in Airplane Mode: nothing you say or write leaves the phone.

- **Phonodeck tab:** say how long you have and the feeling you want, pick a curated experience or build your own, and a Game Master builds a world, tells it aloud, keeps an eye on the clock, lands a real ending, and grades the result with a report card. Play by typing, by tapping the microphone, or hands-free (say **"make it so"** to send).
- **Chat tab:** a plain conversation with the same on-device model.
- **Models tab:** download the storyteller, narrator voice and listening models from Hugging Face. Every model shows whether it will run comfortably on *this* phone before you download it. Paste a link to add any other MLX model.
- **Share experiences:** export a set-up as a small `.phonodeck` file and send it to someone; they tap it to import.
- **Optional passcodes:** a secret passcode (or Face ID) opens your own chats and stories; a demo passcode opens an empty Phonodeck to show people.

This is the on-device sibling of the [Phonodeck web app](https://github.com/simbonk/phonodeck), which uses Gemini in the cloud.

## The models

All are free, and all run offline once downloaded.

| Job | Fast | Medium | Good, slower |
|---|---|---|---|
| **Storyteller** | Llama 3.2 3B (1.8 GB) | **Qwen3 4B (2.3 GB, recommended)**, Gemma 4 E4B (3.6 GB) | Qwen3 8B (4.6 GB, 12 GB phones) |
| **Narrator voice** | Apple's built-in voices (no download) | Kokoro (0.35 GB) | Qwen3-TTS (1.9 GB) |
| **Listening** | Apple dictation (no download) | Parakeet Small (0.45 GB) | Parakeet 0.6B (2.5 GB) |

Small on-device models tell shorter, simpler stories than Gemini Pro, so the prompts here are a lighter version of the web app's.

## How it decides whether a model fits

iOS lets each app use only part of the phone's memory. The app asks iOS how much it may use (`os_proc_available_memory`), then adds up what a model needs: its weights, the memory for a 4,000-token conversation (worked out from the model's own `config.json`), and some working room, plus whatever voice or listening model stays loaded beside it. Under 70% of the budget is **Runs comfortably**, under 92% is **Will run, but tight**, and above that is **Too big for this phone**. It also estimates speed (memory bandwidth divided by model size) so you know whether narration will keep up.

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

1. The app opens on the **Models** tab. On Wi-Fi, tap **Download** next to **Qwen3 4B** (green "Runs comfortably" means it fits).
2. Optional: download **Kokoro** for a more natural narrator and **Parakeet Small** for offline listening.
3. Go to the **Phonodeck** tab, pick an experience, and tap **Build my world**. The first scene takes about a minute while the phone loads the model and designs the world.

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
