import AVFoundation
import UniformTypeIdentifiers

/// Video wheel wedges, clockwise from the top.
enum VideoFormat: String, CaseIterable, Identifiable, Sendable {
    /// H.264 — plays everywhere.
    case mp4
    /// H.265 — about half the size of H.264 at the same quality.
    case hevc
    /// Rewraps into QuickTime without re-encoding: instant and lossless.
    case mov
    /// ProRes 422 — large, but what editing apps like best.
    case prores
    /// Audio track only.
    case m4a
    /// Animated, silent, downscaled.
    case gif

    var id: String { rawValue }

    var label: String {
        switch self {
        case .prores: "PRORES"
        default: rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4, .hevc: "mp4"
        case .mov, .prores: "mov"
        case .m4a: "m4a"
        case .gif: "gif"
        }
    }

    /// nil for GIF, which is built frame by frame instead of exported.
    var preset: String? {
        switch self {
        case .mp4: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        case .mov: AVAssetExportPresetPassthrough
        case .prores: AVAssetExportPresetAppleProRes422LPCM
        case .m4a: AVAssetExportPresetAppleM4A
        case .gif: nil
        }
    }

    var fileType: AVFileType {
        switch self {
        case .mp4, .hevc: .mp4
        case .mov, .prores, .gif: .mov
        case .m4a: .m4a
        }
    }

    /// Only QuickTime counts as "already MOV". MP4 is never greyed out: re-encoding an
    /// MP4 to H.264 is useful (e.g. HEVC → H.264 for compatibility).
    init?(url: URL) {
        guard let type = url.contentType, type.conforms(to: .quickTimeMovie) else { return nil }
        self = .mov
    }

    /// MOV, MP4, M4V, AVI, 3GP, MTS/AVCHD, MPEG… — whatever AVFoundation can open.
    /// (MKV, WebM, FLV and WMV aren't supported by macOS.)
    static func canConvert(from url: URL) -> Bool {
        guard let type = url.contentType, type.conforms(to: .movie) else { return false }
        return readableTypes.contains { type.conforms(to: $0) }
    }

    private static let readableTypes: [UTType] =
        AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }.filter { $0.conforms(to: .movie) }
}
