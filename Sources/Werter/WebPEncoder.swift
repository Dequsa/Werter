import Accelerate
import CoreGraphics
import libwebp

/// macOS can decode WebP but not encode it, so this goes through Google's libwebp.
/// Pixels are converted to sRGB since the file carries no color profile.
enum WebPEncoder {
    static let maxDimension = Int(WEBP_MAX_DIMENSION)

    static func encode(_ image: CGImage, quality: Double, lossless: Bool, name: String) throws -> Data {
        guard image.width <= maxDimension, image.height <= maxDimension else {
            throw ConversionError.tooLarge(name, limit: maxDimension)
        }
        // libwebp wants 8-bit RGBA with straight (non-premultiplied) alpha.
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        ), var buffer = try? vImage_Buffer(cgImage: image, format: format)
        else { throw ConversionError.unreadable(name) }
        defer { buffer.free() }

        let pixels = buffer.data.assumingMemoryBound(to: UInt8.self)
        let width = Int32(buffer.width), height = Int32(buffer.height), stride = Int32(buffer.rowBytes)
        var output: UnsafeMutablePointer<UInt8>?
        let size = lossless
            ? WebPEncodeLosslessRGBA(pixels, width, height, stride, &output)
            : WebPEncodeRGBA(pixels, width, height, stride, Float(quality * 100), &output)
        guard size > 0, let output else { throw ConversionError.unwritable(name) }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }
}
