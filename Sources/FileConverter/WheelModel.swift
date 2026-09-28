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
    /// The wedges, which depend on whether photos or videos were dropped.
    @Published private(set) var options: [OutputFormat] = MediaKind.image.outputs
    /// Formats every file is already in — nothing to convert to.
    @Published private(set) var disabled: Set<OutputFormat> = []
    @Published var hovered: OutputFormat?
    @Published var phase: Phase = .choosing
    @Published var progress: Double = 0

    func load(_ urls: [URL]) {
        files = urls
        hovered = nil
        phase = .choosing
        progress = 0
        thumbnail = nil
        options = (MediaKind(urls: urls) ?? .image).outputs

        // Only grey out a format when *every* file is already in it (a RAW + a JPG can still go to JPG).
        let current = urls.map(OutputFormat.current(of:))
        if let first = current.first, let format = first, current.allSatisfy({ $0 == format }) {
            disabled = [format]
        } else {
            disabled = []
        }

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
