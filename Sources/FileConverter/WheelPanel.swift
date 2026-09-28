import AppKit
import SwiftUI

/// Borderless, transparent, always-on-top window that never steals focus from Finder mid-drag.
final class WheelPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = content
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Drop target and mouse handler for the whole wheel. SwiftUI only draws; this view decides what's hovered.
final class WheelContainerView: NSView {
    private let model: WheelModel
    private var geometry: WheelGeometry { WheelGeometry(count: model.options.count) }
    var onChoose: ((WheelOption, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    var onShiftPressed: (() -> Void)?

    init(model: WheelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: WheelGeometry.canvas, height: WheelGeometry.canvas))
        registerForDraggedTypes([.fileURL])

        let diameter = WheelGeometry.diameter
        let blur = NSVisualEffectView(frame: NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2,
                                                    width: diameter, height: diameter))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = NSImage(size: blur.bounds.size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        addSubview(blur)

        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = bounds
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Swallow all events so the hosting view doesn't; we route them ourselves.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func format(at windowPoint: NSPoint) -> WheelOption? {
        guard let index = geometry.index(at: convert(windowPoint, from: nil), in: bounds) else { return nil }
        let format = model.options[index]
        return model.disabled.contains(format) ? nil : format
    }

    private func updateHover(_ windowPoint: NSPoint) {
        guard model.phase == .choosing else { return }
        let format = format(at: windowPoint)
        guard format != model.hovered else { return }
        model.hovered = format
        if let format, let index = model.options.firstIndex(of: format) {
            Self.tick(forWedge: index)
            TickSound.shared.play()
        }
    }

    /// A trackpad tap when crossing onto a wedge, with a different feel per wedge
    /// so you can tell them apart without looking. Needs a Force Touch trackpad.
    private static func tick(forWedge index: Int) {
        let patterns: [NSHapticFeedbackManager.FeedbackPattern] = [.levelChange, .alignment, .generic]
        NSHapticFeedbackManager.defaultPerformer.perform(patterns[index % patterns.count], performanceTime: .now)
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHover(sender.draggingLocation)
        return model.hovered == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if model.phase == .choosing { model.hovered = nil }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard model.phase == .choosing, let format = format(at: sender.draggingLocation) else { return false }
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        onChoose?(format, urls.isEmpty ? model.files : urls)
        return true
    }

    // MARK: Click mode

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event.locationInWindow) }

    override func mouseExited(with event: NSEvent) {
        if model.phase == .choosing { model.hovered = nil }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // While converting, a click hides the wheel; the job carries on in the menu bar.
        guard model.phase == .choosing else { return onCancel?() ?? () }
        if let format = format(at: event.locationInWindow) {
            onChoose?(format, model.files)
        } else {
            onCancel?()
        }
    }

    /// Click mode: ⇧ flips between formats and actions.
    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) { onShiftPressed?() }
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) } // Esc
    }
}
