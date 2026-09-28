import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoConverter {
    static let gifFrameRate = 12.0
    static let gifMaxDimension: CGFloat = 640
    static let gifMaxDuration = 60.0

    /// Writes a converted copy next to `source`. Honors task cancellation and removes partial output.
    static func convert(_ source: URL, to format: VideoFormat,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        let destination = Converter.availableURL(
            for: source.deletingPathExtension().appendingPathExtension(format.fileExtension))
        do {
            if format == .gif {
                try await makeGIF(from: asset, to: destination, name: name, progress: progress)
            } else {
                try await export(asset, to: destination, as: format, name: name, progress: progress)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if error is ConversionError || Task.isCancelled { throw error }
            throw ConversionError.failed(name, error.localizedDescription)
        }
    }

    private static func export(_ asset: AVURLAsset, to destination: URL, as format: VideoFormat, name: String,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let needsVideo = format != .m4a
        guard try await !asset.loadTracks(withMediaType: needsVideo ? .video : .audio).isEmpty else {
            throw needsVideo ? ConversionError.noVideo(name) : ConversionError.noAudio(name)
        }
        guard let preset = format.preset,
              await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: format.fileType),
              let session = AVAssetExportSession(asset: asset, presetName: preset)
        else { throw ConversionError.unsupported(name, format.label) }

        session.shouldOptimizeForNetworkUse = format.fileType == .mp4
        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let exportProgress) = state { progress(exportProgress.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: destination, as: format.fileType)
    }

    private static func makeGIF(from asset: AVURLAsset, to destination: URL, name: String,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ConversionError.noVideo(name) }
        let duration = try await asset.load(.duration).seconds
        guard duration <= gifMaxDuration else { throw ConversionError.tooLong(name, limit: Int(gifMaxDuration)) }

        let frameCount = max(1, Int(duration * gifFrameRate))
        let times = (0..<frameCount).map { CMTime(seconds: Double($0) / gifFrameRate, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: gifMaxDimension, height: gifMaxDimension)
        let tolerance = CMTime(seconds: 0.5 / gifFrameRate, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let gif = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString,
                                                        frameCount, nil)
        else { throw ConversionError.unwritable(destination.lastPathComponent) }
        CGImageDestinationSetProperties(gif, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0], // loop forever
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1 / gifFrameRate],
        ] as CFDictionary

        var added = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            CGImageDestinationAddImage(gif, try result.image, frameProperties)
            added += 1
            progress(Double(added) / Double(frameCount))
        }
        try Task.checkCancellation()
        guard added == frameCount, CGImageDestinationFinalize(gif) else {
            throw ConversionError.unwritable(destination.lastPathComponent)
        }
    }
}
