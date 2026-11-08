import SwiftUI

/// The holographic core from the web app: two counter-rotating dashed rings, an orbiting spark
/// and a pulsing heart. Shown while the Phonodeck thinks and, large, while a world is built.
struct HoloCore: View {
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * (reduceMotion ? 0.25 : 1)
            Canvas { g, sz in
                let s = min(sz.width, sz.height) / 40
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                func ring(_ r: CGFloat, _ dash: [CGFloat], _ angle: Double, _ opacity: Double) {
                    var p = Path()
                    p.addArc(center: c, radius: r * s, startAngle: .radians(angle), endAngle: .radians(angle + 2 * .pi), clockwise: false)
                    g.stroke(p, with: .color(Theme.accent.opacity(opacity)),
                             style: StrokeStyle(lineWidth: 1.5 * s, lineCap: .round, dash: dash.map { $0 * s }))
                }
                ring(17, [22, 6, 3, 6], t / 3.2 * 2 * .pi, 1)
                ring(11.5, [12, 4], -t / 2.1 * 2 * .pi, 0.65)
                let a = t / 1.4 * 2 * .pi - .pi / 2
                let spark = CGPoint(x: c.x + cos(a) * 17 * s, y: c.y + sin(a) * 17 * s)
                g.fill(Path(ellipseIn: CGRect(x: spark.x - 1.8 * s, y: spark.y - 1.8 * s, width: 3.6 * s, height: 3.6 * s)), with: .color(Theme.accent))
                let beat = 0.5 + 0.5 * sin(t / 1.6 * 2 * .pi)
                let r = 4.5 * s * (0.7 + 0.45 * beat)
                g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Theme.accent.opacity(0.55 + 0.45 * beat)))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.7), radius: max(3, size / 12))
        .shadow(color: Theme.accent.opacity(0.3), radius: max(6, size / 4))
        .accessibilityHidden(true)
    }
}

/// Text that condenses out of a blur of light, as names and stages do on the web app's build screen.
struct Materialize: View {
    let text: String
    var font: Font = .body
    var color: Color = Theme.fg
    @State private var shown = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .blur(radius: shown ? 0 : 6)
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 1.06)
            .shadow(color: Theme.accent.opacity(shown ? 0 : 0.9), radius: 10)
            .onAppear { reveal() }
            .onChange(of: text) { _, _ in
                shown = false
                reveal()
            }
    }

    private func reveal() {
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.8)) { shown = true } }
    }
}

/// The send phrase: every letter glows gold and bobs in a wave, so nobody misses it.
struct MagicPhrase: View {
    let phrase: String
    var font: Font = .callout

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                ForEach(Array(phrase.enumerated()), id: \.offset) { i, ch in
                    let wave = sin((t - Double(i) * 0.08) / 1.4 * 2 * .pi)
                    Text(String(ch))
                        .font(font.bold())
                        .foregroundStyle(Theme.magic)
                        .offset(y: -2.5 - 2.5 * wave)
                        .shadow(color: Theme.magic.opacity(0.45 + 0.45 * wave), radius: 3 + 5 * (wave + 1) / 2)
                }
            }
        }
        .accessibilityLabel(phrase)
    }
}

/// A light that sweeps across a control until it is used (the Hands-free button).
struct Sheen: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                TimelineView(.animation) { ctx in
                    let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Theme.accent.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: (min(p / 0.6, 1) * 1.6 - 0.6) * geo.size.width)
                    }
                }
                .allowsHitTesting(false)
                .clipShape(Capsule())
            }
        }
    }
}

/// A slow pulse (the red Hands-free button while it listens).
struct Pulse: ViewModifier {
    var active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                content.opacity(0.78 + 0.22 * cos(t * 2 * .pi))
            }
        } else {
            content
        }
    }
}

/// The shimmering progress bar of the build screen.
struct ShimmerBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                TimelineView(.animation) { ctx in
                    let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Capsule()
                        .fill(LinearGradient(
                            stops: [.init(color: Theme.accent.opacity(0.4), location: 0),
                                    .init(color: Theme.accent, location: max(0.01, p - 0.15)),
                                    .init(color: Color(hex: 0xE8FFFC), location: p),
                                    .init(color: Theme.accent, location: min(0.99, p + 0.15)),
                                    .init(color: Theme.accent.opacity(0.6), location: 1)],
                            startPoint: .leading, endPoint: .trailing))
                        .shadow(color: Theme.accent, radius: 6)
                }
                .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                .animation(.easeOut(duration: 1.2), value: fraction)
            }
        }
        .frame(height: 4)
    }
}

/// The big card buttons of the web app's start screen and wizard.
struct BigCard<Label: View>: View {
    var primary = false
    var glow = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .foregroundStyle(primary ? Theme.onAccent : Theme.fg)
                .background(primary ? Theme.accent : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(glow || primary ? Theme.accent : Theme.line, lineWidth: glow ? 2 : 1))
                .shadow(color: glow ? Theme.accent.opacity(0.35) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
    }
}

/// A selectable option chip.
struct Chip: View {
    let text: String
    var selected = false
    var suggested = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Theme.onAccent : Theme.fg)
                .background(selected ? Theme.accent : Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.accent : Theme.line, style: StrokeStyle(lineWidth: 1, dash: suggested && !selected ? [4, 3] : [])))
        }
        .buttonStyle(.plain)
    }
}

/// Lays chips out in rows that wrap.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, s.height)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// A small spaced-capitals label, like the web app's section headings.
struct Caps: View {
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text.uppercased()).font(.caption.bold()).tracking(1.2).foregroundStyle(color)
    }
}
