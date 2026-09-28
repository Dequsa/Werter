import AppKit

@MainActor
final class WheelController {
    enum Mode {
        /// Shown under the cursor when the user holds ⌥ while dragging files; dropping on a wedge converts.
        /// Stays up until the drag ends, so ⌥ can be released before dropping.
        case drag
        /// Shown from the menu or "Open With"; clicking a wedge converts.
        case click
    }

    private let model = WheelModel()
    private let panel: WheelPanel
    private var mode: Mode = .click
    private var dragEndTimer: Timer?
    /// Bumped on every present/dismiss so stale delayed dismissals do nothing.
    private var generation = 0

    var isVisible: Bool { panel.isVisible }

    init() {
        let container = WheelContainerView(model: model)
        panel = WheelPanel(content: container)
        container.onChoose = { [weak self] format, urls in self?.convert(urls, to: format) }
        container.onCancel = { [weak self] in self?.dismiss() }
        panel.onResignKey = { [weak self] in
            guard let self, self.mode == .click, self.model.phase == .choosing else { return }
            self.dismiss()
        }
    }

    func present(_ urls: [URL], at point: NSPoint, mode: Mode) {
        generation += 1
        self.mode = mode
        model.load(urls)

        let size = WheelGeometry.canvas
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size)
        }
        panel.setFrameOrigin(origin)

        panel.alphaValue = 0
        if mode == .click {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
        } else {
            panel.orderFrontRegardless()
            watchForDragEnd()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func presentCentered(_ urls: [URL]) {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        present(urls, at: NSPoint(x: frame.midX, y: frame.midY), mode: .click)
    }

    func dismiss() {
        generation += 1
        let token = generation
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.panel.orderOut(nil)
                self.model.load([])
            }
        })
    }

    private func dismiss(after seconds: Double) {
        let token = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.generation == token else { return }
            self.dismiss()
        }
    }

    /// Global mouse-up isn't reliably delivered during another app's drag session, so poll the button state.
    private func watchForDragEnd() {
        dragEndTimer?.invalidate()
        dragEndTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                self.dragEndTimer = nil
                // Give performDragOperation a moment to arrive if they dropped on a wedge.
                if self.model.phase == .choosing { self.dismiss(after: 0.3) }
            }
        }
    }

    private func convert(_ urls: [URL], to format: ImageFormat) {
        guard model.phase == .choosing else { return }
        let sources = urls.filter { ImageFormat.canConvert(from: $0) && ImageFormat(url: $0) != format }
        guard !sources.isEmpty else { return dismiss() }

        generation += 1
        let token = generation
        model.hovered = format
        model.phase = .converting

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Converter.convertAll(sources, to: format) }.value
            guard self.generation == token else { return }
            if result.failures.isEmpty {
                let count = result.outputs.count
                self.model.phase = .done(count == 1 ? "Saved" : "Saved \(count)")
                self.dismiss(after: 0.9)
            } else {
                NSLog("FileConverter: %@", result.failures.joined(separator: "; "))
                self.model.phase = .failed("\(result.failures.count) failed")
                self.dismiss(after: 2.0)
            }
        }
    }
}
