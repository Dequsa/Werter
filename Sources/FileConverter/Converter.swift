import CoreGraphics
import Foundation
import ImageIO

enum ConversionError: LocalizedError {
    case unreadable(String)
    case unwritable(String)
    case tooLarge(String, limit: Int)
    case tooLong(String, limit: Int)
    case noVideo(String)
    case noAudio(String)
    case unsupported(String, String)
    case failed(String, String)
    case noSubject(String)
    case alreadySmall(String, String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read \(name)"
        case .unwritable(let name): "Couldn't write \(name)"
        case .tooLarge(let name, let limit): "\(name) is larger than \(limit) px"
        case .tooLong(let name, let limit): "\(name) is longer than \(limit) s"
        case .noVideo(let name): "\(name) has no video"
        case .noAudio(let name): "\(name) has no audio"
        case .unsupported(let name, let format): "\(name) can't be converted to \(format)"
        case .failed(let name, let reason): "\(name): \(reason)"
        case .noSubject(let name): "No subject found in \(name)"
        case .alreadySmall(let name, let size): "\(name) is already \(size) or smaller"
        }
    }
}

struct ConversionResult: Sendable {
    var outputs: [URL] = []
    var failures: [String] = []
    var cancelled = false
}

enum Converter {
    static let lossyQuality = 0.9

    /// Converts one file after another, reporting overall progress from 0 to 1.
    /// Nonisolated and async, so it runs off the main thread; stops early when the task is cancelled.
    static func run(_ sources: [URL], to format: WheelOption,
                    progress: @escaping @Sendable (Double) -> Void) async -> ConversionResult {
        var result = ConversionResult()
        let share = 1 / Double(max(sources.count, 1))
        for (index, source) in sources.enumerated() {
            guard !Task.isCancelled else { break }
            let base = Double(index) * share
            do {
                switch format {
                case .image(let imageFormat):
                    result.outputs.append(try convert(source, to: imageFormat))
                case .video(let videoFormat):
                    result.outputs.append(try await VideoConverter.convert(source, to: videoFormat) { fraction in
                        progress(base + fraction * share)
                    })
                case .photoAction(let action):
                    result.outputs.append(try PhotoProcessor.apply(action, to: source))
                case .videoAction(let action):
                    result.outputs.append(try await VideoProcessor.apply(action, to: source) { fraction in
                        progress(base + fraction * share)
                    })
                }
            } catch {
                if Task.isCancelled { break }
                result.failures.append(error.localizedDescription)
            }
            progress(base + share)
        }
        result.cancelled = Task.isCancelled
        return result
    }

    /// Writes a converted copy next to `source` and returns its URL. Never overwrites existing files.
    static func convert(_ source: URL, to format: ImageFormat) throws -> URL {
        let name = source.lastPathComponent
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError.unreadable(name)
        }
        // Keep metadata (EXIF, GPS, orientation, color profile) from the original.
        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        // WebP is written without EXIF, so the rotation has to be baked into the pixels.
        guard let image = source.isRawImage || format == .webp
            ? uprightImage(imageSource, properties: &properties)
            : CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { throw ConversionError.unreadable(name) }

        // Keep screenshots and graphics pixel-perfect in WebP; photos get the usual lossy quality.
        let losslessWebP = ImageFormat(url: source).map { !$0.isLossy } ?? false
        return try write(image, properties: properties, as: format,
                         to: outputURL(for: source, extension: format.fileExtension), losslessWebP: losslessWebP)
    }

    /// Encodes `image` into `destination`, applying the per-format rules (quality, TIFF compression,
    /// flattening for formats without alpha). Removes the file again if writing fails.
    @discardableResult
    static func write(_ image: CGImage, properties: [CFString: Any], as format: ImageFormat, to destination: URL,
                      losslessWebP: Bool = false) throws -> URL {
        var image = image
        var properties = properties
        if format == .webp {
            let data = try WebPEncoder.encode(image, quality: lossyQuality, lossless: losslessWebP,
                                              name: destination.lastPathComponent)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
            } catch {
                throw ConversionError.unwritable(destination.lastPathComponent)
            }
            return destination
        }

        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = lossyQuality
        }
        if format == .tiff {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW: lossless, far smaller than uncompressed
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if !format.supportsAlpha, image.hasAlpha, let flattened = flattenOnWhite(image) {
            image = flattened
        }

        guard let imageDestination = CGImageDestinationCreateWithURL(
            destination as CFURL, format.type.identifier as CFString, 1, nil
        ) else { throw ConversionError.unwritable(destination.lastPathComponent) }

        CGImageDestinationAddImage(imageDestination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.unwritable(destination.lastPathComponent)
        }
        return destination
    }

    /// A free URL next to `source`: "photo.jpg" + prefix "cropped" → "cropped-photo.jpg".
    static func outputURL(for source: URL, prefix: String? = nil, extension ext: String) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let name = prefix.map { "\($0)-\(stem)" } ?? stem
        return availableURL(for: source.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(ext))
    }

    /// "photo.jpg" → "photo 2.jpg" → "photo 3.jpg" … until the name is free.
    static func availableURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Decodes already rotated upright — at full size, or scaled so the longest side is `maxPixelSize` —
    /// and resets the orientation tag to avoid rotating twice. For RAWs this develops the sensor data
    /// with the camera's default look.
    static func uprightImage(_ source: CGImageSource, properties: inout [CFString: Any],
                             maxPixelSize: Int? = nil) -> CGImage? {
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, // full image, not an embedded preview
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let size = maxPixelSize ?? (max(width, height) > 0 ? max(width, height) : nil) {
            options[kCGImageSourceThumbnailMaxPixelSize] = size
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        return image
    }

    /// JPEG and BMP have no (usable) alpha channel, so transparent pixels would turn black; composite onto white instead.
    private static func flattenOnWhite(_ image: CGImage) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
