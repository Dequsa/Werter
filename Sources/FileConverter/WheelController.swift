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

    enum JobStatus {
        case idle
        case running(Double)
        /// `failure` is the first error message, if any file failed.
        case finished(failure: String?)
    }

    /// How long the wheel shows progress before getting out of the way (the menu bar takes over).
    private static let backgroundAfter = 1.5

    private let model = WheelModel()
    private let panel: WheelPanel
    private var mode: Mode = .click
    private var dragEndTimer: Timer?
    /// Bumped on every present/dismiss so stale delayed dismissals and job updates leave the wheel alone.
    private var generation = 0
    private var jobs: [UUID: (task: Task<Void, Never>, progress: Double)] = [:]

    var isVisible: Bool { panel.isVisible }
    var hasRunningJobs: Bool { !jobs.isEmpty }
    var onJobStatusChanged: ((JobStatus) -> Void)?

    init() {
        let container = WheelContainerView(model: model)
        panel = WheelPanel(content: container)
        container.onChoose = { [weak self] format, urls in self?.convert(urls, to: format) }
        container.onCancel = { [weak self] in self?.dismiss() }
        container.onShiftPressed = { [weak self] in
            guard let self, self.mode == .click else { return }
            self.model.switchMode(to: self.model.mode == .convert ? .actions : .convert)
        }
        panel.onResignKey = { [weak self] in
            guard let self, self.mode == .click, self.model.phase == .choosing else { return }
            self.dismiss()
        }
    }

    func present(_ urls: [URL], at point: NSPoint, mode: Mode, wheel: WheelMode = .convert) {
        generation += 1
        self.mode = mode
        model.load(urls, mode: wheel)
        TickSound.shared.prepare()

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
                TickSound.shared.stop()
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
                // ⇧ pressed mid-drag switches to actions and stays there, so letting go of the
                // keys before dropping can't land the file on a different wheel.
                if NSEvent.modifierFlags.contains(.shift) { self.model.switchMode(to: .actions) }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                self.dragEndTimer = nil
                // Give performDragOperation a moment to arrive if they dropped on a wedge.
                if self.model.phase == .choosing { self.dismiss(after: 0.3) }
            }
        }
    }

    func cancelAllJobs() {
        jobs.values.forEach { $0.task.cancel() }
    }

    private func convert(_ urls: [URL], to format: WheelOption) {
        guard model.phase == .choosing else { return }
        let sources = urls.filter { MediaKind(url: $0) == format.kind && WheelOption.current(of: $0) != format }
        guard !sources.isEmpty else { return dismiss() }

        generation += 1
        let token = generation
        let id = UUID()
        model.hovered = format
        model.phase = .converting
        model.progress = 0

        let task = Task { @MainActor [weak self] in
            // `run` is nonisolated, so the work happens off the main thread; cancelling this task cancels it.
            let result = await Converter.run(sources, to: format) { fraction in
                Task { @MainActor in self?.updateProgress(fraction, job: id, token: token) }
            }
            self?.finish(result, job: id, token: token)
        }
        jobs[id] = (task, 0)
        publishJobStatus()

        // Long jobs (mostly video) continue in the menu bar instead of parking the wheel on screen.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.backgroundAfter))
            guard let self, self.generation == token, self.model.phase == .converting else { return }
            self.dismiss()
        }
    }

    private func updateProgress(_ fraction: Double, job id: UUID, token: Int) {
        guard let job = jobs[id] else { return }
        jobs[id]?.progress = max(job.progress, fraction)
        if generation == token { model.progress = max(model.progress, fraction) }
        publishJobStatus()
    }

    private func finish(_ result: ConversionResult, job id: UUID, token: Int) {
        jobs[id] = nil
        if !result.failures.isEmpty {
            NSLog("FileConverter: %@", result.failures.joined(separator: "; "))
        }
        publishJobStatus(finished: result)

        guard generation == token else { return } // wheel already hidden or showing something else
        if result.cancelled {
            dismiss()
        } else if result.failures.isEmpty {
            let count = result.outputs.count
            model.phase = .done(count == 1 ? "Saved" : "Saved \(count)")
            dismiss(after: 0.9)
        } else {
            model.phase = .failed(result.failures.count == 1 ? "Failed" : "\(result.failures.count) failed")
            dismiss(after: 2.5)
        }
    }

    private func publishJobStatus(finished result: ConversionResult? = nil) {
        if !jobs.isEmpty {
            let progress = jobs.values.map(\.progress).reduce(0, +) / Double(jobs.count)
            onJobStatusChanged?(.running(progress))
        } else if let result, !result.cancelled {
            onJobStatusChanged?(.finished(failure: result.failures.first))
        } else {
            onJobStatusChanged?(.idle)
        }
    }
}
