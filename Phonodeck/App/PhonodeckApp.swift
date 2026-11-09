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
            // Stop GPU work as soon as the app starts to leave the foreground (inactive comes
            // before background), so iOS never sees it submit GPU work from the background.
            AppActivity.shared.set(foreground: phase == .active)
            if phase == .background { app.lock() }
            if phase == .active { app.engine.resumeAfterBackground() }
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
    let chat: ChatEngine
    let vault: Vault
    var tab: Tab = .phonodeck
    /// Which kind of model the Models tab shows.
    var modelsTab: ModelsTab = .thinking
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
        let engine = StoryEngine(llm: llm, narrator: narrator, dictation: dictation, library: library)
        let chat = ChatEngine(llm: llm, narrator: narrator, dictation: dictation, library: library)
        self.engine = engine
        self.chat = chat
        self.vault = Vault()
        if let key = vault.key { library.open(key: key) }
        // The narrator and the microphone are shared: the Chat tab gets them while it is open
        // or talking hands-free, the story gets them otherwise.
        narrator.onFinished = { [weak self] in
            guard let self else { return }
            if self.chat.handsFree || self.chat.reading { self.chat.narrationFinished() } else { self.engine.narrationFinished() }
        }
        dictation.onSend = { [weak self] text in
            guard let self else { return }
            if self.tab == .chat || self.chat.handsFree { self.chat.send(text) } else { self.engine.send(text) }
        }
        ComputerSounds.shared.warm()
        MLXCrashRecorder.install()
        let lastError = MLXCrashRecorder.takeLast()
        // The automatic switch to the processor made Kokoro hang without a sound, so it is undone
        // once; the switch is now only ever turned on by hand.
        if !UserDefaults.standard.bool(forKey: "neuralOnCPUReset1") {
            UserDefaults.standard.set(true, forKey: "neuralOnCPUReset1")
            Narrator.neuralOnCPU = false
        }
        // A neural voice was working when the app last closed. That is often just Xcode stopping
        // the app, so only an actual MLX error message counts as a crash worth mentioning.
        if let id = UserDefaults.standard.string(forKey: "voiceInFlight") {
            UserDefaults.standard.removeObject(forKey: "voiceInFlight")
            let name = ModelCatalog.entry(id)?.name ?? "neural"
            if let lastError {
                notice = "The \(name) voice closed Phonodeck last time. MLX said: \(lastError)"
            }
        } else if let lastError {
            notice = "Phonodeck closed last time because of an MLX error: \(lastError)"
        }
    }

    /// Switches to the Models tab, open at one kind of model.
    func openModels(_ t: ModelsTab) {
        modelsTab = t
        tab = .models
    }

    func unlocked() {
        if let key = vault.key { library.open(key: key) }
    }

    func lock() {
        engine.close()
        chat.close()
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
    /// The opening splash: the holographic core spins up while the app finishes starting.
    @State private var splash = true

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
        .overlay {
            if splash {
                LaunchSplash()
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: .seconds(1.8))
                        withAnimation(.easeOut(duration: 0.6)) { splash = false }
                    }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { !splash && (!onboarded || !adult) && !app.vault.isLocked && app.notice == nil }, set: { if !$0, adult { onboarded = true } })) {
            WelcomeView { onboarded = true; app.tab = .phonodeck }
        }
        .alert("Phonodeck", isPresented: Binding(get: { !splash && app.notice != nil }, set: { if !$0 { app.notice = nil } })) {
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
            Text("Download a thinking model first")
                .font(.title3.bold())
            Text("Phonodeck runs its language model on your \(DeviceFit.deviceWord), so nothing you say leaves it and it works in Airplane Mode. Pick one in Models > Thinking; the recommended one is about \(String(format: "%.1f", ModelCatalog.entry(ModelCatalog.recommendedLanguageID)?.approxGB ?? 3)) GB.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Models") { app.openModels(.thinking) }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }
}
