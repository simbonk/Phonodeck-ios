import SwiftUI

@main
struct PhonodeckApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onOpenURL { app.importFile($0) }
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { app.lock() }
        }
    }
}

/// Everything the screens share.
@Observable
@MainActor
final class AppModel {
    let store: ModelStore
    let llm: LLMService
    let narrator: Narrator
    let dictation: Dictation
    let library: Library
    let engine: StoryEngine
    let vault: Vault
    var tab: Tab = .phonodeck
    var notice: String?
    /// An experience opened from a shared file, shown in the set-up screen.
    var pendingExperience: Experience?

    enum Tab: Hashable { case phonodeck, chat, models, settings }

    init() {
        let store = ModelStore()
        let llm = LLMService(store: store)
        let narrator = Narrator(store: store)
        let dictation = Dictation(store: store)
        let library = Library()
        self.store = store
        self.llm = llm
        self.narrator = narrator
        self.dictation = dictation
        self.library = library
        self.engine = StoryEngine(llm: llm, narrator: narrator, dictation: dictation, library: library)
        self.vault = Vault()
        if let space = vault.unlocked { library.open(space) }
    }

    func unlocked() {
        if let space = vault.unlocked { library.open(space) }
    }

    func lock() {
        engine.close()
        narrator.stop()
        dictation.stop()
        vault.lock()
        if vault.isLocked { library.unload() }   // nothing private stays in memory behind the lock screen
    }

    func importFile(_ url: URL) {
        guard !vault.isLocked else { notice = "Unlock Phonodeck first, then open the file again."; return }
        do {
            let e = try library.importExperience(from: url)
            pendingExperience = e
            tab = .phonodeck
            notice = "Imported \"\(e.title)\"."
        } catch {
            notice = error.localizedDescription
        }
    }
}

/// The web app's look: deep navy, a teal holographic accent, gold for the send phrase.
enum Theme {
    static let bg = Color(hex: 0x0B0F14)
    static let panel = Color(hex: 0x121923)
    static let line = Color(hex: 0x223042)
    static let fg = Color(hex: 0xD7E2EE)
    static let dim = Color(hex: 0x8497AB)
    static let accent = Color(hex: 0x4FD1C5)
    static let you = Color(hex: 0x1D2B3C)
    static let warn = Color(hex: 0xF6C667)
    static let magic = Color(hex: 0xFFD36B)
    static let rec = Color(hex: 0xC0392B)
    static let onAccent = Color(hex: 0x001122)
    static let card = panel
    static let narration = Font.system(.body, design: .serif)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("adultConfirmed") private var adult = false

    var body: some View {
        @Bindable var app = app
        Group {
            if app.vault.isLocked {
                LockView()
            } else {
                TabView(selection: $app.tab) {
                    PhonodeckHome()
                        .tabItem { Label("Phonodeck", systemImage: "waveform") }
                        .tag(AppModel.Tab.phonodeck)
                    ChatView()
                        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                        .tag(AppModel.Tab.chat)
                    ModelsView()
                        .tabItem { Label("Models", systemImage: "arrow.down.circle") }
                        .tag(AppModel.Tab.models)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppModel.Tab.settings)
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { (!onboarded || !adult) && !app.vault.isLocked }, set: { if !$0, adult { onboarded = true } })) {
            WelcomeView { onboarded = true; app.tab = .phonodeck }
        }
        .alert("Phonodeck", isPresented: Binding(get: { app.notice != nil }, set: { if !$0 { app.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.notice ?? "")
        }
    }
}

/// Shown when no storyteller model is ready yet.
struct NeedsModelBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Download a storyteller first")
                .font(.title3.bold())
            Text("Phonodeck runs its language model on your \(DeviceFit.deviceWord), so nothing you say leaves it and it works in Airplane Mode. Pick one in the Models tab; the recommended one is about 2.3 GB.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Models") { app.tab = .models }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }
}
