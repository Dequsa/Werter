import Foundation

/// What was dropped decides which wheel appears.
enum MediaKind: Sendable {
    case image, video

    init?(url: URL) {
        if ImageFormat.canConvert(from: url) {
            self = .image
        } else if VideoFormat.canConvert(from: url) {
            self = .video
        } else {
            return nil
        }
    }

    /// The kind shared by every file; nil when empty, unsupported or mixed.
    init?(urls: [URL]) {
        let kinds = Set(urls.map(MediaKind.init(url:)))
        guard kinds.count == 1, let only = kinds.first, let kind = only else { return nil }
        self = kind
    }

    var outputs: [OutputFormat] {
        switch self {
        case .image: ImageFormat.allCases.map(OutputFormat.image)
        case .video: VideoFormat.allCases.map(OutputFormat.video)
        }
    }

    /// Keeps the files matching the first supported one, e.g. when an open panel returns a mix.
    static func batch(from urls: [URL]) -> [URL] {
        guard let kind = urls.lazy.compactMap(MediaKind.init(url:)).first else { return [] }
        return urls.filter { MediaKind(url: $0) == kind }
    }
}

/// One wedge on the wheel.
enum OutputFormat: Hashable, Sendable, Identifiable {
    case image(ImageFormat)
    case video(VideoFormat)

    var id: String { "\(kind)-\(label)" }

    var label: String {
        switch self {
        case .image(let format): format.label
        case .video(let format): format.label
        }
    }

    var kind: MediaKind {
        switch self {
        case .image: .image
        case .video: .video
        }
    }

    /// The wedge a file is already in, so it can be greyed out and skipped.
    static func current(of url: URL) -> OutputFormat? {
        if let format = ImageFormat(url: url) { return .image(format) }
        if let format = VideoFormat(url: url) { return .video(format) }
        return nil
    }
}
