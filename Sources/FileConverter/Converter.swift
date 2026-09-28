import CoreGraphics
import Foundation
import ImageIO

enum ConversionError: LocalizedError {
    case unreadable(String)
    case unwritable(String)
    case tooLarge(String, limit: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read \(name)"
        case .unwritable(let name): "Couldn't write \(name)"
        case .tooLarge(let name, let limit): "\(name) is larger than \(limit) px"
        }
    }
}

struct ConversionResult: Sendable {
    var outputs: [URL] = []
    var failures: [String] = []
}

enum Converter {
    static let lossyQuality = 0.9

    static func convertAll(_ sources: [URL], to format: ImageFormat) -> ConversionResult {
        var result = ConversionResult()
        for source in sources {
            do {
                result.outputs.append(try convert(source, to: format))
            } catch {
                result.failures.append(error.localizedDescription)
            }
        }
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
        guard var image = source.isRawImage || format == .webp
            ? renderUpright(imageSource, properties: &properties)
            : CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { throw ConversionError.unreadable(name) }

        let destination = availableURL(for: source.deletingPathExtension().appendingPathExtension(format.fileExtension))
        if format == .webp {
            // Keep screenshots and graphics pixel-perfect; photos get the usual lossy quality.
            let lossless = ImageFormat(url: source).map { !$0.isLossy } ?? false
            let data = try WebPEncoder.encode(image, quality: lossyQuality, lossless: lossless, name: name)
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

    /// Decodes at full size, already rotated upright, and resets the orientation tag to avoid
    /// rotating twice. For RAWs this develops the sensor data with the camera's default look.
    private static func renderUpright(_ source: CGImageSource, properties: inout [CFString: Any]) -> CGImage? {
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, // full image, not an embedded preview
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if max(width, height) > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height) }
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
