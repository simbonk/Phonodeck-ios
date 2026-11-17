import SwiftUI

/// The Hands-free button, shared by the story and the Chat tab.
/// Off: a glowing teal outline with a light sweeping across it, so it stands out until used.
/// On and listening: solid red and pulsing. On but paused (narrator speaking, reply loading): red outline.
struct HandsFreeButton: View {
    let on: Bool
    let listening: Bool
    let toggle: () -> Void

    var body: some View {
        let live = on && listening
        Button(action: toggle) {
            Label(on ? "Hands-free ON" : "Hands-free", systemImage: "headphones")
                .font(.body.bold())
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(live ? .white : on ? Theme.rec : Theme.accent)
                .background(live ? Theme.rec : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(on ? Theme.rec : Theme.accent, lineWidth: 2))
                .shadow(color: on ? .clear : Theme.accent.opacity(0.45), radius: 8)
                .modifier(Sheen(active: !on))
                .modifier(Pulse(active: live))
        }
        .buttonStyle(.plain)
        .accessibilityHint("The microphone stays on; say \(Dictation.sendPhrase) to send")
    }
}
