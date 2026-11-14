import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("playerGender") private var playerGender = ""
    @AppStorage("playerInterest") private var playerInterest = ""
    @AppStorage("sendPhrase") private var sendPhrase = ""
    @AppStorage("computerSounds") private var computerSounds = true
    @AppStorage("fullTrace") private var fullTrace = true
    @AppStorage(Reading.textSizeKey) private var textSize: Double = Reading.defaultTextSize
    @State private var editingCode = false
    @State private var tab = SettingsTab.gameplay

    enum SettingsTab: String, CaseIterable, Identifiable {
        case gameplay = "Gameplay", privacy = "Privacy", about = "About"
        var id: Self { self }
    }

    var body: some View {
        @Bindable var engine = app.engine
        NavigationStack {
            Form {
                switch tab {
                case .gameplay: gameplay(engine)
                case .privacy: privacy
                case .about: about
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Settings", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.bg)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $editingCode) {
                PasscodeSheet()
            }
        }
    }

    // MARK: Gameplay: you in stories, reading and hands-free

    @ViewBuilder
    private func gameplay(_ engine: StoryEngine) -> some View {
                Section {
                    profileRow("Gender", "Your own words", $playerGender)
                    profileRow("Attracted to", "Anyone", $playerInterest)
                } header: {
                    Text("You in stories (optional)")
                } footer: {
                    Text("All optional and can be made up. Your name is set inside each story instead: say it to a character, or type it under the globe. Gender shapes how characters see and address you; Attracted to tells the story who your romantic interests might be.")
                }

                Section {
                    Toggle("Read replies aloud", isOn: Binding(get: { engine.narrate }, set: { on in
                        engine.narrate = on
                        if !on { app.chat.stopReading(); app.narrator.stop() }
                    }))
                    Stepper(value: $textSize, in: Reading.minTextSize...Reading.maxTextSize, step: 1) {
                        LabeledContent("Text size", value: "\(Int(textSize)) pt")
                    }
                    Text("The rain eases. Somewhere below, a door opens.")
                        .font(.system(size: textSize, design: .serif))
                        .foregroundStyle(Theme.dim)
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Shared by the Phonodeck and Chat, and also in each one's ••• menu. Tap any reply to hear it again, or to stop the voice.")
                }

                Section {
                    Toggle("Full trace in the export", isOn: $fullTrace)
                } header: {
                    Text("Testing")
                } footer: {
                    Text("\"Copy with prompts\" gives one log of everything, in order and timed: what you said and what the story said in ### blocks, every question to the model, and every step worked out in code. It gets long. Off: the shorter sectioned export.")
                }

                Section {
                    LabeledContent("Say this to send") {
                        TextField("make it so", text: $sendPhrase)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("Sound cues", isOn: $computerSounds)
                        .onChange(of: computerSounds) { _, on in if !on { ComputerSounds.shared.stopHum() } }
                } header: {
                    Text("Hands-free")
                } footer: {
                    Text("Sound cues: a chirp when the microphone opens, another when it hears \"\(Dictation.sendPhrase)\", and a soft hum while the Phonodeck thinks.")
                }

    }

    // MARK: Privacy: the lock, and where to find help

    @ViewBuilder
    private var privacy: some View {
                lockSection

                Section {
                    CrisisLine()
                    NavigationLink("Take a break and find support") { SupportView() }
                    NavigationLink("A note for parents and guardians") { ParentNoteView() }
                } header: {
                    Text("If you're struggling")
                } footer: {
                    Text("Phonodeck's characters are fiction made up by an AI. They aren't a therapist or a friend who can help in a crisis; a real person can.")
                }

    }

    // MARK: About: what Phonodeck is and how it works (to be expanded)

    @ViewBuilder
    private var about: some View {
        Section {
            Text("Phonodeck is interactive stories you play with your voice. You pick a world or build your own, a storyteller narrates, and you decide what happens next.")
        } header: {
            Text("What it is")
        }
        Section {
            Label("A thinking model (a language model) writes the story and the chat replies.", systemImage: "brain")
            Label("Before each reply, short questions pick out only what this moment needs: the room, the person you face, what matters now. The app keeps track of time, places and people.", systemImage: "map")
            Label("A speaking model reads the story aloud, and a listening model hears you in hands-free mode.", systemImage: "waveform")
        } header: {
            Text("How it works")
        }
        Section {
            Text("Everything runs on this \(DeviceFit.deviceWord). Once the models are downloaded, Phonodeck works in Airplane Mode, and nothing you say or write leaves it.")
        } header: {
            Text("Private by design")
        }
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
        }
    }

    /// A labelled profile field: the label on the left, what you typed on the right.
    private func profileRow(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.fg)
        }
    }

    private var lockSection: some View {
        let vault = app.vault
        let bio = Vault.biometryName
        return Section {
            Button(vault.hasPasscode ? "Change passcode" : "Lock Phonodeck with a passcode") { editingCode = true }
            if vault.hasPasscode {
                if let bio {
                    Toggle("Unlock with \(bio)", isOn: Binding(get: { vault.useFaceID }, set: { vault.setFaceID($0) }))
                }
                Button("Remove passcode", role: .destructive) { vault.setPasscode(nil) }
            }
        } header: {
            Text("Privacy lock")
        } footer: {
            Text("Your stories and chats are always encrypted on this \(DeviceFit.deviceWord). Anyone with your phone's passcode can open Phonodeck unless you give it its own lock. With one, Phonodeck locks whenever you leave it, and only your passcode\(bio.map { " or \($0)" } ?? "") can open them. If you forget the passcode, they can't be recovered by anyone.")
        }
    }
}

struct AppleVoicePicker: View {
    @Binding var selection: String
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Button {
                selection = ""
            } label: {
                HStack { Text("Automatic (best installed)"); Spacer(); if selection.isEmpty { Image(systemName: "checkmark") } }
            }
            ForEach(Narrator.appleVoices, id: \.identifier) { v in
                Button {
                    selection = v.identifier
                    Narrator.appleVoiceID = v.identifier
                    let u = AVSpeechUtterance(string: "Hello. I'll be your narrator tonight.")
                    u.voice = v
                    u.rate = Narrator.rate
                    Narrator.configureSession()
                    AVSpeechSynthesizer.shared.speak(u)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(v.name)
                            Text("\(v.language) · \(Narrator.qualityLabel(v))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == v.identifier { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .navigationTitle("Apple voice")
    }
}

extension AVSpeechSynthesizer {
    /// Kept alive for voice previews.
    @MainActor static let shared = AVSpeechSynthesizer()
}

struct PasscodeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New passcode", text: $first)
                    SecureField("Type it again", text: $second)
                } footer: {
                    Text("Locks Phonodeck whenever you leave it. If you forget it, your stories and chats can't be recovered; deleting and reinstalling the app starts fresh.")
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle("Passcode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard first.count >= 4 else { problem = "Use at least 4 characters."; return }
                        guard first == second else { problem = "The two passcodes don't match."; return }
                        app.vault.setPasscode(first)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The 988 Suicide & Crisis Lifeline, reachable from Settings and the lock screen.
struct CrisisLine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Need to talk to someone now? Call or text 988, free and any time, in the US and Canada. Elsewhere, call your local emergency number.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Link(destination: URL(string: "tel:988")!) { Label("Call 988", systemImage: "phone") }
                Link(destination: URL(string: "sms:988")!) { Label("Text 988", systemImage: "message") }
            }
            .font(.callout.weight(.semibold))
        }
    }
}

/// A link that reads as a row in a list of resources.
private struct ResourceLink: View {
    let title: String
    let detail: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Taking a break, and where to find a real person to talk to.
struct SupportView: View {
    var body: some View {
        Form {
            Section {
                Text("Phonodeck is for fun and imagination. Like any good story, it's best enjoyed with breaks. Your stories live only on this phone, so anyone who can unlock it can read them.")
            } header: {
                Text("Enjoy it well")
            }
            Section {
                Text("Stories are best in doses. If you've been playing for a long time, or a story is weighing on you, put the phone down for a while: go outside, get some air and daylight, move around, or message a friend.")
            } header: {
                Text("Take a break")
            }
            Section {
                Text("A friend, someone in your family, your doctor or a counsellor can help in ways an AI can't. Phonodeck's characters are made up by a program, however real they sound.")
                ResourceLink(title: "Find a therapist", detail: "Psychology Today's directory (US and Canada)", url: "https://www.psychologytoday.com/us/therapists")
            } header: {
                Text("Talk to someone")
            }
            Section {
                CrisisLine()
                ResourceLink(title: "988 Suicide & Crisis Lifeline", detail: "United States", url: "https://988lifeline.org")
                ResourceLink(title: "9-8-8 Suicide Crisis Helpline", detail: "Canada", url: "https://988.ca")
                ResourceLink(title: "Find a Helpline", detail: "Free, confidential helplines in other countries", url: "https://findahelpline.com")
            } header: {
                Text("If you're in crisis")
            } footer: {
                Text("If you or someone else is in immediate danger, call your local emergency number (911 in the US and Canada).")
            }
        }
        .navigationTitle("Support")
    }
}

/// For a parent or guardian who finds Phonodeck on a young person's phone.
struct ParentNoteView: View {
    var body: some View {
        Form {
            Section {
                Text("Phonodeck is made for adults 18 and over. If you've found it on a young person's phone, a calm conversation will usually do more good than simply deleting it.")
            }
            Section {
                Text("Phonodeck tells interactive stories using an AI language model that runs entirely on this phone. There's no account, and nothing is sent to a server or the cloud.")
                Text("Stories are saved on the phone, so they're as private as the phone is. Phonodeck's own lock adds a passcode of its own.")
            } header: {
                Text("What it is")
            }
            Section {
                Text("AI characters can feel real, but they're written by a program. They can get things wrong, and some optional models from the internet are made for adults.")
            } header: {
                Text("What to know about AI")
            }
            Section {
                Text("Ask what they use it for and what they enjoy about it.")
                Text("Explain that an AI isn't a friend or a counsellor, even when it feels like one.")
                Text("Agree together on what's okay to share with any app, since nothing on a device is ever completely private.")
                Text("Make sure they know they can come to you, or another adult they trust, if something they read or heard upset them.")
            } header: {
                Text("Talking about it")
            }
            Section {
                ResourceLink(title: "Kids Help Phone", detail: "Canada: call 1-800-668-6868 or text 686868", url: "https://kidshelpphone.ca")
                ResourceLink(title: "988 Suicide & Crisis Lifeline", detail: "United States: call or text 988", url: "https://988lifeline.org")
                ResourceLink(title: "Find a Helpline", detail: "Other countries", url: "https://findahelpline.com")
            } header: {
                Text("Support for young people")
            }
        }
        .navigationTitle("For parents")
    }
}
