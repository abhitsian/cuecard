import SwiftUI

enum Theme {
    static let accent = Color(red: 0.97, green: 0.73, blue: 0.32)
    static let youColor = Color(red: 0.40, green: 0.84, blue: 0.78)
    static let themColor = Color(red: 0.93, green: 0.86, blue: 0.74)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.085)
    static let hairline = Color.white.opacity(0.09)
    static let faint = Color.white.opacity(0.45)
    static let dim = Color.white.opacity(0.62)
}

/// "now", "12s", "3m".
func age(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = Theme.dim
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hover ? .white : tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hover ? Color.white.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.dim
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Three bars that rise with the level.
struct LevelMeter: View {
    let level: Float
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3) { i in
                    let threshold = Float(i) * 0.12 + 0.02
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level > threshold ? color : Color.white.opacity(0.15))
                        .frame(width: 2.5, height: CGFloat(5 + i * 3))
                }
            }
            .animation(.easeOut(duration: 0.12), value: level)
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.faint)
        }
        .help(label == "you" ? "Your microphone" : "The other side (the Mac's audio)")
    }
}

struct PulsingDot: View {
    let color: Color
    var pulsing: Bool
    @State private var on = false
    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14).scaleEffect(on ? 1.2 : 0.6).opacity(on ? 0 : 1)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

/// True while `--render` draws the panel to an image. ImageRenderer can't draw scroll views or text fields.
var isRendering = false

/// A ScrollView, except when rendering to an image.
struct Scroll<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if isRendering { VStack(spacing: 0) { content; Spacer(minLength: 0) } } else { ScrollView { content } }
    }
}

/// A plain text field, drawn as text when rendering to an image.
struct PlainField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        if isRendering {
            Text(text.isEmpty ? placeholder : text).foregroundStyle(text.isEmpty ? Theme.faint : .white).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $text).textFieldStyle(.plain)
        }
    }
}
