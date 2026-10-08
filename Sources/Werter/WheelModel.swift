import AppKit
import AVFoundation
import ImageIO

@MainActor
final class WheelModel: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case converting
        case done(String)
        case failed(String)
    }

    @Published private(set) var files: [URL] = []
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var sizeText = ""
    /// Formats (⌥) or actions (⇧⌥).
    @Published private(set) var mode: WheelMode = .convert
    /// The wedges, which depend on the mode and on whether photos or videos were dropped.
    @Published private(set) var options: [WheelOption] = MediaKind.image.options(for: .convert)
    /// Formats every file is already in — nothing to convert to.
    @Published private(set) var disabled: Set<WheelOption> = []
    @Published var hovered: WheelOption?
    @Published var phase: Phase = .choosing
    @Published var progress: Double = 0

    func load(_ urls: [URL], mode: WheelMode = .convert) {
        files = urls
        phase = .choosing
        progress = 0
        thumbnail = nil
        self.mode = mode
        refreshOptions()

        let bytes = urls.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

        guard let first = urls.first else { return }
        Task {
            let image = await Task.detached(priority: .userInitiated) { await Self.makeThumbnail(first) }.value
            guard let image, self.files.first == first else { return }
            self.thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    func switchMode(to newMode: WheelMode) {
        guard phase == .choosing, newMode != mode else { return }
        mode = newMode
        refreshOptions()
    }

    private func refreshOptions() {
        hovered = nil
        options = (MediaKind(urls: files) ?? .image).options(for: mode)
        // Only grey out a format when *every* file is already in it (a RAW + a JPG can still go to JPG).
        let current = files.map(WheelOption.current(of:))
        if mode == .convert, let first = current.first, let format = first, current.allSatisfy({ $0 == format }) {
            disabled = [format]
        } else {
            disabled = []
        }
    }

    nonisolated private static func makeThumbnail(_ url: URL) async -> CGImage? {
        if MediaKind(url: url) == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            return try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
