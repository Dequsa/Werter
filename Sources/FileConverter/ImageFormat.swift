import Foundation
import UniformTypeIdentifiers

/// Formats shown on the wheel, clockwise from the top. Adding a case here adds a wedge.
enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jpeg: "JPG"
        case .png: "PNG"
        case .heic: "HEIC"
        }
    }

    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        }
    }

    var isLossy: Bool { self != .png }
    var supportsAlpha: Bool { self != .jpeg }

    /// The format of an existing file, or nil if it isn't one we handle.
    init?(url: URL) {
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard let type = contentType ?? UTType(filenameExtension: url.pathExtension) else { return nil }
        if let match = Self.allCases.first(where: { type.conforms(to: $0.type) }) {
            self = match
        } else if type.conforms(to: .heif) {
            self = .heic
        } else {
            return nil
        }
    }
}
