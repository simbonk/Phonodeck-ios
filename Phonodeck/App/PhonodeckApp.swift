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
        if !store.hasLanguageModel { tab = .models }
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

enum Theme {
    static let accent = Color(red: 0.98, green: 0.69, blue: 0.29)
    static let card = Color.white.opacity(0.06)
    static let narration = Font.system(.body, design: .serif)
}

struct RootView: View {
    @Environment(AppModel.self) private var app

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
            Text("Phonodeck runs its language model on your iPhone, so nothing you say leaves the phone and it works in Airplane Mode. Pick one in the Models tab; the recommended one is about 2.3 GB.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Models") { app.tab = .models }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }
}
