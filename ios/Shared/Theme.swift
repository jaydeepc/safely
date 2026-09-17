import SwiftUI

/// Shhlock's look: calm, precise, light. One blue accent, warm-neutral surfaces, generous whitespace.
enum Theme {
    static let ink = Color(red: 0.06, green: 0.09, blue: 0.16)          // #101828
    static let muted = Color(red: 0.40, green: 0.44, blue: 0.52)        // #667085
    static let faint = Color(red: 0.60, green: 0.64, blue: 0.70)
    static let canvas = Color(red: 0.96, green: 0.97, blue: 0.985)      // #F5F7FB
    static let surface = Color.white
    static let field = Color(red: 0.94, green: 0.95, blue: 0.97)        // #EFF2F7
    static let line = Color(red: 0.90, green: 0.92, blue: 0.95)

    static let primary = Color(red: 0.18, green: 0.42, blue: 1.0)       // #2F6BFF
    static let primaryDeep = Color(red: 0.11, green: 0.31, blue: 0.85)  // #1D4ED8
    static let navy = Color(red: 0.06, green: 0.11, blue: 0.24)         // #0F1B3D
    static let teal = Color(red: 0.05, green: 0.65, blue: 0.64)
    static let green = Color(red: 0.07, green: 0.72, blue: 0.42)        // #12B76A
    static let amber = Color(red: 0.97, green: 0.56, blue: 0.04)        // #F79009
    static let rose = Color(red: 0.90, green: 0.28, blue: 0.30)         // #E5484D

    // kept for call sites; all map onto the restrained palette
    static let mint = teal
    static let grape = Color(red: 0.42, green: 0.36, blue: 0.90)
    static let pink = rose
    static let sky = primary
    static let sunny = amber
    static let tangerine = amber

    static let gradient = LinearGradient(colors: [primary, Color(red: 0.36, green: 0.56, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let navyGradient = LinearGradient(colors: [navy, primaryDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let grapeGradient = gradient
    static let skyGradient = LinearGradient(colors: [teal, Color(red: 0.24, green: 0.80, blue: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let sunnyGradient = LinearGradient(colors: [amber, Color(red: 0.99, green: 0.70, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)

    /// Every login gets a stable, muted colour pair from its title.
    static func avatarGradient(for text: String) -> LinearGradient {
        let palettes: [[Color]] = [
            [primary, Color(red: 0.36, green: 0.56, blue: 1.0)],
            [Color(red: 0.42, green: 0.36, blue: 0.90), Color(red: 0.62, green: 0.56, blue: 0.98)],
            [teal, Color(red: 0.24, green: 0.80, blue: 0.72)],
            [Color(red: 0.87, green: 0.40, blue: 0.34), Color(red: 0.98, green: 0.60, blue: 0.42)],
            [green, Color(red: 0.42, green: 0.84, blue: 0.52)],
            [navy, Color(red: 0.30, green: 0.40, blue: 0.62)],
        ]
        let seed = text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return LinearGradient(colors: palettes[seed % palettes.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Font {
    /// Display text uses the system face with tight tracking; the "rounded" name stays for call sites.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

/// A quiet backdrop: the canvas colour with a faint cool wash at the top.
struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Theme.canvas
            LinearGradient(colors: [Theme.primary.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Theme.navy.opacity(0.04), radius: 10, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }

    /// Fades and lifts in, later rows slightly later. Subtle on purpose.
    func staggered(_ index: Int, shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .animation(.easeOut(duration: 0.35).delay(Double(min(index, 12)) * 0.035), value: shown)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: LinearGradient = Theme.gradient
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rounded(16))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var color: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rounded(16))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct Avatar: View {
    let text: String
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.avatarGradient(for: text))
            .frame(width: size, height: size)
            .overlay(
                Text(String(text.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// The white padlock glyph on the app icon, as an illustration.
struct LockGlyph: View {
    var size: CGFloat = 120
    var body: some View {
        Image("LockGlyph")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: Theme.navy.opacity(0.12), radius: size * 0.1, y: size * 0.06)
    }
}

/// The lock glyph on a deep-blue tile, like the app icon.
struct LockTile: View {
    var size: CGFloat = 96
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Theme.navyGradient)
            .frame(width: size, height: size)
            .overlay(LockGlyph(size: size * 0.62))
            .shadow(color: Theme.navy.opacity(0.25), radius: size * 0.16, y: size * 0.08)
    }
}

/// A small status dot with label.
struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }
}
