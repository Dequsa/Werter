import CoreGraphics
import ImageIO
import XCTest
@testable import FileConverter

final class ConverterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 64×48 PNG, left half opaque red, right half fully transparent.
    private func makePNG(named name: String = "sample.png") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func load(_ url: URL) throws -> (type: String, image: CGImage) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source)) as String
        return (type, try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    func testConvertsToEveryFormat() throws {
        let png = try makePNG()
        XCTAssertEqual(ImageFormat(url: png), .png)
        for format in ImageFormat.allCases where format != .png {
            let output = try Converter.convert(png, to: format)
            XCTAssertEqual(output.pathExtension, format.fileExtension)
            XCTAssertEqual(ImageFormat(url: output), format)
            if format == .pdf { // ImageIO writes PDF but can't read it back
                let page = try XCTUnwrap(CGPDFDocument(output as CFURL)?.page(at: 1))
                XCTAssertEqual(page.getBoxRect(.mediaBox).size, CGSize(width: 64, height: 48))
                continue
            }
            let (type, image) = try load(output)
            XCTAssertEqual(type, format.type.identifier)
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 48)
        }
    }

    func testRoundTripBackToPNG() throws {
        let heic = try Converter.convert(try makePNG(), to: .heic)
        let png = try Converter.convert(heic, to: .png)
        XCTAssertEqual(png.lastPathComponent, "sample 2.png") // original sample.png is kept
        XCTAssertEqual(try load(png).type, "public.png")
    }

    func testJPEGFlattensTransparencyOnWhite() throws {
        let jpeg = try Converter.convert(try makePNG(), to: .jpeg)
        let image = try load(jpeg).image
        XCTAssertFalse(image.hasAlpha)

        // Sample the transparent (right) half: it should be white, not black.
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 48))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (24 * 64 + 56) * 4
        XCTAssertGreaterThan(pixels[offset], 240)
        XCTAssertGreaterThan(pixels[offset + 1], 240)
        XCTAssertGreaterThan(pixels[offset + 2], 240)
    }

    func testNeverOverwrites() throws {
        let png = try makePNG()
        let first = try Converter.convert(png, to: .jpeg)
        let second = try Converter.convert(png, to: .jpeg)
        XCTAssertEqual(first.lastPathComponent, "sample.jpg")
        XCTAssertEqual(second.lastPathComponent, "sample 2.jpg")
    }

    func testTIFFIsCompressed() throws {
        let tiff = try Converter.convert(try makePNG(), to: .tiff)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiffInfo = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiffInfo[kCGImagePropertyTIFFCompression] as? Int, 5)
    }

    /// Decodes to straight RGBA8 sRGB so pixels can be compared.
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    func testWebPFromPNGIsLosslessAndKeepsAlpha() throws {
        let png = try makePNG()
        let webp = try Converter.convert(png, to: .webp)
        let (type, image) = try load(webp)
        XCTAssertEqual(type, "org.webmproject.webp")
        XCTAssertTrue(image.hasAlpha)
        XCTAssertEqual(try rgba(image), try rgba(load(png).image))
    }

    func testWebPBakesInOrientation() throws {
        // A 64×48 JPEG tagged "rotate 90° CW" displays as 48×64.
        let jpeg = directory.appendingPathComponent("rotated.jpg")
        let source = try load(makePNG()).image
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let image = try load(Converter.convert(jpeg, to: .webp)).image
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 64)
    }

    func testInputDetection() {
        let url = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }
        for name in ["a.png", "a.jpg", "a.heic", "a.HEIF", "a.webp", "a.dng", "a.cr2", "a.nef", "a.arw", "a.raf", "a.avif", "a.tif", "a.gif"] {
            XCTAssertTrue(ImageFormat.canConvert(from: url(name)), name)
        }
        for name in ["a.pdf", "a.txt", "a.mov", "a.docx"] {
            XCTAssertFalse(ImageFormat.canConvert(from: url(name)), name)
        }
        XCTAssertNil(ImageFormat(url: url("a.dng")))   // RAW is input-only
        XCTAssertEqual(ImageFormat(url: url("a.tif")), .tiff)
        XCTAssertTrue(url("a.CR3").isRawImage)
    }

    func testWheelHitTesting() {
        let geometry = WheelGeometry(count: ImageFormat.allCases.count)
        let bounds = CGRect(x: 0, y: 0, width: WheelGeometry.canvas, height: WheelGeometry.canvas)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let at = { (dx: CGFloat, dy: CGFloat) in geometry.index(at: CGPoint(x: c.x + dx, y: c.y + dy), in: bounds) }
        XCTAssertNil(at(0, 0))            // centre = cancel
        XCTAssertEqual(at(0, -100), 0)    // top → JPG
        XCTAssertEqual(at(100, 0), 2)     // right → WEBP
        XCTAssertEqual(at(0, 100), 5)     // bottom → TIFF
        XCTAssertEqual(at(-100, 0), 7)    // left → BMP
        XCTAssertEqual(at(-70, -70), 8)   // top-left → PDF
    }
}
