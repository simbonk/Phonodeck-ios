import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("playerName") private var playerName = ""
    @AppStorage("playerGender") private var playerGender = ""
    @AppStorage("playerInterest") private var playerInterest = ""
    @AppStorage("appleVoice") private var appleVoice = ""
    @AppStorage("speechRate") private var speechRate = 0.5
    @AppStorage("chatSystem") private var chatSystem = ""
    @AppStorage("sendPhrase") private var sendPhrase = ""
    @AppStorage("computerSounds") private var computerSounds = true
    @State private var editingCode: CodeKind?

    enum CodeKind: Identifiable { case secret, demo; var id: Self { self } }

    var body: some View {
        @Bindable var engine = app.engine
        NavigationStack {
            Form {
                Section {
                    TextField("Your name in stories", text: $playerName)
                    TextField("Gender (your own words)", text: $playerGender)
                    TextField("Who you're drawn to (optional)", text: $playerInterest)
                } header: {
                    Text("You in stories (optional)")
                } footer: {
                    Text("All optional and can be made up. Leave the name blank and each story gives you one that fits its world.")
                }

                Section {
                    Toggle("Read replies aloud", isOn: $engine.narrate)
                    Toggle("Game Master plans each reply", isOn: $engine.gmPlans)
                    LabeledContent("Say this to send") {
                        TextField("make it so", text: $sendPhrase)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("Computer sounds", isOn: $computerSounds)
                        .onChange(of: computerSounds) { _, on in if !on { ComputerSounds.shared.stopHum() } }
                } footer: {
                    Text("Game Master plans each reply: before writing, the Game Master reviews the clock, the goal, your feeling and the recalled memories and decides what the reply must do. It adds a few seconds to each turn. Computer sounds: a chirp when the microphone opens, an acknowledging chirp when it hears \"\(Dictation.sendPhrase)\", and a soft hum while the Phonodeck thinks.")
                }

                Section {
                    NavigationLink {
                        AppleVoicePicker(selection: $appleVoice)
                    } label: {
                        LabeledContent("Apple voice", value: appleVoiceName)
                    }
                    if let model = app.store.voiceModel {
                        Picker("\(model.name) voice", selection: Binding(
                            get: { Narrator.neuralVoice(for: model) },
                            set: { Narrator.setNeuralVoice($0, for: model) })) {
                            ForEach(model.voices, id: \.self) { Text(voiceLabel($0)).tag($0) }
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Speaking speed (Apple voices)")
                        Slider(value: $speechRate, in: 0.35...0.6)
                    }
                    Button("Test the narrator") {
                        app.narrator.speak("The rain eases. Somewhere below, a door opens, and a voice you almost recognise calls your name.")
                    }
                } header: {
                    Text("Narrator")
                } footer: {
                    Text("The narrator in use: \(app.store.voiceModel?.name ?? "Apple's built-in voice"). Change it in the Models tab. For a better Apple voice, download a Premium or Enhanced voice in the iPhone's Settings > Accessibility > Spoken Content > Voices.")
                }

                Section {
                    TextField("Instructions for the Chat tab (optional)", text: $chatSystem, axis: .vertical)
                } header: {
                    Text("Chat")
                }

                if app.vault.unlocked == .mine {
                    passcodeSection
                } else {
                    Section {
                        Text("You're in the demo space. It starts empty each time and is wiped when you lock the app.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Everything runs on this iPhone. Once the models are downloaded, Phonodeck works in Airplane Mode, and nothing you say or write leaves the phone.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $editingCode) { kind in
                PasscodeSheet(kind: kind)
            }
        }
    }

    private var passcodeSection: some View {
        @Bindable var vault = app.vault
        return Section {
            Button(vault.hasSecret ? "Change secret passcode" : "Set a passcode") { editingCode = .secret }
            if vault.hasSecret {
                Button(vault.hasDemo ? "Change demo passcode" : "Add a demo passcode") { editingCode = .demo }
                if vault.hasDemo {
                    Button("Remove demo passcode", role: .destructive) { vault.setDemo(nil) }
                }
                if let bio = Vault.biometryName {
                    Toggle("Unlock with \(bio)", isOn: $vault.useFaceID)
                }
                Button("Remove all passcodes", role: .destructive) { vault.setSecret(nil) }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Optional. With a passcode, Phonodeck locks whenever you leave it. Your secret passcode opens your chats and experiences. A demo passcode opens a clean, empty Phonodeck to show people; it never shows yours. Downloaded models are shared, so the demo works right away.")
        }
    }

    private var appleVoiceName: String {
        AVSpeechSynthesisVoice(identifier: appleVoice).map { "\($0.name) (\(Narrator.qualityLabel($0)))" } ?? "Automatic"
    }

    private func voiceLabel(_ v: String) -> String {
        let names: [String: String] = [
            "af_heart": "Heart (US, female)", "af_bella": "Bella (US, female)", "af_nicole": "Nicole (US, female, soft)",
            "af_sarah": "Sarah (US, female)", "am_michael": "Michael (US, male)", "am_adam": "Adam (US, male)",
            "am_fenrir": "Fenrir (US, male, deep)", "bf_emma": "Emma (UK, female)", "bf_isabella": "Isabella (UK, female)",
            "bm_george": "George (UK, male)", "bm_fable": "Fable (UK, male)", "bm_lewis": "Lewis (UK, male)",
        ]
        return names[v] ?? v
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
    let kind: SettingsView.CodeKind
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
                    Text(kind == .secret
                         ? "Opens your own chats and experiences. If you forget it, the only way back in is to delete and reinstall the app."
                         : "Opens an empty demo space to show people. It must be different from your secret passcode.")
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle(kind == .secret ? "Secret passcode" : "Demo passcode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard first.count >= 4 else { problem = "Use at least 4 characters."; return }
                        guard first == second else { problem = "The two passcodes don't match."; return }
                        if kind == .secret {
                            app.vault.setSecret(first)
                        } else if !app.vault.setDemo(first) {
                            problem = "The demo passcode must be different from your secret one."
                            return
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
