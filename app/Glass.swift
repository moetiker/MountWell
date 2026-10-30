// Liquid Glass with fallback for macOS 14/15, and the window background.

import SwiftUI

extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        #if SCREENSHOT
        // glass is drawn by the window server and does not show up in an offscreen
        // capture; a light fill stands in for it in docs/screenshot.png
        self.background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        #else
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #endif
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if SCREENSHOT
        // glass buttons are drawn by the window server too and came out nearly invisible
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #else
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #endif
    }
}

// Colored background, stronger in dark mode so the glass stands out
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(dark ? 0.30 : 0.20), Color.purple.opacity(dark ? 0.16 : 0.08), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.cyan.opacity(dark ? 0.14 : 0.10), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
