import SwiftUI
import AppKit

/// Forces the enclosing `NSScrollView` to show a permanent, space-reserving
/// (legacy-style) scrollbar, independent of the system "Show scroll bars"
/// setting.
///
/// SwiftUI's `.scrollIndicators(.visible)` does NOT override the macOS overlay
/// auto-hide when the system setting is "Automatically" / "When scrolling" — the
/// bar still fades out, leaving a thin, awkward grab target. This drops a
/// zero-size probe into the scroll content, walks up to the backing
/// `NSScrollView`, and pins its scroller to always-visible legacy style. Applied
/// (and re-applied on layout) so SwiftUI relayouts can't quietly revert it.
struct AlwaysVisibleScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async { Self.pinLegacyScroller(from: probe) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.pinLegacyScroller(from: nsView) }
    }

    private static func pinLegacyScroller(from view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.scrollerStyle = .legacy          // reserves space + always drawn
        scrollView.autohidesScrollers = false       // never fade out
        scrollView.hasVerticalScroller = true
    }
}
