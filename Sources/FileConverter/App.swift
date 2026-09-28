import AppKit
import UniformTypeIdentifiers

@main
enum FileConverterApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let dragWheelKey = "showWheelWhileDragging"

    private let wheel = WheelController()
    private let dragWatcher = DragWatcher()
    private var statusItem: NSStatusItem?
    private var dragToggle: NSMenuItem?

    private var showsWheelWhileDragging: Bool {
        get { UserDefaults.standard.object(forKey: Self.dragWheelKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.dragWheelKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        dragWatcher.onImageDragStarted = { [weak self] urls in
            guard let self, !self.wheel.isVisible else { return }
            self.wheel.present(urls, at: NSEvent.mouseLocation, mode: .drag)
        }
        if showsWheelWhileDragging { dragWatcher.start() }
    }

    /// Finder "Open With", or files dropped on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let images = urls.filter { ImageFormat(url: $0) != nil }
        guard !images.isEmpty else { return }
        wheel.presentCentered(images)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "File Converter")

        let menu = NSMenu()
        menu.addItem(withTitle: "Convert Images…", action: #selector(chooseFiles), keyEquivalent: "o").target = self

        let toggle = NSMenuItem(title: "Show Wheel While Dragging Images", action: #selector(toggleDragWheel), keyEquivalent: "")
        toggle.target = self
        toggle.state = showsWheelWhileDragging ? .on : .off
        menu.addItem(toggle)
        dragToggle = toggle

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit File Converter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ImageFormat.allCases.map(\.type) + [.heif]
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        wheel.presentCentered(panel.urls)
    }

    @objc private func toggleDragWheel() {
        showsWheelWhileDragging.toggle()
        dragToggle?.state = showsWheelWhileDragging ? .on : .off
        if showsWheelWhileDragging { dragWatcher.start() } else { dragWatcher.stop() }
    }
}
