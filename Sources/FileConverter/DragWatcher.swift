import AppKit

/// Notices when the user drags supported photos or videos anywhere on screen while holding ⌥.
/// Every drag writes to the shared drag pasteboard, so a changed changeCount during a
/// mouse drag means a new drag session began. Global mouse monitors and reading
/// `NSEvent.modifierFlags` need no permissions (a global flagsChanged monitor would).
@MainActor
final class DragWatcher {
    var onWheelRequested: (([URL]) -> Void)?

    private let pasteboard = NSPasteboard(name: .drag)
    private lazy var lastChangeCount = pasteboard.changeCount
    private var monitor: Any?
    /// Files in the current drag, waiting for ⌥ to be pressed.
    private var pendingFiles: [URL] = []
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
            pendingFiles = draggedFiles()
        }
        guard !pendingFiles.isEmpty else { return }
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
        let files = pendingFiles
        reset()
        onWheelRequested?(files)
        return true
    }

    private func reset() {
        pendingFiles = []
        optionPoll?.invalidate()
        optionPoll = nil
    }

    private func draggedFiles() -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        // Only when every file is a photo, or every file is a video — mixed drags are probably meant for somewhere else.
        return MediaKind(urls: urls) != nil ? urls : []
    }
}
