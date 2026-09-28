import AVFoundation
import ImageIO
import XCTest
@testable import FileConverter

final class ActionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    /// Solid mid-grey image of the given size, written as `name` (format from the extension).
    private func makeImage(_ name: String, width: Int = 64, height: Int = 48,
                           properties: [CFString: Any] = [:]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let type = try XCTUnwrap(url.contentType).identifier
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func pixelSize(of url: URL) throws -> CGSize {
        let properties = try properties(of: url)
        return CGSize(width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                      height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private func videoSize(of url: URL) async throws -> CGSize {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        return try await XCTUnwrap(track).load(.naturalSize)
    }

    // MARK: Crop geometry

    func testCropRect() {
        let size = CGSize(width: 64, height: 48)
        XCTAssertEqual(AspectRatio.story.cropRect(in: size, focus: Saliency.center),
                       CGRect(x: 19, y: 0, width: 27, height: 48))
        // Focus near an edge slides the window over but never outside the image.
        XCTAssertEqual(AspectRatio.story.cropRect(in: size, focus: CGPoint(x: 1, y: 0.5)).minX, 37)
        XCTAssertEqual(AspectRatio.story.cropRect(in: size, focus: CGPoint(x: 0, y: 0.5)).minX, 0)
        XCTAssertEqual(AspectRatio.wide.cropRect(in: size, focus: Saliency.center).size, CGSize(width: 64, height: 36))
        XCTAssertEqual(AspectRatio.square.cropRect(in: CGSize(width: 320, height: 240), focus: Saliency.center),
                       CGRect(x: 40, y: 0, width: 240, height: 240))
        XCTAssertEqual(AspectRatio.story.cropRect(in: CGSize(width: 320, height: 240), focus: Saliency.center,
                                                  evenSides: true).size, CGSize(width: 134, height: 240))
    }

    // MARK: Photos

    func testPhotoCropsKeepFormatAndName() throws {
        let png = try makeImage("shot.png")
        let square = try PhotoProcessor.apply(.square, to: png)
        XCTAssertEqual(square.lastPathComponent, "cropped-shot.png")
        XCTAssertEqual(try pixelSize(of: square), CGSize(width: 48, height: 48))

        let story = try PhotoProcessor.apply(.story, to: png)
        XCTAssertEqual(story.lastPathComponent, "cropped-shot 2.png")
        XCTAssertEqual(try pixelSize(of: story), CGSize(width: 27, height: 48))
    }

    func testCropsTheUprightImage() throws {
        // Stored 64×48 but tagged "rotate 90°", so it displays as 48×64: a 16:9 crop must be wide.
        let jpeg = try makeImage("rotated.jpg", properties: [kCGImagePropertyOrientation: 6])
        let wide = try PhotoProcessor.apply(.wide, to: jpeg)
        XCTAssertEqual(try pixelSize(of: wide), CGSize(width: 48, height: 27))
        XCTAssertEqual(try properties(of: wide)[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    func testResize() throws {
        let png = try makeImage("big.png", width: 3000, height: 2000)
        let half = try PhotoProcessor.apply(.half, to: png)
        XCTAssertEqual(half.lastPathComponent, "resized-big.png")
        XCTAssertEqual(try pixelSize(of: half), CGSize(width: 1500, height: 1000))

        let fitted = try PhotoProcessor.apply(.fit2048, to: png)
        XCTAssertEqual(fitted.lastPathComponent, "resized-big 2.png")
        XCTAssertEqual(try pixelSize(of: fitted), CGSize(width: 2048, height: 1365))

        let small = try makeImage("small.png")
        XCTAssertThrowsError(try PhotoProcessor.apply(.fit2048, to: small)) { error in
            XCTAssertEqual(error.localizedDescription, "small.png is already 2048 px or smaller")
        }
    }

    func testStripInfoRemovesLocationButKeepsOrientation() throws {
        let jpeg = try makeImage("trip.jpg", properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.23, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 21.01, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
        ])
        XCTAssertNotNil(try properties(of: jpeg)[kCGImagePropertyGPSDictionary])

        let clean = try PhotoProcessor.apply(.stripInfo, to: jpeg)
        XCTAssertEqual(clean.lastPathComponent, "stripped-trip.jpg")
        let stripped = try properties(of: clean)
        XCTAssertNil(stripped[kCGImagePropertyGPSDictionary])
        XCTAssertNil((stripped[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel])
        XCTAssertNil((stripped[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertEqual(stripped[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(try pixelSize(of: clean), CGSize(width: 64, height: 48)) // untouched, not rotated
    }

    func testCutoutOnRealPhoto() throws {
        // A relative symlink into /System; copy the real file, not the link.
        let sample = URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic").resolvingSymlinksInPath()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sample.path), "sample photo not installed")
        let copy = directory.appendingPathComponent("Parrot.heic")
        try FileManager.default.copyItem(at: sample, to: copy)

        let cutout = try PhotoProcessor.apply(.cutout, to: copy)
        XCTAssertEqual(cutout.lastPathComponent, "cutout-Parrot.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(cutout as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue(image.hasAlpha)
        XCTAssertEqual(try pixelSize(of: cutout), try pixelSize(of: copy))
    }

    func testCutoutWithoutSubjectFailsClearly() throws {
        let flat = try makeImage("flat.png")
        XCTAssertThrowsError(try PhotoProcessor.apply(.cutout, to: flat)) { error in
            XCTAssertEqual(error.localizedDescription, "No subject found in flat.png")
        }
    }

    // MARK: Videos

    func testVideoCropUsesUprightFrame() async throws {
        // 320×240 stored, rotated 90° → displays 240×320. A 9:16 crop is 180×320, filled edge to edge.
        let rotate = CGAffineTransform(rotationAngle: .pi / 2)
        let movie = try await TestMedia.movie(in: directory, gray: 200, transform: rotate)
        let output = try await VideoProcessor.apply(.story, to: movie) { _ in }
        XCTAssertEqual(output.lastPathComponent, "cropped-clip.mov")
        let size = try await videoSize(of: output)
        XCTAssertEqual(size, CGSize(width: 180, height: 320))

        // A wrong transform would leave black bars; every corner should be the clip's grey.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let context = try XCTUnwrap(CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
                                              bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(2, 2), (frame.width - 3, 2), (2, frame.height - 3), (frame.width - 3, frame.height - 3)] {
            XCTAssertGreaterThan(pixels[(y * frame.width + x) * 4], 150, "corner \(x),\(y) is dark")
        }
    }

    func testMuteDropsAudioOnly() async throws {
        let movie = try await TestMedia.movie(in: directory, withAudio: true)
        let before = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        XCTAssertEqual(before.count, 1)

        let muted = try await VideoProcessor.apply(.mute, to: movie) { _ in }
        XCTAssertEqual(muted.lastPathComponent, "muted-clip.mov")
        let asset = AVURLAsset(url: muted)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertEqual(video.count, 1)
    }

    func testShrink() async throws {
        let movie = try await TestMedia.movie(in: directory, name: "hd.mov", width: 1920, height: 1080)
        let small = try await VideoProcessor.apply(.p720, to: movie) { _ in }
        XCTAssertEqual(small.lastPathComponent, "resized-hd.mp4")
        let size = try await videoSize(of: small)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))

        do {
            _ = try await VideoProcessor.apply(.p1080, to: movie) { _ in }
            XCTFail("1080p source shouldn't shrink to 1080p")
        } catch {
            XCTAssertEqual(error.localizedDescription, "hd.mov is already 1080p or smaller")
        }
    }

    func testGrabFrame() async throws {
        let movie = try await TestMedia.movie(in: directory)
        let frame = try await VideoProcessor.apply(.frame, to: movie) { _ in }
        XCTAssertEqual(frame.lastPathComponent, "frame-clip.jpg")
        XCTAssertEqual(try pixelSize(of: frame), CGSize(width: 320, height: 240))
    }

    // MARK: Wheel modes

    func testWheelModes() {
        XCTAssertEqual(MediaKind.image.options(for: .actions).count, 8)
        XCTAssertEqual(MediaKind.video.options(for: .actions).count, 8)
        XCTAssertEqual(MediaKind.image.options(for: .actions).first, .photoAction(.square))
        XCTAssertEqual(MediaKind.video.options(for: .actions).first, .videoAction(.story))
        XCTAssertEqual(WheelOption.videoAction(.story).summary, "Crop 9:16")
        XCTAssertEqual(WheelOption.image(.png).summary, "→ PNG")
    }
}
