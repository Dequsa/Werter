import AVFoundation
import XCTest

/// Generates small media files for tests.
enum TestMedia {
    /// A 1-second, 30 fps H.264 QuickTime clip. Frames are solid `gray`, or brighten from black
    /// when nil; optionally rotated via `transform` and with a silent AAC track.
    static func movie(in directory: URL, name: String = "clip.mov", width: Int = 320, height: Int = 240,
                      gray: UInt8? = nil, transform: CGAffineTransform = .identity,
                      withAudio: Bool = false) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)

        var audio: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            ])
            writer.add(input)
            audio = input
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Audio first: one second of silence lets the writer interleave the video after it.
        if let audio {
            try await waitUntilReady(audio)
            XCTAssertTrue(audio.append(try silence(seconds: 1)))
            audio.markAsFinished()
        }

        for frame in 0..<30 {
            try await waitUntilReady(video)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(gray ?? UInt8(frame * 8)), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        video.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        for _ in 0..<400 where !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(input.isReadyForMoreMediaData, "writer input stalled")
    }

    private static func silence(seconds: Int) throws -> CMSampleBuffer {
        let frames = 44_100 * seconds
        var description = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 2,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: frames * 2, flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: try XCTUnwrap(block), offsetIntoDestination: 0,
                                   dataLength: frames * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: try XCTUnwrap(block), formatDescription: try XCTUnwrap(format),
            sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
