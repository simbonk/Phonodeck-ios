import SwiftUI

/// Settings > Overnight tests: start a run, watch it go, and share the morning report.
struct TestRunView: View {
    @Environment(AppModel.self) private var app
    @State private var pastReports: [URL] = []

    var body: some View {
        @Bindable var runner = TestRunner.shared
        Form {
            Section {
                DatePicker("Stop at", selection: $runner.stopAt, displayedComponents: [.date, .hourAndMinute])
                Picker("Test suite", selection: $runner.suite) {
                    ForEach(TestRunner.Suite.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                Stepper(value: $runner.turnsPerBlock, in: 5...50, step: 5) {
                    LabeledContent("Turns per room", value: "\(runner.turnsPerBlock)")
                }
                Toggle("Fast prebuilt openings", isOn: $runner.usePrebuilt)
                Toggle("Improvised turns", isOn: $runner.improvise)
                Toggle("Judge each reply", isOn: $runner.judge)
                if runner.isRunning {
                    Button("Stop now", role: .destructive) { runner.stop() }
                } else {
                    Button("Start the tests") { runner.start(app: app) }
                        .disabled(app.store.language == nil)
                }
            } header: {
                Text("Overnight tests")
            } footer: {
                Text("Plays the six sample stories by itself on the active storyteller model, checks the room grid, voice cast, and story state after every turn, and writes a morning report you can share straight back for review. Fast prebuilt openings starts in seconds instead of rebuilding all 6 openings from scratch. Regressions focuses specifically on room transitions, unknown rooms, false door exits, outdoor visits, newcomers, and multi-voice dialogue.")
            }

            if runner.isRunning || runner.turns > 0 {
                Section("Progress") {
                    Text(runner.status)
                    LabeledContent("Rooms played", value: "\(runner.blocks)")
                    LabeledContent("Turns", value: "\(runner.turns)")
                    LabeledContent("Checks passed", value: "\(runner.passed)")
                    LabeledContent("Checks failed", value: "\(runner.failed)")
                    if let r = runner.lastReport {
                        ShareLink(item: r) { Label("Share the report", systemImage: "square.and.arrow.up") }
                    }
                }
                if !runner.recent.isEmpty {
                    Section("Latest failures") {
                        ForEach(Array(runner.recent.prefix(15).enumerated()), id: \.offset) { _, l in
                            Text(l).font(.caption.monospaced())
                        }
                    }
                }
            }

            if !pastReports.isEmpty {
                Section("Earlier runs") {
                    ForEach(pastReports, id: \.self) { url in
                        ShareLink(item: url) { Label(url.deletingLastPathComponent().lastPathComponent, systemImage: "doc.text") }
                    }
                }
            }
        }
        .navigationTitle("Overnight tests")
        .onAppear { loadPast() }
        .onChange(of: TestRunner.shared.isRunning) { _, _ in loadPast() }
    }

    private func loadPast() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: TestRunner.testsFolder, includingPropertiesForKeys: nil)) ?? []
        pastReports = dirs.map { $0.appending(path: "report.md") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path > $1.path }
    }
}
