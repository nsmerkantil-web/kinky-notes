import SwiftUI

enum NotePalette {
    static let paper = adaptive(0xf7f7f2, 0x20221f)
    static let sidebar = adaptive(0xf0f0ea, 0x272a25)
    static let surface = adaptive(0xebede6, 0x2d322c)
    static let selection = adaptive(0xdce7db, 0x35483a)
    static let accent = adaptive(0x365847, 0xa8c8a8)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

/// Quiet, shared states for compact macOS controls. Native buttons retain keyboard focus.
struct NoteButtonStyle: ButtonStyle {
    var selected = false
    var capsule = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        NoteButtonBody(configuration: configuration, selected: selected, capsule: capsule, enabled: enabled, reduceMotion: reduceMotion)
    }
    private struct NoteButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let capsule: Bool
        let enabled: Bool
        let reduceMotion: Bool
        @State private var hovering = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: capsule ? 20 : 8)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? NotePalette.accent : Color.primary)
                .opacity(enabled ? 1 : 0.45)
                .padding(.horizontal, capsule ? 14 : 10).frame(minHeight: capsule ? 28 : 30)
                .background(configuration.isPressed && enabled ? NotePalette.selection :
                            selected ? NotePalette.selection : hovering && enabled ? NotePalette.surface : .clear,
                            in: shape)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct NoteRowSurface: ViewModifier {
    var selected = false
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(selected ? NotePalette.selection : hovering ? NotePalette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}
