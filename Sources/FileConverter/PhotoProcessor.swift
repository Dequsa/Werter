import CoreImage
import ImageIO
import Vision

enum Saliency {
    static let center = CGPoint(x: 0.5, y: 0.5)

    /// Centre of what draws the eye (0–1, top-left origin), via Vision's attention saliency.
    /// Falls back to the image centre when nothing stands out.
    static func focus(in image: CGImage) -> CGPoint {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let objects = request.results?.first?.salientObjects, !objects.isEmpty
        else { return center }
        let box = objects.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: box.midX, y: 1 - box.midY) // Vision's origin is bottom-left
    }
}

enum PhotoProcessor {
    static let fitSize = 2048

    /// Saves the result next to `source`, e.g. "cropped-photo.jpg". Keeps the source format when
    /// macOS can write it; RAW, JPEG XL and friends come out as JPEG.
    static func apply(_ action: PhotoAction, to source: URL) throws -> URL {
        let name = source.lastPathComponent
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError.unreadable(name)
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        let format = ImageFormat(url: source) ?? .jpeg
        let lossless = !format.isLossy

        if action == .stripInfo {
            return try stripInfo(imageSource, source: source, format: format, properties: properties,
                                 prefix: action.filePrefix)
        }

        if action == .half || action == .fit2048 {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            let longest = max(width, height)
            let target = action == .half ? longest / 2 : fitSize
            guard longest > target else { throw ConversionError.alreadySmall(name, "\(fitSize) px") }
            guard let image = Converter.uprightImage(imageSource, properties: &properties, maxPixelSize: target) else {
                throw ConversionError.unreadable(name)
            }
            return try Converter.write(image, properties: properties, as: format,
                                       to: Converter.outputURL(for: source, prefix: action.filePrefix,
                                                               extension: format.fileExtension),
                                       losslessWebP: lossless)
        }

        guard let image = Converter.uprightImage(imageSource, properties: &properties) else {
            throw ConversionError.unreadable(name)
        }

        if action == .cutout {
            let cutout = try removeBackground(image, name: name)
            return try Converter.write(cutout, properties: properties, as: .png,
                                       to: Converter.outputURL(for: source, prefix: action.filePrefix, extension: "png"))
        }

        guard let aspect = action.aspect else { throw ConversionError.unsupported(name, action.summary) }
        let rect = aspect.cropRect(in: CGSize(width: image.width, height: image.height), focus: Saliency.focus(in: image))
        guard let cropped = image.cropping(to: rect) else { throw ConversionError.unreadable(name) }
        properties[kCGImagePropertyPixelWidth] = cropped.width
        properties[kCGImagePropertyPixelHeight] = cropped.height
        return try Converter.write(cropped, properties: properties, as: format,
                                   to: Converter.outputURL(for: source, prefix: action.filePrefix,
                                                           extension: format.fileExtension),
                                   losslessWebP: lossless)
    }

    /// Cuts the subject(s) out with Vision's on-device foreground segmentation.
    private static func removeBackground(_ image: CGImage, name: String) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ConversionError.noSubject(name)
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let cutout = CIContext().createCGImage(masked, from: masked.extent, format: .RGBA8,
                                                     colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
        else { throw ConversionError.unreadable(name) }
        return cutout
    }

    /// Drops EXIF, GPS, IPTC and XMP. For JPEG, PNG, HEIC and TIFF this copies the compressed image
    /// data untouched (no quality loss) and keeps only the orientation; anything else is re-encoded
    /// upright with no metadata at all.
    private static func stripInfo(_ imageSource: CGImageSource, source: URL, format: ImageFormat,
                                  properties: [CFString: Any], prefix: String) throws -> URL {
        if let type = CGImageSourceGetType(imageSource) {
            let destination = Converter.outputURL(for: source, prefix: prefix, extension: source.pathExtension)
            if let imageDestination = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) {
                // ImageIO won't combine a replacement metadata set with its orientation option,
                // so the orientation goes inside the otherwise empty metadata.
                let metadata = CGImageMetadataCreateMutable()
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation, orientation as CFNumber)
                let options: [CFString: Any] = [
                    kCGImageDestinationMetadata: metadata,
                    kCGImageDestinationMergeMetadata: false,
                    kCGImageMetadataShouldExcludeGPS: true,
                    kCGImageMetadataShouldExcludeXMP: true,
                ]
                if CGImageDestinationCopyImageSource(imageDestination, imageSource, options as CFDictionary, nil) {
                    return destination
                }
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var uprightProperties = properties
        guard let image = Converter.uprightImage(imageSource, properties: &uprightProperties) else {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        return try Converter.write(image, properties: [:], as: format,
                                   to: Converter.outputURL(for: source, prefix: prefix, extension: format.fileExtension),
                                   losslessWebP: !format.isLossy)
    }
}
