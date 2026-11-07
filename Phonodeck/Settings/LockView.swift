import SwiftUI

struct LockView: View {
    @Environment(AppModel.self) private var app
    @State private var code = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
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
            Spacer()
            Spacer()
        }
        .padding()
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
