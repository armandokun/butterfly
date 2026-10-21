import SwiftUI

/// Pond design language (butterfly.so/pond): mint paper, flat square color blocks,
/// italic serif display type, mono labels. Used everywhere except the notch.
enum Pond {
    static let paper = Color(red: 239 / 255, green: 255 / 255, blue: 225 / 255)   // #EFFFE1
    static let ink = Color(red: 27 / 255, green: 50 / 255, blue: 45 / 255)        // #1B322D
    static let lime = Color(red: 206 / 255, green: 240 / 255, blue: 88 / 255)     // #CEF058
    static let moss = Color(red: 203 / 255, green: 226 / 255, blue: 91 / 255)     // #CBE25B
    static let lavender = Color(red: 203 / 255, green: 166 / 255, blue: 247 / 255) // #CBA6F7
    static let peach = Color(red: 255 / 255, green: 159 / 255, blue: 103 / 255)   // #FF9F67
    static let teal = Color(red: 148 / 255, green: 226 / 255, blue: 213 / 255)    // #94E2D5
    static let bark = Color(red: 99 / 255, green: 43 / 255, blue: 15 / 255)       // #632B0F
    static let rose = Color(red: 238 / 255, green: 123 / 255, blue: 123 / 255)    // #EE7B7B
    static let plum = Color(red: 63 / 255, green: 29 / 255, blue: 104 / 255)      // #3F1D68
    static let stone = Color(red: 155 / 255, green: 167 / 255, blue: 181 / 255)   // #9BA7B5

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif).italic() }
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 11, weight: .medium, design: .monospaced)
}

/// A flat square chip: "[ Label ]" block of color.
struct PondChip: View {
    let text: String
    var fill: Color = Pond.lime
    var ink: Color = Pond.ink
    var body: some View {
        Text(text)
            .font(Pond.label)
            .foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(fill)
    }
}

/// Section: a mono chip header + a flat panel of rows.
struct PondSection<Content: View>: View {
    let title: String
    var tint: Color = Pond.lime
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PondChip(text: title, fill: tint)
            VStack(spacing: 0) { content() }
                .background(Color.white.opacity(0.55))
                .overlay(Rectangle().stroke(Pond.ink.opacity(0.12), lineWidth: 1))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(Pond.ink.opacity(0.6))
            }
        }
    }
}

/// One row inside a section: label left, control right, hairline under.
struct PondRow<Trailing: View>: View {
    let title: String
    var last = false
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Pond.body).foregroundStyle(Pond.ink)
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { Rectangle().fill(Pond.ink.opacity(0.08)).frame(height: 1) }
        }
    }
}

/// Flat square button: solid color block, mono label.
struct PondButtonStyle: ButtonStyle {
    var fill: Color = Pond.lavender
    var ink: Color = Pond.ink
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Pond.label)
            .foregroundStyle(ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == PondButtonStyle {
    static var pond: PondButtonStyle { PondButtonStyle() }
    static func pond(_ fill: Color, ink: Color = Pond.ink) -> PondButtonStyle { PondButtonStyle(fill: fill, ink: ink) }
}

/// Pond's wordmark: the name set in a 2×2 grid of italic serif on a lime block ("P o / n d").
struct PondWordmark: View {
    let letters: [String]   // 4
    var size: CGFloat = 64
    var body: some View {
        Grid(horizontalSpacing: size * 0.18, verticalSpacing: size * 0.02) {
            GridRow { cell(0); cell(1) }
            GridRow { cell(2); cell(3) }
        }
        .padding(size * 0.22)
        .background(Pond.moss)
    }
    private func cell(_ i: Int) -> some View {
        Text(letters[i]).font(Pond.display(size * 0.5)).foregroundStyle(Pond.ink)
    }
}

/// Plain text field in Pond style: square, hairline border, no bezel.
struct PondField: View {
    let prompt: String
    @Binding var text: String
    var secure = false
    var body: some View {
        Group {
            if secure { SecureField("", text: $text, prompt: Text(prompt)) }
            else { TextField("", text: $text, prompt: Text(prompt)) }
        }
        .textFieldStyle(.plain)
        .font(Pond.body)
        .foregroundStyle(Pond.ink)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Pond.paper)
        .overlay(Rectangle().stroke(Pond.ink.opacity(0.18), lineWidth: 1))
    }
}
