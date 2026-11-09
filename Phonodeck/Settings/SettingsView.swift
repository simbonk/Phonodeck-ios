import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("playerName") private var playerName = ""
    @AppStorage("playerGender") private var playerGender = ""
    @AppStorage("playerInterest") private var playerInterest = ""
    @AppStorage("sendPhrase") private var sendPhrase = ""
    @AppStorage("computerSounds") private var computerSounds = true
    @AppStorage(Reading.textSizeKey) private var textSize: Double = Reading.defaultTextSize
    @State private var editingCode = false


    var body: some View {
        @Bindable var engine = app.engine
        NavigationStack {
            Form {
                Section {
                    profileRow("Name", "Given by each story", $playerName)
                    profileRow("Gender", "Your own words", $playerGender)
                    profileRow("Attracted to", "Anyone", $playerInterest)
                } header: {
                    Text("You in stories (optional)")
                } footer: {
                    Text("All optional and can be made up. Leave the name blank and each story gives you one that fits its world. Gender shapes how characters see and address you; Attracted to tells the story who your romantic interests might be.")
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
                    LabeledContent("Say this to send") {
                        TextField("make it so", text: $sendPhrase)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("Computer sounds", isOn: $computerSounds)
                        .onChange(of: computerSounds) { _, on in if !on { ComputerSounds.shared.stopHum() } }
                } header: {
                    Text("Hands-free")
                } footer: {
                    Text("Computer sounds: a chirp when the microphone opens, another when it hears \"\(Dictation.sendPhrase)\", and a soft hum while the Phonodeck thinks.")
                }

                Section {
                    Toggle("Plans each reply", isOn: $engine.gmPlans)
                    Toggle("Reasons first (slower)", isOn: $engine.deepThinking)
                        .disabled(!engine.gmPlans)
                } header: {
                    Text("Game Master")
                } footer: {
                    Text("Plans each reply: before writing, the Game Master reviews the clock, the goal, your feeling and what it remembers, and decides what the reply must do. While a reply is read aloud it checks it for slips and plans the next move. Reasons first: uses the model's thinking mode (Qwen), which can take up to about a minute a turn.")
                }

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

                Section {
                    Text("Everything runs on this \(DeviceFit.deviceWord). Once the models are downloaded, Phonodeck works in Airplane Mode, and nothing you say or write leaves it.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $editingCode) {
                PasscodeSheet()
            }
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
                Text("Use Phonodeck responsibly. Stories are for fun and imagination, not for leaning into anything that harms you or someone else. And remember that no data on a phone is ever completely private: anyone with your phone's passcode has access to what's on it, so be careful what you save.")
            } header: {
                Text("Play responsibly")
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
                Text("That doesn't mean nothing is kept. Stories and chats are saved on the phone, and no data on a phone is ever completely private: anyone who has the phone's passcode has access to what's on it. Phonodeck's own lock keeps stories from casual eyes; it doesn't make what's written in them harmless.")
            } header: {
                Text("What it is")
            }
            Section {
                Text("AI characters can sound real, warm and understanding, but they are made up by a program. They can be wrong, and some models people can download will say things that aren't suitable for young people.")
            } header: {
                Text("What to know about AI")
            }
            Section {
                Text("Ask what they use it for and what they enjoy about it.")
                Text("Explain that an AI isn't a friend or a counsellor, even when it feels like one.")
                Text("Agree together on what's okay to share with any app, and that nothing online or on a device is ever completely private or safe.")
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
