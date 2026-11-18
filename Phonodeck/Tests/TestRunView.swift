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
                Stepper(value: $runner.turnsPerBlock, in: 5...60, step: 5) {
                    LabeledContent("Turns per room", value: "\(runner.turnsPerBlock)")
                }
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
                Text("Plays the six sample stories by itself on the Thinking model, checks the world after every turn and writes a report. Each room starts fresh from its story's opening and plays \(runner.turnsPerBlock) turns before the next one. Leave Phonodeck open and plugged in; nothing is spoken aloud and the test stories are deleted as it goes. Improvised turns: a simulated player makes up some turns between the scripted ones. Judge: one extra yes/no question per turn on whether the reply answered you.")
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
