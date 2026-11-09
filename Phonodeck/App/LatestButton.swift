import SwiftUI

/// The floating "Latest" pill shown once you scroll up to read: centred above the reply box,
/// on a blurred background with a soft shadow, so it reads as a control rather than a message.
struct LatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Latest", systemImage: "arrow.down")
                .font(.footnote.bold())
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityLabel("Jump to the latest")
    }
}
