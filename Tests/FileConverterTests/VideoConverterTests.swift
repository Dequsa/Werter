import AVFoundation
import ImageIO
import XCTest
@testable import FileConverter

final class VideoConverterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeMovie() async throws -> URL {
        try await TestMedia.movie(in: directory)
    }

    private func videoCodec(of url: URL) async throws -> FourCharCode {
        let track = try await XCTUnwrapAsync(await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let description = try await XCTUnwrapAsync(await track.load(.formatDescriptions).first)
        return CMFormatDescriptionGetMediaSubType(description)
    }

    private func XCTUnwrapAsync<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

    func testDetection() throws {
        let url = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }
        for name in ["a.mov", "a.mp4", "a.m4v", "a.avi", "a.3gp", "a.mts"] {
            XCTAssertEqual(MediaKind(url: url(name)), .video, name)
        }
        for name in ["a.mkv", "a.webm", "a.mp3", "a.txt"] {
            XCTAssertNil(MediaKind(url: url(name)), name)
        }
        XCTAssertEqual(MediaKind(url: url("a.gif")), .image) // GIFs get the photo wheel
        XCTAssertNil(MediaKind(urls: [url("a.mov"), url("a.jpg")]))  // mixed → no wheel
        XCTAssertEqual(MediaKind.batch(from: [url("a.txt"), url("a.mov"), url("a.jpg"), url("b.mp4")]),
                       [url("a.mov"), url("b.mp4")])
        XCTAssertEqual(WheelOption.current(of: url("a.mov")), .video(.mov))
        XCTAssertNil(WheelOption.current(of: url("a.mp4"))) // MP4 → H.264 MP4 is still useful
    }

    func testExportsToEveryCodec() async throws {
        let movie = try await makeMovie()
        let expected: [(VideoFormat, FourCharCode)] = [
            (.mp4, kCMVideoCodecType_H264),
            (.hevc, kCMVideoCodecType_HEVC),
            (.mov, kCMVideoCodecType_H264), // passthrough keeps the codec
            (.prores, kCMVideoCodecType_AppleProRes422),
        ]
        for (format, codec) in expected {
            let output = try await VideoConverter.convert(movie, to: format) { _ in }
            XCTAssertEqual(output.pathExtension, format.fileExtension, format.label)
            let actual = try await videoCodec(of: output)
            XCTAssertEqual(actual, codec, "\(format.label): got \(actual)")
        }
    }

    func testGIF() async throws {
        let movie = try await makeMovie()
        let lastProgress = LastValue()
        let gif = try await VideoConverter.convert(movie, to: .gif) { lastProgress.set($0) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        XCTAssertEqual(CGImageSourceGetCount(source), 12) // 1 s at 12 fps
        XCTAssertEqual(lastProgress.get(), 1)
    }

    func testAudioFromSilentClipFailsClearly() async throws {
        let movie = try await makeMovie()
        do {
            _ = try await VideoConverter.convert(movie, to: .m4a) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "clip.mov has no audio")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clip.m4a").path))
    }

    func testAudioExtraction() async throws {
        let movie = try await TestMedia.movie(in: directory, withAudio: true)
        let m4a = try await VideoConverter.convert(movie, to: .m4a) { _ in }
        let asset = AVURLAsset(url: m4a)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertTrue(videoTracks.isEmpty)
    }

    func testRunReportsProgressAndResults() async throws {
        let movie = try await makeMovie()
        let result = await Converter.run([movie], to: .video(.mp4)) { _ in }
        XCTAssertEqual(result.outputs.map(\.lastPathComponent), ["clip.mp4"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.cancelled)
    }

    func testCancellationStopsAndCleansUp() async throws {
        let movie = try await makeMovie()
        let task = Task { await Converter.run([movie, movie, movie], to: .video(.prores)) { _ in } }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["clip.mov"])
    }
}

private final class LastValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func set(_ newValue: Double) { lock.withLock { value = newValue } }
    func get() -> Double? { lock.withLock { value } }
}
