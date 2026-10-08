import AVFoundation

enum VideoProcessor {
    /// Saves the result next to `source`, e.g. "cropped-clip.mp4". Crops and mute keep the source
    /// container (MOV stays MOV); everything else that isn't MOV comes out as MP4.
    static func apply(_ action: VideoAction, to source: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.noVideo(name)
        }
        let isQuickTime = source.contentType?.conforms(to: .quickTimeMovie) ?? false
        let container: (ext: String, type: AVFileType) = isQuickTime ? ("mov", .mov) : ("mp4", .mp4)

        if action == .frame {
            let destination = Converter.outputURL(for: source, prefix: action.filePrefix, extension: "jpg")
            return try await VideoConverter.cleaningUp(destination, name: name) {
                try await grabFrame(asset, to: destination)
                progress(1)
            }
        }

        if action == .mute {
            let destination = Converter.outputURL(for: source, prefix: action.filePrefix, extension: container.ext)
            return try await VideoConverter.cleaningUp(destination, name: name) {
                let silent = try await videoOnly(asset)
                try await export(silent, preset: AVAssetExportPresetPassthrough, to: destination, as: container.type,
                                 name: name, label: action.summary, progress: progress)
            }
        }

        let display = try await displayGeometry(of: track)

        if let shortSide = action.shortSide {
            guard min(display.size.width, display.size.height) > CGFloat(shortSide) else {
                throw ConversionError.alreadySmall(name, action.label)
            }
            // These presets scale down to fit the box, keeping the aspect ratio. Always H.264 MP4.
            let preset = shortSide == 1080 ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720
            let destination = Converter.outputURL(for: source, prefix: action.filePrefix, extension: "mp4")
            return try await VideoConverter.cleaningUp(destination, name: name) {
                try await export(asset, preset: preset, to: destination, as: .mp4,
                                 name: name, label: action.summary, progress: progress)
            }
        }

        guard let aspect = action.aspect else { throw ConversionError.unsupported(name, action.summary) }
        let focus = await focus(of: asset)
        let crop = aspect.cropRect(in: display.size, focus: focus, evenSides: true)
        let destination = Converter.outputURL(for: source, prefix: action.filePrefix, extension: container.ext)
        return try await VideoConverter.cleaningUp(destination, name: name) {
            let composition = AVMutableVideoComposition()
            composition.renderSize = crop.size
            let frameDuration = try await track.load(.minFrameDuration)
            composition.frameDuration = frameDuration.isValid && frameDuration.seconds > 0
                ? frameDuration : CMTime(value: 1, timescale: 30)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            // Rotate upright (preferred transform), then shift the crop window to the origin.
            layer.setTransform(display.transform.concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY)),
                               at: .zero)
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]

            // Keep HEVC sources HEVC; everything else becomes H.264.
            let isHEVC = try await track.load(.formatDescriptions)
                .contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
            try await export(asset, preset: isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality,
                             to: destination, as: container.type, name: name, label: action.summary,
                             videoComposition: composition, progress: progress)
        }
    }

    private static func export(_ asset: AVAsset, preset: String, to destination: URL, as fileType: AVFileType,
                               name: String, label: String, videoComposition: AVVideoComposition? = nil,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
              let session = AVAssetExportSession(asset: asset, presetName: preset)
        else { throw ConversionError.unsupported(name, label) }
        session.videoComposition = videoComposition
        try await VideoConverter.run(session, to: destination, as: fileType, progress: progress)
    }

    /// The upright frame size, and a transform mapping the stored frame onto it with the origin at 0,0.
    private static func displayGeometry(of track: AVAssetTrack) async throws -> (size: CGSize, transform: CGAffineTransform) {
        let (naturalSize, preferred) = try await track.load(.naturalSize, .preferredTransform)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let transform = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        return (bounds.size, transform)
    }

    /// Averages the salient centre of a few frames spread across the clip, so the crop follows
    /// the subject without jumping around mid-video.
    private static func focus(of asset: AVAsset) async -> CGPoint {
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return Saliency.center }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let times = [0.1, 0.3, 0.5, 0.7, 0.9].map { CMTimeMultiplyByFloat64(duration, multiplier: $0) }

        var points: [CGPoint] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { points.append(Saliency.focus(in: image)) }
        }
        guard !points.isEmpty else { return Saliency.center }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                       y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    /// A copy of the asset with only its video tracks, so passthrough export drops the sound.
    private static func videoOnly(_ asset: AVAsset) async throws -> AVAsset {
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let copy = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        return composition
    }

    /// The exact middle frame, upright and full resolution, as a JPEG.
    private static func grabFrame(_ asset: AVAsset, to destination: URL) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let middle = CMTimeMultiplyByFloat64(try await asset.load(.duration), multiplier: 0.5)
        let image = try await generator.image(at: middle).image
        try Converter.write(image, properties: [:], as: .jpeg, to: destination)
    }
}
