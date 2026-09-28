import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Output formats, one wedge each, clockwise from the top. Adding a case here adds a wedge
/// (it must be a type ImageIO can write — see `CGImageDestinationCopyTypeIdentifiers()`).
enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heic, avif, tiff, gif, bmp, pdf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jpeg: "JPG"
        default: rawValue.uppercased()
        }
    }

    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .avif: UTType("public.avif")!
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .pdf: .pdf
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    var isLossy: Bool { [.jpeg, .heic, .avif].contains(self) }
    /// BMP technically can hold alpha, but most apps ignore it and show black.
    var supportsAlpha: Bool { ![.jpeg, .bmp].contains(self) }

    /// The output format a file is already in, or nil if it's something else (RAW, WebP, …).
    init?(url: URL) {
        guard let type = url.contentType else { return nil }
        if let match = Self.allCases.first(where: { type.conforms(to: $0.type) }) {
            self = match
        } else if type.conforms(to: .heif) {
            self = .heic
        } else {
            return nil
        }
    }

    /// Anything ImageIO can decode: the output formats plus RAW, WebP, JPEG XL, PSD, …
    static func canConvert(from url: URL) -> Bool {
        guard let type = url.contentType, type.conforms(to: .image) else { return false }
        return readableTypes.contains { type.conforms(to: $0) }
    }

    private static let readableTypes: [UTType] =
        ((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []).compactMap { UTType($0) }
}

extension URL {
    var contentType: UTType? {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: pathExtension)
    }

    var isRawImage: Bool { contentType?.conforms(to: .rawImage) ?? false }
}
