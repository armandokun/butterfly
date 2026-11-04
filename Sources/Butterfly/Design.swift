import AppKit
import SwiftUI

/// Butterfly's design language: white canvas, ink type, editorial serif titles, puffy white pills,
/// soft squircle cards and a few saturated widget tiles. Used everywhere except the (black) notch.
enum Design {
    static let canvas = Color.white
    static let ink = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)          // #191919
    static let secondary = Color(red: 91 / 255, green: 91 / 255, blue: 91 / 255)    // #5B5B5B
    static let mist = Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)      // #F5F5F5
    static let hairline = ink.opacity(0.07)

    // Widget tile colors
    static let pink = Color(red: 1, green: 0.42, blue: 0.68)       // #FF6BAD
    static let sky = Color(red: 0.31, green: 0.67, blue: 1)        // #4FABFF
    static let orange = Color(red: 1, green: 0.55, blue: 0.24)     // #FF8C3D
    static let slate = Color(red: 0.33, green: 0.38, blue: 0.45)   // #546173
    static let green = Color(red: 0.2, green: 0.75, blue: 0.47)    // #33BF78
    static let violet = Color(red: 0.55, green: 0.47, blue: 0.97)  // #8C78F7
    static let red = Color(red: 0.9, green: 0.27, blue: 0.24)

    static let radius: CGFloat = 24, tileRadius: CGFloat = 22, fieldRadius: CGFloat = 10
    static let gap: CGFloat = 8, pad: CGFloat = 16, section: CGFloat = 28, margin: CGFloat = 28

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .regular) }
    static let body = Font.system(size: 13.5)
    static let caption = Font.system(size: 12)
    static let label = Font.system(size: 11.5, weight: .medium)
}

extension View {
    /// Editorial serif heading: regular weight, -1% tracking.
    func displayText(_ size: CGFloat, color: Color = Design.ink) -> some View {
        font(Design.display(size)).tracking(-size * 0.01).foregroundStyle(color)
    }
    /// Large sans section title, -4% tracking.
    func titleText(_ size: CGFloat) -> some View { font(Design.title(size)).tracking(-size * 0.04).foregroundStyle(Design.ink) }
    /// Secondary gray paragraph.
    func secondaryText(_ font: Font = Design.caption) -> some View {
        self.font(font).tracking(-0.1).lineSpacing(3).foregroundStyle(Design.secondary)
    }
    /// Liquid Glass squircle (optionally tinted). Reduce Transparency falls back to an opaque fill automatically.
    func softCard(_ tint: Color? = nil, radius: CGFloat = Design.radius) -> some View {
        let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
        return glassEffect(glass, in: .rect(cornerRadius: radius))
    }
}

/// Soft colour blobs behind the white canvas so Liquid Glass has something to refract (glass on pure white reads flat).
struct Backdrop: View {
    var body: some View {
        ZStack {
            // See-through: the desktop shows (blurred) behind the window; faint blobs keep the glass reading.
            BehindWindowBlur()
            Color.white.opacity(0.25)
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    blob(Design.pink, 0.14, CGSize(width: w * 0.55, height: w * 0.45)).position(x: w * 0.12, y: h * 0.12)
                    blob(Design.sky, 0.14, CGSize(width: w * 0.6, height: w * 0.5)).position(x: w * 0.92, y: h * 0.35)
                    blob(Design.orange, 0.10, CGSize(width: w * 0.55, height: w * 0.45)).position(x: w * 0.2, y: h * 0.75)
                    blob(Design.violet, 0.10, CGSize(width: w * 0.5, height: w * 0.45)).position(x: w * 0.85, y: h * 0.95)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func blob(_ c: Color, _ o: Double, _ s: CGSize) -> some View {
        Ellipse().fill(c.opacity(o)).frame(width: s.width, height: s.height).blur(radius: 70)
    }
}

/// Translucent window background: blurs whatever is behind the window.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow; v.material = .hudWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Liquid Glass pill: interactive glass capsule; `prominent` is glass tinted ink with white text (or a custom tint).
/// Destructive buttons get red text.
struct PuffyPillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Design.ink
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let glass: Glass = prominent ? .regular.tint(tint).interactive() : .regular.interactive()
        return configuration.label
            .font(.system(size: 12.5, weight: .medium)).tracking(-0.1)
            .labelStyle(PillLabel())
            .foregroundStyle(prominent ? .white : configuration.role == .destructive ? Design.red : Design.ink)
            .padding(.horizontal, 14).frame(height: 30)
            .contentShape(Capsule())
            .glassEffect(glass, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }

    private struct PillLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) { configuration.icon.font(.system(size: 11, weight: .semibold)); configuration.title }
        }
    }
}

extension ButtonStyle where Self == PuffyPillButtonStyle {
    static var puffy: PuffyPillButtonStyle { PuffyPillButtonStyle() }
    static var puffyInk: PuffyPillButtonStyle { PuffyPillButtonStyle(prominent: true) }
}

/// A saturated (or white glassy) squircle: symbol top-left, serif title and caption at the bottom.
struct WidgetTile: View {
    let title: String
    let symbol: String
    var caption: String? = nil
    var tint: Color = Design.sky
    var filled = true
    var size = CGSize(width: 104, height: 84)

    var body: some View {
        let ink: Color = filled ? .white : Design.ink
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(filled ? .white : tint)
            Spacer(minLength: 0)
            Text(title).displayText(15, color: ink).lineLimit(1).minimumScaleFactor(0.8)
            if let caption { Text(caption).font(.system(size: 10.5)).foregroundStyle(ink.opacity(0.7)).lineLimit(1) }
        }
        .padding(12)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .contentShape(.rect(cornerRadius: Design.tileRadius))
        .glassEffect(filled ? .regular.tint(tint.opacity(0.9)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: Design.tileRadius))
    }
}

/// Small gray capsule tag.
struct Tag: View {
    let text: String
    var tint: Color? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(Design.label).foregroundStyle(Design.ink)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassEffect(.regular.tint(tint?.opacity(0.18)), in: .capsule)
    }
}

/// Section: small gray title, a soft white card of rows, optional gray footer.
struct CardSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .medium)).tracking(-0.1).foregroundStyle(Design.secondary).padding(.leading, 4)
            VStack(spacing: 0) { GlassEffectContainer(spacing: 8) { VStack(spacing: 0) { content() } } }.softCard()
            if let footer { Text(footer).secondaryText().padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// One row inside a card: label left, control right, hairline under.
struct CardRow<Trailing: View>: View {
    let title: String
    var last = false
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Design.body).tracking(-0.15).foregroundStyle(Design.ink).lineLimit(1).fixedSize()
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.horizontal, Design.pad).frame(minHeight: 48)
            if !last { Rectangle().fill(Design.hairline).frame(height: 1).padding(.leading, Design.pad) }
        }
    }
}

/// Text field on a light gray rounded fill, no bezel.
struct SoftField: View {
    let prompt: String
    @Binding var text: String
    var secure = false
    var body: some View {
        Group {
            if secure { SecureField("", text: $text, prompt: Text(prompt)) }
            else { TextField("", text: $text, prompt: Text(prompt)) }
        }
        .textFieldStyle(.plain)
        .font(Design.body)
        .foregroundStyle(Design.ink)
        .padding(.horizontal, 14).frame(height: 30)
        .glassEffect(.regular.tint(.white.opacity(0.35)).interactive(), in: .capsule)
    }
}

/// Settings toggle: the native macOS 26 Liquid Glass switch, tinted ink.
struct InkToggle: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Design.ink) }
}

/// Pop-up picker as a glass capsule (native popup, glass button chrome).
extension View {
    func glassPicker() -> some View { pickerStyle(.menu).buttonStyle(.glass).controlSize(.large) }
}
