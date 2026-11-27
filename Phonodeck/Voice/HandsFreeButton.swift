import SwiftUI

/// Compact circular microphone button for Hands-free mode, tucked beside the Send button.
/// Off: calm circular mic with a subtle shimmer. On and listening: solid red and pulsing.
/// On but paused (narrator speaking, reply loading): tinted red outline.
struct HandsFreeButton: View {
    let on: Bool
    let listening: Bool
    let toggle: () -> Void

    var body: some View {
        let live = on && listening
        Button(action: toggle) {
            Image(systemName: on ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(live ? .white : on ? Theme.rec : Theme.accent)
                .background(live ? Theme.rec : (on ? Theme.rec.opacity(0.12) : Theme.panel), in: Circle())
                .overlay(Circle().stroke(on ? Theme.rec : Theme.accent.opacity(0.45), lineWidth: on ? 1.5 : 1))
                .modifier(Sheen(active: !on))
                .modifier(Pulse(active: live))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Hands-free microphone ON" : "Hands-free microphone")
        .accessibilityHint("Tap to toggle hands-free listening; say \(Dictation.sendPhrase) to send")
    }
}
