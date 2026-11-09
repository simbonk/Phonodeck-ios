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
    @State private var editingCode: CodeKind?

    enum CodeKind: Identifiable { case secret, demo; var id: Self { self } }

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

                if app.vault.unlocked == .mine {
                    passcodeSection
                } else {
                    Section {
                        Text("You're in the demo space. It starts empty each time and is wiped when you lock the app.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Everything runs on this \(DeviceFit.deviceWord). Once the models are downloaded, Phonodeck works in Airplane Mode, and nothing you say or write leaves it.")
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

    /// A labelled profile field: the label on the left, what you typed on the right.
    private func profileRow(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.fg)
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
