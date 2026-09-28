import CoreGraphics
import Foundation
import ImageIO

enum ConversionError: LocalizedError {
    case unreadable(String)
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read \(name)"
        case .unwritable(let name): "Couldn't write \(name)"
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
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { throw ConversionError.unreadable(name) }

        // Keep metadata (EXIF, GPS, orientation, color profile) from the original.
        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = lossyQuality
        }
        if !format.supportsAlpha, image.hasAlpha, let flattened = flattenOnWhite(image) {
            image = flattened
        }

        let destination = availableURL(for: source.deletingPathExtension().appendingPathExtension(format.fileExtension))
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

    /// JPEG has no alpha channel, so transparent pixels would turn black; composite onto white instead.
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
