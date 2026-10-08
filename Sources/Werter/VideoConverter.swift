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
        let destination = Converter.outputURL(for: source, extension: format.fileExtension)
        return try await cleaningUp(destination, name: name) {
            if format == .gif {
                try await makeGIF(from: asset, to: destination, name: name, progress: progress)
            } else {
                try await export(asset, to: destination, as: format, name: name, progress: progress)
            }
        }
    }

    /// Runs `work`, returning `destination`; on failure or cancellation deletes the partial file
    /// and puts the file name into AVFoundation's otherwise anonymous errors.
    static func cleaningUp(_ destination: URL, name: String, _ work: () async throws -> Void) async throws -> URL {
        do {
            try await work()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if error is ConversionError || Task.isCancelled { throw error }
            throw ConversionError.failed(name, error.localizedDescription)
        }
    }

    /// Exports while reporting progress; cancelling the calling task cancels the export.
    static func run(_ session: AVAssetExportSession, to destination: URL, as fileType: AVFileType,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        session.shouldOptimizeForNetworkUse = fileType == .mp4
        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let exportProgress) = state { progress(exportProgress.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: destination, as: fileType)
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

        try await run(session, to: destination, as: format.fileType, progress: progress)
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
