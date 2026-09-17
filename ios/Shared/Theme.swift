import SwiftUI

enum Theme {
    static let ink = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let muted = Color(red: 0.39, green: 0.45, blue: 0.55)
    static let canvas = Color(red: 0.965, green: 0.969, blue: 0.992)
    static let indigo = Color(red: 0.39, green: 0.40, blue: 0.95)
    static let indigoDeep = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let mint = Color(red: 0.18, green: 0.83, blue: 0.75)
    static let green = Color(red: 0.13, green: 0.77, blue: 0.37)
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let rose = Color(red: 0.94, green: 0.27, blue: 0.35)
    static let field = Color(red: 0.93, green: 0.945, blue: 0.975)

    static let gradient = LinearGradient(colors: [indigo, mint], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.72)

    /// Every login gets a stable pair of colours from its title.
    static func avatarGradient(for text: String) -> LinearGradient {
        let palettes: [[Color]] = [
            [indigo, mint],
            [Color(red: 0.98, green: 0.45, blue: 0.52), Color(red: 0.99, green: 0.73, blue: 0.35)],
            [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.93, green: 0.47, blue: 0.86)],
            [Color(red: 0.05, green: 0.65, blue: 0.91), Color(red: 0.39, green: 0.87, blue: 0.80)],
            [Color(red: 0.13, green: 0.77, blue: 0.55), Color(red: 0.64, green: 0.90, blue: 0.21)],
            [Color(red: 0.96, green: 0.35, blue: 0.62), Color(red: 0.55, green: 0.36, blue: 0.96)],
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
                blob(Color(red: 0.78, green: 0.82, blue: 1.0), size: geo.size.width * 0.95)
                    .offset(x: drift ? -geo.size.width * 0.30 : -geo.size.width * 0.12, y: drift ? -geo.size.height * 0.36 : -geo.size.height * 0.30)
                blob(Color(red: 0.65, green: 0.95, blue: 0.84), size: geo.size.width * 0.85)
                    .offset(x: drift ? geo.size.width * 0.38 : geo.size.width * 0.24, y: drift ? -geo.size.height * 0.05 : geo.size.height * 0.06)
                blob(Color(red: 0.99, green: 0.81, blue: 0.91), size: geo.size.width * 0.80)
                    .offset(x: drift ? -geo.size.width * 0.10 : geo.size.width * 0.06, y: drift ? geo.size.height * 0.42 : geo.size.height * 0.36)
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
            .shadow(color: Theme.indigoDeep.opacity(0.09), radius: 18, y: 8)
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
    var tint: LinearGradient = LinearGradient(colors: [Theme.indigo, Theme.indigoDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rounded(16))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(tint, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: Theme.indigo.opacity(configuration.isPressed ? 0.15 : 0.35), radius: configuration.isPressed ? 4 : 12, y: configuration.isPressed ? 2 : 7)
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

/// The Safely shield, drawn so it can animate.
struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w, y: h * 0.153))
        path.addLine(to: CGPoint(x: w, y: h * 0.474))
        path.addCurve(to: CGPoint(x: w * 0.5, y: h), control1: CGPoint(x: w, y: h * 0.716), control2: CGPoint(x: w * 0.793, y: h * 0.926))
        path.addCurve(to: CGPoint(x: 0, y: h * 0.474), control1: CGPoint(x: w * 0.207, y: h * 0.926), control2: CGPoint(x: 0, y: h * 0.716))
        path.addLine(to: CGPoint(x: 0, y: h * 0.153))
        path.closeSubpath()
        return path
    }
}

struct ShieldMark: View {
    var size: CGFloat = 64
    var locked = true

    var body: some View {
        ZStack {
            ShieldShape()
                .fill(Theme.gradient)
                .frame(width: size * 0.79, height: size)
                .shadow(color: Theme.indigo.opacity(0.35), radius: size * 0.2, y: size * 0.1)
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .offset(y: -size * 0.03)
        }
    }
}
