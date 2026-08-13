import AppKit
import SwiftUI

/// Frosted backdrop shown behind a translucent terminal.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Applies the window-level settings SwiftUI does not expose.
///
/// A translucent terminal background only reads as translucent if the window
/// itself stops painting an opaque sheet behind it, and that is an `NSWindow`
/// property with no SwiftUI equivalent — hence the trip through AppKit.
struct WindowConfigurator: NSViewRepresentable {
    var isTranslucent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window until it is in the hierarchy.
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = !isTranslucent
        window.backgroundColor = isTranslucent ? .clear : nil
        // Shadows are drawn from the opaque region, so they need recomputing
        // whenever that region changes or a stale outline is left behind.
        window.invalidateShadow()
    }
}
