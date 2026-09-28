import AppKit
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
    /// Formats every file is already in — nothing to convert to.
    @Published private(set) var disabled: Set<ImageFormat> = []
    @Published var hovered: ImageFormat?
    @Published var phase: Phase = .choosing

    func load(_ urls: [URL]) {
        files = urls
        hovered = nil
        phase = .choosing
        thumbnail = nil

        let formats = Set(urls.compactMap(ImageFormat.init(url:)))
        disabled = formats.count == 1 ? formats : []

        let bytes = urls.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

        guard let first = urls.first else { return }
        Task {
            let image = await Task.detached(priority: .userInitiated) { Self.makeThumbnail(first) }.value
            guard let image, self.files.first == first else { return }
            self.thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    nonisolated private static func makeThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
