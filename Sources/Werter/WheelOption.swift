import CoreGraphics
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

    func options(for mode: WheelMode) -> [WheelOption] {
        switch (self, mode) {
        case (.image, .convert): ImageFormat.allCases.map(WheelOption.image)
        case (.video, .convert): VideoFormat.allCases.map(WheelOption.video)
        case (.image, .actions): PhotoAction.allCases.map(WheelOption.photoAction)
        case (.video, .actions): VideoAction.allCases.map(WheelOption.videoAction)
        }
    }

    /// Keeps the files matching the first supported one, e.g. when an open panel returns a mix.
    static func batch(from urls: [URL]) -> [URL] {
        guard let kind = urls.lazy.compactMap(MediaKind.init(url:)).first else { return [] }
        return urls.filter { MediaKind(url: $0) == kind }
    }
}

/// ⌥ shows the format wheel; ⇧⌥ shows the actions wheel.
enum WheelMode: Sendable {
    case convert, actions
}

/// One wedge on the wheel.
enum WheelOption: Hashable, Sendable, Identifiable {
    case image(ImageFormat)
    case video(VideoFormat)
    case photoAction(PhotoAction)
    case videoAction(VideoAction)

    var id: Self { self }

    /// Big text on the wedge (unused when there's a symbol).
    var label: String {
        switch self {
        case .image(let format): format.label
        case .video(let format): format.label
        case .photoAction(let action): action.label
        case .videoAction(let action): action.label
        }
    }

    /// SF Symbol drawn instead of the label.
    var symbol: String? {
        switch self {
        case .image, .video: nil
        case .photoAction(let action): action.symbol
        case .videoAction(let action): action.symbol
        }
    }

    /// Small text under the label or symbol.
    var caption: String? {
        switch self {
        case .image, .video: nil
        case .photoAction(let action): action.caption
        case .videoAction(let action): action.caption
        }
    }

    /// Shown in the centre pill while hovering.
    var summary: String {
        switch self {
        case .image, .video: "→ \(label)"
        case .photoAction(let action): action.summary
        case .videoAction(let action): action.summary
        }
    }

    var kind: MediaKind {
        switch self {
        case .image, .photoAction: .image
        case .video, .videoAction: .video
        }
    }

    /// The wedge a file is already in, so it can be greyed out and skipped.
    static func current(of url: URL) -> WheelOption? {
        if let format = ImageFormat(url: url) { return .image(format) }
        if let format = VideoFormat(url: url) { return .video(format) }
        return nil
    }
}

struct AspectRatio: Hashable, Sendable {
    let width: Int
    let height: Int

    static let square = AspectRatio(width: 1, height: 1)
    static let portrait = AspectRatio(width: 4, height: 5)
    static let story = AspectRatio(width: 9, height: 16)
    static let wide = AspectRatio(width: 16, height: 9)

    var label: String { "\(width):\(height)" }

    /// The largest rect of this ratio inside `size`, centred on `focus` (0–1, top-left origin)
    /// as far as the edges allow. Video encoders need even sides.
    func cropRect(in size: CGSize, focus: CGPoint, evenSides: Bool = false) -> CGRect {
        let ratio = CGFloat(width) / CGFloat(height)
        var cropWidth = min(size.width, size.height * ratio)
        var cropHeight = min(size.height, size.width / ratio)
        cropWidth = evenSides ? floor(cropWidth / 2) * 2 : floor(cropWidth)
        cropHeight = evenSides ? floor(cropHeight / 2) * 2 : floor(cropHeight)
        let x = min(max(focus.x * size.width - cropWidth / 2, 0), size.width - cropWidth)
        let y = min(max(focus.y * size.height - cropHeight / 2, 0), size.height - cropHeight)
        return CGRect(x: x.rounded(), y: y.rounded(), width: cropWidth, height: cropHeight)
    }
}

/// Photo actions wheel (⇧⌥), clockwise from the top.
enum PhotoAction: CaseIterable, Sendable {
    case square, portrait, story, wide, cutout, half, fit2048, stripInfo

    var aspect: AspectRatio? {
        switch self {
        case .square: .square
        case .portrait: .portrait
        case .story: .story
        case .wide: .wide
        default: nil
        }
    }

    var label: String {
        switch self {
        case .half: "50%"
        case .fit2048: "2048"
        default: aspect?.label ?? ""
        }
    }

    var symbol: String? {
        switch self {
        case .cutout: "scissors"
        case .stripInfo: "location.slash"
        default: nil
        }
    }

    var caption: String? {
        switch self {
        case .square: "Square"
        case .portrait: "Portrait"
        case .story: "Story"
        case .wide: "Wide"
        case .cutout: "Cutout"
        case .half: "Size"
        case .fit2048: "Max px"
        case .stripInfo: "Strip Info"
        }
    }

    /// Output names read "cropped-photo.jpg".
    var filePrefix: String {
        switch self {
        case .square, .portrait, .story, .wide: "cropped"
        case .cutout: "cutout"
        case .half, .fit2048: "resized"
        case .stripInfo: "stripped"
        }
    }

    var summary: String {
        switch self {
        case .cutout: "Cut out"
        case .half: "Half size"
        case .fit2048: "Max 2048"
        case .stripInfo: "Strip info"
        default: "Crop \(label)"
        }
    }
}

/// Video actions wheel (⇧⌥), clockwise from the top.
enum VideoAction: CaseIterable, Sendable {
    case story, square, portrait, wide, mute, p1080, p720, frame

    var aspect: AspectRatio? {
        switch self {
        case .story: .story
        case .square: .square
        case .portrait: .portrait
        case .wide: .wide
        default: nil
        }
    }

    /// Target short side for the shrink actions.
    var shortSide: Int? {
        switch self {
        case .p1080: 1080
        case .p720: 720
        default: nil
        }
    }

    var label: String {
        switch self {
        case .p1080: "1080p"
        case .p720: "720p"
        default: aspect?.label ?? ""
        }
    }

    var symbol: String? {
        switch self {
        case .mute: "speaker.slash"
        case .frame: "camera"
        default: nil
        }
    }

    var caption: String? {
        switch self {
        case .story: "Reels"
        case .square: "Square"
        case .portrait: "Portrait"
        case .wide: "Wide"
        case .mute: "Mute"
        case .p1080, .p720: "Shrink"
        case .frame: "Frame"
        }
    }

    /// Output names read "cropped-clip.mov".
    var filePrefix: String {
        switch self {
        case .story, .square, .portrait, .wide: "cropped"
        case .mute: "muted"
        case .p1080, .p720: "resized"
        case .frame: "frame"
        }
    }

    var summary: String {
        switch self {
        case .mute: "Mute"
        case .p1080, .p720: "Shrink \(label)"
        case .frame: "Grab frame"
        default: "Crop \(label)"
        }
    }
}
