import SwiftUI

/// The first launch, in the web app's order: what Phonodeck is and how to play it,
/// a little about you, then the storyteller download. Shown once.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("playerName") private var playerName = ""
    @AppStorage("adultConfirmed") private var adult = false
    @State private var page = 0
    @State private var showModels = false
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
                    case 1: adultsOnly
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
                .disabled(page == 1 && !adult)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 620)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showModels) {
            ModelsView()
                .overlay(alignment: .topTrailing) {
                    Button("Done") { showModels = false }.bold().padding(.horizontal, 20).padding(.top, 14)
                }
        }
    }

    /// Sized to fit on one iPhone screen without scrolling.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Spacer(); HoloCore(size: 72); Spacer() }
            Text("PHONODECK")
                .font(.system(size: 28, weight: .bold)).tracking(5)
                .foregroundStyle(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.5), radius: 8)
            Text("Interactive stories you play with your voice. Pick a world or build your own; the storyteller narrates while you decide what happens.")
                .font(.callout).foregroundStyle(Theme.fg)
            Caps(text: "Before you start").padding(.top, 2)
            tip("speaker.wave.2.fill", "Turn the sound up", "Stories are read aloud. Check Silent Mode is off.")
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic.fill").foregroundStyle(Theme.rec).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Go hands-free").bold().foregroundStyle(Theme.fg)
                    FlowLayout(spacing: 5) {
                        Text("Tap Hands-free and talk. Say").foregroundStyle(Theme.dim)
                        MagicPhrase(phrase: Dictation.sendPhrase, font: .subheadline.bold())
                        Text("to send.").foregroundStyle(Theme.dim)
                    }
                }
                .font(.subheadline)
            }
            tip("globe", "Open the World", "The globe shows your mission and every character, place and item. Edit any of it.")
            tip("lock.fill", "It stays here", "Runs on this \(DeviceFit.deviceWord). Nothing you say leaves it, even in Airplane Mode.")
        }
    }

    private var adultsOnly: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caps(text: "For adults")
            Text("Phonodeck is for people 18 and over.")
                .font(.title3.bold()).foregroundStyle(Theme.fg)
            Text("The storyteller is an open model running on this \(DeviceFit.deviceWord), with no content filter in the cloud behind it. It can write mature themes, so it isn't suitable for children.")
                .font(.subheadline).foregroundStyle(Theme.dim)
            Toggle(isOn: $adult) {
                Text("I'm 18 or older").bold().foregroundStyle(Theme.fg)
            }
            .tint(Theme.accent)
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(adult ? Theme.accent : Theme.line))
            field("Your name in stories (optional)") { TextField("Leave blank and each story names you", text: $playerName).textContentType(.givenName) }
        }
    }

    private var storyteller: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The storyteller is a language model that runs on this \(DeviceFit.deviceWord). This one is picked to fit it. Then choose how the story sounds and how it hears you. Everything here can be changed later in the Models tab.")
                .font(.subheadline).foregroundStyle(Theme.dim)
            StorytellerCard(showOthers: { showModels = true })
            NarratorSetup().padding(.top, 10)
            ListeningSetup().padding(.top, 10)
            if app.store.hasLanguageModel {
                Text("All set. Tap Let's go, then Set up a new experience.").font(.subheadline).foregroundStyle(Theme.accent).padding(.top, 6)
            }
        }
    }

    private func tip(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
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
