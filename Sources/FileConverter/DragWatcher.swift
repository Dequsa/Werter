import AppKit

/// Notices when the user starts dragging supported image files anywhere on screen.
/// Every drag writes to the shared drag pasteboard, so a changed changeCount during a
/// mouse drag means a new drag session began. Global mouse monitors need no permissions.
@MainActor
final class DragWatcher {
    var onImageDragStarted: (([URL]) -> Void)?

    private let pasteboard = NSPasteboard(name: .drag)
    private lazy var lastChangeCount = pasteboard.changeCount
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        lastChangeCount = pasteboard.changeCount
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func check() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = urls.filter { ImageFormat(url: $0) != nil }
        // Only when every dragged file is an image — mixed drags are probably meant for somewhere else.
        guard !images.isEmpty, images.count == urls.count else { return }
        onImageDragStarted?(images)
    }
}
