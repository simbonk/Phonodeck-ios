import SwiftUI

/// The first launch, in the web app's order: what Phonodeck is and how to play it,
/// a little about you, then the storyteller download. Shown once.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("playerName") private var playerName = ""
    @AppStorage("playerAge") private var playerAge = 0
    @AppStorage("playerGender") private var playerGender = ""
    @State private var page = 0
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(i <= page ? Theme.accent : Theme.line).frame(height: 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case 0: intro
                    case 1: aboutYou
                    default: storyteller
                    }
                }
                .padding(24)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            HStack {
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }.foregroundStyle(Theme.dim)
                }
                Spacer()
                Button {
                    if page < 2 { withAnimation { page += 1 } } else { onDone() }
                } label: {
                    Text(page < 2 ? "Next" : app.store.hasLanguageModel || app.store.isDownloading ? "Let's go" : "Skip for now")
                        .bold().padding(.horizontal, 18).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.onAccent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 620)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Spacer(); HoloCore(size: 110); Spacer() }.padding(.vertical, 10)
            Text("PHONODECK")
                .font(.system(size: 32, weight: .bold)).tracking(5)
                .foregroundStyle(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.5), radius: 8)
            Text("Interactive stories you play with your voice. Pick a world, or build your own, and a storyteller narrates while you decide what happens.")
                .foregroundStyle(Theme.fg)
            Caps(text: "Before you start").padding(.top, 6)
            tip("speaker.wave.2.fill", "Turn the sound up", "The story is read aloud. If you hear nothing, check that Silent Mode is off.")
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic.fill").foregroundStyle(Theme.rec).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Go hands-free").bold().foregroundStyle(Theme.fg)
                    Text("Tap the hands-free button in a story and just talk. When you're done, say").foregroundStyle(Theme.dim)
                    MagicPhrase(phrase: Dictation.sendPhrase, font: .headline)
                    Text("and your words are sent. You can change the phrase in Settings.").foregroundStyle(Theme.dim)
                }
                .font(.subheadline)
            }
            tip("globe", "Open the World", "The globe in a story shows your mission, the story bible, and every character, place and item it has collected. You can edit any of it.")
            tip("lock.fill", "It stays here", "Everything runs on this \(DeviceFit.deviceWord). Once the storyteller is downloaded, nothing you say leaves it, and it works in Airplane Mode.")
        }
    }

    private var aboutYou: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caps(text: "About you")
            Text("Stories are written around you. These are used for every new experience, can be made up, and can be changed in Settings. Children get gentle, G-rated stories.")
                .font(.subheadline).foregroundStyle(Theme.dim)
            field("Your name in stories") { TextField("e.g. Alex", text: $playerName).textContentType(.givenName) }
            field("Age") {
                Stepper(playerAge == 0 ? "Not set" : "\(playerAge)", value: $playerAge, in: 0...110)
            }
            field("Gender (your own words)") { TextField("optional", text: $playerGender) }
        }
    }

    private var storyteller: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caps(text: "Your storyteller")
            Text("The storyteller is a language model that runs on this \(DeviceFit.deviceWord). This one is picked to fit it. You can try others in the Models tab later.")
                .font(.subheadline).foregroundStyle(Theme.dim)
            StorytellerCard()
            if app.store.hasLanguageModel {
                Text("All set. Tap Let's go, then Set up a new experience.").font(.subheadline).foregroundStyle(Theme.accent)
            }
        }
    }

    private func tip(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).bold().foregroundStyle(Theme.fg)
                Text(text).foregroundStyle(Theme.dim)
            }
            .font(.subheadline)
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Theme.dim)
            c()
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
    }
}
