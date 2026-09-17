import SwiftUI

enum Theme {
    // Shlok palette: warm, bright and a little silly. One colour per idea, not one blue for everything.
    static let ink = Color(red: 0.17, green: 0.10, blue: 0.25)        // deep plum
    static let muted = Color(red: 0.50, green: 0.44, blue: 0.57)
    static let canvas = Color(red: 1.0, green: 0.97, blue: 0.93)      // warm cream
    static let field = Color(red: 0.98, green: 0.93, blue: 0.91)

    static let primary = Color(red: 1.0, green: 0.31, blue: 0.47)     // coral
    static let primaryDeep = Color(red: 0.93, green: 0.20, blue: 0.40)
    static let tangerine = Color(red: 1.0, green: 0.60, blue: 0.24)
    static let sunny = Color(red: 1.0, green: 0.80, blue: 0.20)
    static let grape = Color(red: 0.49, green: 0.30, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.36, blue: 0.66)
    static let sky = Color(red: 0.20, green: 0.68, blue: 1.0)
    static let mint = Color(red: 0.10, green: 0.83, blue: 0.64)

    static let green = Color(red: 0.06, green: 0.73, blue: 0.51)
    static let amber = Color(red: 0.98, green: 0.58, blue: 0.09)
    static let rose = Color(red: 0.93, green: 0.18, blue: 0.33)

    static let gradient = LinearGradient(colors: [primary, tangerine], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let grapeGradient = LinearGradient(colors: [grape, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let skyGradient = LinearGradient(colors: [sky, mint], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let sunnyGradient = LinearGradient(colors: [sunny, tangerine], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.68)

    /// Every login gets a stable pair of colours from its title.
    static func avatarGradient(for text: String) -> LinearGradient {
        let palettes: [[Color]] = [
            [primary, tangerine], [grape, pink], [sky, mint], [sunny, tangerine],
            [pink, Color(red: 1.0, green: 0.55, blue: 0.45)], [mint, Color(red: 0.55, green: 0.88, blue: 0.20)],
            [Color(red: 0.36, green: 0.42, blue: 1.0), sky], [Color(red: 0.75, green: 0.35, blue: 0.98), grape],
        ]
        let seed = text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return LinearGradient(colors: palettes[seed % palettes.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Slowly drifting pastel light behind every screen.
struct AuroraBackground: View {
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.canvas
                blob(Color(red: 1.0, green: 0.78, blue: 0.62), size: geo.size.width * 0.95)   // peach
                    .offset(x: drift ? -geo.size.width * 0.32 : -geo.size.width * 0.12, y: drift ? -geo.size.height * 0.38 : -geo.size.height * 0.30)
                blob(Color(red: 1.0, green: 0.90, blue: 0.50), size: geo.size.width * 0.80)   // lemon
                    .offset(x: drift ? geo.size.width * 0.40 : geo.size.width * 0.24, y: drift ? -geo.size.height * 0.12 : -geo.size.height * 0.02)
                blob(Color(red: 1.0, green: 0.72, blue: 0.86), size: geo.size.width * 0.85)   // bubblegum
                    .offset(x: drift ? -geo.size.width * 0.18 : geo.size.width * 0.04, y: drift ? geo.size.height * 0.30 : geo.size.height * 0.22)
                blob(Color(red: 0.66, green: 0.95, blue: 0.85), size: geo.size.width * 0.75)   // mint
                    .offset(x: drift ? geo.size.width * 0.30 : geo.size.width * 0.38, y: drift ? geo.size.height * 0.46 : geo.size.height * 0.40)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle().fill(color.opacity(0.55)).frame(width: size, height: size).blur(radius: 70)
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Theme.primaryDeep.opacity(0.10), radius: 18, y: 8)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }

    /// Slides and fades in, later rows a little later.
    func staggered(_ index: Int, shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .animation(.spring(response: 0.5, dampingFraction: 0.78).delay(Double(min(index, 14)) * 0.045), value: shown)
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
            .background(tint, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: Theme.primary.opacity(configuration.isPressed ? 0.15 : 0.35), radius: configuration.isPressed ? 4 : 12, y: configuration.isPressed ? 2 : 7)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
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
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct Avatar: View {
    let text: String
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(Theme.avatarGradient(for: text))
            .frame(width: size, height: size)
            .overlay(
                Text(String(text.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.rounded(size * 0.42, .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// The Shlok mascot. `pose` picks one of the illustrations in Shared/Art.xcassets.
struct Mascot: View {
    enum Pose: String {
        case shh = "Mascot", phone = "MascotPhone", key = "MascotKey", magic = "MascotMagic", empty = "MascotEmpty", party = "MascotParty"
    }

    var pose: Pose = .shh
    var size: CGFloat = 120

    var body: some View {
        Image(pose.rawValue)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: Theme.primaryDeep.opacity(0.22), radius: size * 0.12, y: size * 0.08)
    }
}

/// A mascot that gently bobs and tilts, so screens never sit completely still.
struct BouncyMascot: View {
    var pose: Mascot.Pose = .shh
    var size: CGFloat = 120
    @State private var up = false

    var body: some View {
        Mascot(pose: pose, size: size)
            .offset(y: up ? -size * 0.05 : size * 0.03)
            .rotationEffect(.degrees(up ? 3 : -3))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { up = true }
            }
    }
}
