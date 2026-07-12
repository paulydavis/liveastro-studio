import SwiftUI
import AppKit
import LiveAstroCore

/// Overlay metrics, expressed at the 1080p reference height and scaled
/// to the actual window height so OBS captures stay proportionate.
private enum BroadcastLayout {
    static let referenceHeight: CGFloat = 1080
    static let titleSize: CGFloat = 54
    static let captionSize: CGFloat = 34
    static let equipmentSize: CGFloat = 24
    static let elapsedSize: CGFloat = 28
    static let safePadding: CGFloat = 64
    static let shadowRadius: CGFloat = 6
    static let shadowOpacity: Double = 0.8
}

/// The OBS-captured scene: dark, non-interactive, never blanks (spec §5.6).
struct BroadcastView: View {
    @Environment(AppModel.self) private var model
    var configuresWindow: Bool = true

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    // Gesture start snapshots — so we accumulate from drag/pinch start, not
    // compound every onChanged delta.
    @GestureState private var dragStartOffset: CGSize? = nil
    @GestureState private var magnifyStartScale: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            @Bindable var model = model
            let uiScale = geo.size.height / BroadcastLayout.referenceHeight
            let fitted = fittedContentSize(
                imageSize: model.latestImage.map { CGSize(width: $0.width, height: $0.height) },
                in: geo.size)
            ZStack {
                Color.black
                if let cg = model.latestImage {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .scaleEffect(model.zoomPan.scale, anchor: .center)
                        .offset(model.zoomPan.offset)
                        .gesture(dragGesture(view: geo.size, fitted: fitted, model: model))
                        .gesture(magnifyGesture(view: geo.size, fitted: fitted, model: model))
                        .overlay(
                            ScrollWheelZoom(viewSize: geo.size, fittedSize: fitted, model: model)
                        )
                        .clipped()
                }
                overlay(scale: uiScale)
                controlsOverlay(model: $model, view: geo.size, fitted: fitted)
            }
            .ignoresSafeArea()
            .background(configuresWindow ? AnyView(BroadcastWindowConfigurator()) : AnyView(EmptyView()))
        }
        .onAppear { showControlsThenScheduleHide() }
        .onDisappear { hideTask?.cancel() }
    }

    // MARK: - Fitted content size

    /// Letterboxed size the image occupies at scale 1 under scaledToFit.
    private func fittedContentSize(imageSize: CGSize?, in view: CGSize) -> CGSize {
        guard let img = imageSize, img.width > 0, img.height > 0,
              view.width > 0, view.height > 0 else { return view }
        let s = min(view.width / img.width, view.height / img.height)
        return CGSize(width: img.width * s, height: img.height * s)
    }

    // MARK: - Drag gesture

    private func dragGesture(view: CGSize, fitted: CGSize, model: AppModel) -> some Gesture {
        DragGesture()
            // Capture the offset at drag start so we don't compound every delta.
            .updating($dragStartOffset) { _, startSnapshot, _ in
                if startSnapshot == nil { startSnapshot = model.zoomPan.offset }
            }
            .onChanged { g in
                let base = dragStartOffset ?? model.zoomPan.offset
                let proposed = CGSize(width: base.width + g.translation.width,
                                      height: base.height + g.translation.height)
                model.zoomPan.offset = ZoomPanState.clampedOffset(
                    proposed, scale: model.zoomPan.scale,
                    viewSize: view, fittedContentSize: fitted)
            }
    }

    // MARK: - Magnify gesture

    private func magnifyGesture(view: CGSize, fitted: CGSize, model: AppModel) -> some Gesture {
        MagnificationGesture()
            // Snapshot the scale at pinch start so multiplying stays relative to start.
            .updating($magnifyStartScale) { _, startSnapshot, _ in
                if startSnapshot == nil { startSnapshot = model.zoomPan.scale }
            }
            .onChanged { value in
                let base = magnifyStartScale ?? model.zoomPan.scale
                model.zoomPan.scale = ZoomPanState.clampScale(base * value)
                model.zoomPan.offset = ZoomPanState.clampedOffset(
                    model.zoomPan.offset, scale: model.zoomPan.scale,
                    viewSize: view, fittedContentSize: fitted)
            }
    }

    // MARK: - Controls overlay

    @ViewBuilder
    private func controlsOverlay(model: Bindable<AppModel>, view: CGSize, fitted: CGSize) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button("Fit") { model.wrappedValue.zoomPan = .fit }
                Slider(value: Binding(
                    get: { model.wrappedValue.zoomPan.scale },
                    set: { s in
                        model.wrappedValue.zoomPan.scale = ZoomPanState.clampScale(s)
                        model.wrappedValue.zoomPan.offset = ZoomPanState.clampedOffset(
                            model.wrappedValue.zoomPan.offset,
                            scale: model.wrappedValue.zoomPan.scale,
                            viewSize: view, fittedContentSize: fitted)
                    }), in: 1...ZoomPanState.maxScale)
                    .frame(width: 180)
                Button("100%") {
                    if let img = model.wrappedValue.latestImage, fitted.width > 0 {
                        model.wrappedValue.zoomPan.scale = ZoomPanState.clampScale(
                            CGFloat(img.width) / fitted.width)
                        model.wrappedValue.zoomPan.offset = ZoomPanState.clampedOffset(
                            model.wrappedValue.zoomPan.offset,
                            scale: model.wrappedValue.zoomPan.scale,
                            viewSize: view, fittedContentSize: fitted)
                    }
                }
            }
            .padding(8)
            .background(.black.opacity(0.55), in: .capsule)
            .padding(.bottom, 24)
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: controlsVisible)
        }
        .onContinuousHover { _ in showControlsThenScheduleHide() }
    }

    // MARK: - Auto-hide logic

    private func showControlsThenScheduleHide() {
        controlsVisible = true
        guard configuresWindow else { return }   // embedded view: never auto-hide
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { controlsVisible = false }
        }
    }

    // MARK: - Text overlay (must stay outside image transform)

    private func overlay(scale: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.targetName.isEmpty ? "LiveAstro" : model.targetName)
                        .font(.system(size: BroadcastLayout.titleSize * scale, weight: .bold, design: .rounded))
                    Text(model.integrationCaption)
                        .font(.system(size: BroadcastLayout.captionSize * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(equipmentLine)
                        .font(.system(size: BroadcastLayout.equipmentSize * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsedLine)
                        .font(.system(size: BroadcastLayout.elapsedSize * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(BroadcastLayout.safePadding * scale)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(BroadcastLayout.shadowOpacity),
                radius: BroadcastLayout.shadowRadius * scale)
    }

    private var equipmentLine: String {
        var parts = [model.telescope, model.camera].filter { !$0.isEmpty }
        if !model.locationLabel.isEmpty {
            let bortle = model.bortleText.isEmpty ? "" : " · Bortle \(model.bortleText)"
            parts.append(model.locationLabel + bortle)
        }
        return parts.joined(separator: "  ·  ")
    }

    private var elapsedLine: String {
        guard let start = model.sessionStart else { return "" }
        let ref = model.sessionEnd ?? Date()
        let s = Int(ref.timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Scroll-wheel zoom (NSViewRepresentable)

/// Installs an NSEvent local monitor for .scrollWheel events scoped to
/// the image area. Adjusts model.zoomPan.scale by the wheel delta and
/// re-clamps the offset. Removes the monitor on disappear to avoid leaks.
private struct ScrollWheelZoom: NSViewRepresentable {
    let viewSize: CGSize
    let fittedSize: CGSize
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        context.coordinator.nsView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.viewSize = viewSize
        context.coordinator.fittedSize = fittedSize
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewSize: viewSize, fittedSize: fittedSize, model: model)
    }

    final class Coordinator: NSObject {
        var viewSize: CGSize
        var fittedSize: CGSize
        var model: AppModel
        weak var nsView: NSView?
        private var monitor: Any?

        init(viewSize: CGSize, fittedSize: CGSize, model: AppModel) {
            self.viewSize = viewSize
            self.fittedSize = fittedSize
            self.model = model
            super.init()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Only zoom when the scroll happens over THIS view, in its own
                // window — otherwise scrolling any other window (e.g. the Setup
                // form sharing the main window) would zoom the broadcast image.
                guard let self, let view = self.nsView, let win = view.window,
                      event.window === win else { return event }
                let ptInView = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(ptInView) else { return event }
                // scrollingDeltaY: positive = scroll up = zoom in
                let delta = event.scrollingDeltaY
                guard abs(delta) > 0 else { return event }
                let factor = 1.0 + delta * 0.02
                let viewSize = self.viewSize
                let fittedSize = self.fittedSize
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.model.zoomPan.scale = ZoomPanState.clampScale(self.model.zoomPan.scale * factor)
                    self.model.zoomPan.offset = ZoomPanState.clampedOffset(
                        self.model.zoomPan.offset,
                        scale: self.model.zoomPan.scale,
                        viewSize: viewSize,
                        fittedContentSize: fittedSize)
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Gives the hidden-titlebar broadcast window a real window-server title so
/// OBS/ScreenCaptureKit list it, while keeping the chrome invisible.
/// Not unit-testable: needs a live window server — validated visually via
/// OBS window capture.
struct BroadcastWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = "LiveAstro Broadcast"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            if !window.styleMask.contains(.titled) {
                window.styleMask.insert(.titled)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
