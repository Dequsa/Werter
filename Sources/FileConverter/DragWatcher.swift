import AppKit

/// Notices when the user drags supported image files anywhere on screen while holding ⌥.
/// Every drag writes to the shared drag pasteboard, so a changed changeCount during a
/// mouse drag means a new drag session began. Global mouse monitors and reading
/// `NSEvent.modifierFlags` need no permissions (a global flagsChanged monitor would).
@MainActor
final class DragWatcher {
    var onWheelRequested: (([URL]) -> Void)?

    private let pasteboard = NSPasteboard(name: .drag)
    private lazy var lastChangeCount = pasteboard.changeCount
    private var monitor: Any?
    /// Images in the current drag, waiting for ⌥ to be pressed.
    private var pendingImages: [URL] = []
    /// Catches ⌥ pressed while the mouse is held still, when no drag events arrive.
    private var optionPoll: Timer?

    func start() {
        guard monitor == nil else { return }
        lastChangeCount = pasteboard.changeCount
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset()
    }

    private func mouseDragged() {
        if pasteboard.changeCount != lastChangeCount {
            lastChangeCount = pasteboard.changeCount
            pendingImages = draggedImages()
        }
        guard !pendingImages.isEmpty else { return }
        if !requestWheelIfOptionHeld(), optionPoll == nil {
            optionPoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollOption() }
            }
        }
    }

    private func pollOption() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            reset() // drag ended without ⌥
        } else {
            requestWheelIfOptionHeld()
        }
    }

    @discardableResult
    private func requestWheelIfOptionHeld() -> Bool {
        guard NSEvent.modifierFlags.contains(.option) else { return false }
        let images = pendingImages
        reset()
        onWheelRequested?(images)
        return true
    }

    private func reset() {
        pendingImages = []
        optionPoll?.invalidate()
        optionPoll = nil
    }

    private func draggedImages() -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = urls.filter(ImageFormat.canConvert(from:))
        // Only when every dragged file is an image — mixed drags are probably meant for somewhere else.
        return images.count == urls.count ? images : []
    }
}
