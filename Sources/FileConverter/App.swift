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
    private let setup = SetupWindowController()
    private var statusItem: NSStatusItem?
    private var dragToggle: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var lastErrorItem: NSMenuItem?
    /// Bumped per status change so an old "finished" icon doesn't reset a newer one.
    private var statusGeneration = 0
    private static let idleIcon = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                          accessibilityDescription: "File Converter")

    private var showsWheelWhileDragging: Bool {
        get { UserDefaults.standard.object(forKey: Self.dragWheelKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.dragWheelKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        wheel.onJobStatusChanged = { [weak self] status in self?.show(status) }
        dragWatcher.onWheelRequested = { [weak self] urls, wheelMode in
            guard let self, !self.wheel.isVisible else { return }
            self.wheel.present(urls, at: NSEvent.mouseLocation, mode: .drag, wheel: wheelMode)
        }
        if showsWheelWhileDragging { dragWatcher.start() }
        if !SetupWindowController.hasCompletedSetup { setup.show() }
    }

    /// Finder "Open With", or files dropped on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = MediaKind.batch(from: urls)
        guard !files.isEmpty else { return }
        wheel.presentCentered(files)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.idleIcon
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let menu = NSMenu()
        menu.addItem(withTitle: "Convert Files…", action: #selector(chooseFiles), keyEquivalent: "o").target = self

        let cancel = NSMenuItem(title: "Cancel Conversion", action: #selector(cancelConversion), keyEquivalent: ".")
        cancel.target = self
        cancel.isHidden = true
        menu.addItem(cancel)
        cancelItem = cancel

        let lastError = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastError.isEnabled = false
        lastError.isHidden = true
        menu.addItem(lastError)
        lastErrorItem = lastError

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show Wheel on ⌥-Drag", action: #selector(toggleDragWheel), keyEquivalent: "")
        toggle.target = self
        toggle.state = showsWheelWhileDragging ? .on : .off
        menu.addItem(toggle)
        dragToggle = toggle

        let sounds = NSMenuItem(title: "Sound Effects", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = TickSound.shared.isEnabled ? .on : .off
        menu.addItem(sounds)

        menu.addItem(withTitle: "Setup & Permissions…", action: #selector(showSetup), keyEquivalent: ",").target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit File Converter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        let files = panel.runModal() == .OK ? MediaKind.batch(from: panel.urls) : []
        guard !files.isEmpty else { return }
        wheel.presentCentered(files)
    }

    @objc private func cancelConversion() {
        wheel.cancelAllJobs()
    }

    /// Progress lives in the menu bar once the wheel has hidden, e.g. during a long video export.
    private func show(_ status: WheelController.JobStatus) {
        guard let button = statusItem?.button else { return }
        statusGeneration += 1
        cancelItem?.isHidden = !wheel.hasRunningJobs

        switch status {
        case .idle:
            button.image = Self.idleIcon
            button.title = ""
        case .running(let progress):
            button.image = Self.idleIcon
            button.title = " " + progress.formatted(.percent.precision(.fractionLength(0)))
        case .finished(let failure):
            button.title = ""
            button.image = NSImage(systemSymbolName: failure == nil ? "checkmark.circle" : "exclamationmark.triangle",
                                   accessibilityDescription: failure == nil ? "Converted" : "Conversion failed")
            lastErrorItem?.title = failure.map { "Last error: \($0)" } ?? ""
            lastErrorItem?.isHidden = failure == nil
            let token = statusGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.statusGeneration == token else { return }
                self.show(.idle)
            }
        }
    }

    @objc private func showSetup() {
        setup.show()
    }

    @objc private func toggleSounds(_ sender: NSMenuItem) {
        TickSound.shared.isEnabled.toggle()
        sender.state = TickSound.shared.isEnabled ? .on : .off
        guard TickSound.shared.isEnabled else { return }
        TickSound.shared.play() // preview it, then let the audio hardware go again
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if self?.wheel.isVisible == false { TickSound.shared.stop() }
        }
    }

    @objc private func toggleDragWheel() {
        showsWheelWhileDragging.toggle()
        dragToggle?.state = showsWheelWhileDragging ? .on : .off
        if showsWheelWhileDragging { dragWatcher.start() } else { dragWatcher.stop() }
    }
}
