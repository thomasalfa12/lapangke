import AppKit
import SwiftUI

/// Palet & bentuk Lapangke (sama dengan situsnya), dengan varian gelap.
enum Brand {
    static let ink = dynamic(light: 0x082E52, dark: 0xEAF3FF)
    static let ink2 = dynamic(light: 0x405B73, dark: 0xB3C6D8)
    static let accent = dynamic(light: 0x0064AF, dark: 0x5AB3FF)
    static let accentBright = dynamic(light: 0x1F8CF0, dark: 0x4FB2FF)
    static let cyan = Color(hex: 0x4FD7F8)
    static let wash = dynamic(light: 0xE4F3FF, dark: 0x10283F)
    static let sky = dynamic(light: 0xDCEAFF, dark: 0x152D47)
    static let peach = dynamic(light: 0xFFE3D7, dark: 0x3A2923)
    static let lime = dynamic(light: 0xE6EDCD, dark: 0x262F1D)
    static let lavender = dynamic(light: 0xEDE9FA, dark: 0x29253D)
    static let stage = dynamic(light: 0x08375F, dark: 0x0B2E4E)
    static let ok = dynamic(light: 0x1A7A50, dark: 0x4CC38A)
    static let warn = dynamic(light: 0xB07612, dark: 0xF0B14A)
    static let bad = dynamic(light: 0xC2412D, dark: 0xFF7A66)
    static let flower = Color(hex: 0xAFEAFA)
    static let limeSticker = Color(hex: 0xDCEDA7)
    static let sparkSoft = Color(hex: 0xD8CFF8)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// Bentuk "flower" Lapangke (viewBox 120×120).
struct FlowerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let segments: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (74, -8, 87, 2, 86, 20), (108, 9, 121, 26, 107, 42), (130, 46, 131, 67, 110, 73),
            (123, 92, 108, 109, 89, 100), (90, 123, 68, 131, 60, 110), (47, 132, 26, 120, 31, 101),
            (10, 111, -3, 94, 11, 76), (-11, 68, -6, 47, 14, 43), (-1, 24, 16, 9, 35, 21), (32, 1, 51, -8, 60, 8),
        ]
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 120 * rect.width, y: rect.minY + y / 120 * rect.height)
        }
        var path = Path()
        path.move(to: p(60, 8))
        for s in segments { path.addCurve(to: p(s.4, s.5), control1: p(s.0, s.1), control2: p(s.2, s.3)) }
        path.closeSubpath()
        return path
    }
}

/// Bintang empat sudut ("spark") Lapangke (viewBox 80×80).
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 80 * rect.width, y: rect.minY + y / 80 * rect.height)
        }
        var path = Path()
        path.move(to: p(40, 0))
        path.addQuadCurve(to: p(80, 40), control: p(44, 36))
        path.addQuadCurve(to: p(40, 80), control: p(44, 44))
        path.addQuadCurve(to: p(0, 40), control: p(36, 44))
        path.addQuadCurve(to: p(40, 0), control: p(36, 36))
        path.closeSubpath()
        return path
    }
}

/// Sudut asimetris khas website: tiga sudut besar, satu sudut kecil.
struct ExpressiveShape: Shape {
    var radius: CGFloat = 22
    var small: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: radius, bottomLeadingRadius: small, bottomTrailingRadius: radius, topTrailingRadius: radius,
            style: .continuous
        ).path(in: rect)
    }
}

/// Tombol kapsul (pill) seperti CTA website, tetap memakai font & interaksi sistem.
struct PillButtonStyle: ButtonStyle {
    var background: Color = Brand.accent
    var foreground: Color = .white
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.85 : 1), in: Capsule())
            .shadow(color: Brand.ink.opacity(0.25), radius: 10, y: 6)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Stiker squircle bersudut tajam satu.
struct Sticker: View {
    let symbol: String
    var background: Color = Brand.accent
    var foreground: Color = .white
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: UnevenRoundedRectangle(
                topLeadingRadius: size * 0.34, bottomLeadingRadius: size * 0.1,
                bottomTrailingRadius: size * 0.34, topTrailingRadius: size * 0.34, style: .continuous
            ))
            .rotationEffect(.degrees(-10))
    }
}

/// Logo Lapangke digambar ulang dengan SwiftUI (sama dengan ikon app), tidak bergantung pada bundle.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x4FD7F8), Color(hex: 0x1F8CF0), Color(hex: 0x0064AF)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            FlowerShape().fill(.white).frame(width: size * 0.66, height: size * 0.66).rotationEffect(.degrees(12))
            SparkShape().fill(Color(hex: 0x0064AF)).frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
