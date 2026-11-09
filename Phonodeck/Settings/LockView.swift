import SwiftUI

struct LockView: View {
    @Environment(AppModel.self) private var app
    @State private var code = ""
    @State private var wrong = false
    @FocusState private var focused: Bool
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable { case parents, support; var id: Self { self } }

    var body: some View {
        ScrollView {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.accent)
            Text("Phonodeck").font(.largeTitle.bold())
            SecureField("Passcode", text: $code)
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .font(.title3)
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 280)
                .focused($focused)
                .onSubmit(tryCode)
            if wrong { Text("That passcode didn't match.").foregroundStyle(.red).font(.footnote) }
            if app.vault.needsPasscodeOnce {
                Text("Enter your passcode once to turn on encryption for your stories and chats.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            Button("Unlock", action: tryCode)
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty)
            if app.vault.useFaceID, let bio = Vault.biometryName {
                Button {
                    Task { if await app.vault.unlockWithFaceID() { app.unlocked() } }
                } label: {
                    Label("Use \(bio)", systemImage: bio == "Touch ID" ? "touchid" : "faceid")
                }
            }
            VStack(spacing: 12) {
                Text("Phonodeck is made for adults 18 and over.")
                    .font(.footnote.weight(.semibold))
                Text("No data on a phone is ever completely private: anyone with your phone's passcode can get to what's on it. Be careful what you save here. Use Phonodeck responsibly: stories are for fun, not for leaning into anything harmful.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("A note for parents and guardians") { sheet = .parents }
                Button("Take a break and find support") { sheet = .support }
            }
            .font(.footnote)
            .padding(.top, 16)
        }
        .padding()
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $sheet) { which in
            NavigationStack {
                Group {
                    switch which {
                    case .parents: ParentNoteView()
                    case .support: SupportView()
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            }
        }
        .onAppear {
            focused = !app.vault.useFaceID
            if app.vault.useFaceID {
                Task { if await app.vault.unlockWithFaceID() { app.unlocked() } }
            }
        }
    }

    private func tryCode() {
        if app.vault.unlock(with: code) {
            code = ""
            wrong = false
            app.unlocked()
        } else {
            wrong = true
            code = ""
        }
    }
}
