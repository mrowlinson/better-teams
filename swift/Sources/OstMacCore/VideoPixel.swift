// VideoPixel.swift — om-liveav: shared CVPixelBuffer -> CGImage convert.
// One copy used by the one-shot H264Decode and the live stream decoder.
import CoreGraphics
import CoreVideo
import Foundation

public enum VideoPixel {
    /// BGRA pixel buffer to CGImage. Nil when the buffer has no base address.
    public static func cgImage(from imageBuffer: CVImageBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(imageBuffer) else { return nil }
        let w = CVPixelBufferGetWidth(imageBuffer)
        let h = CVPixelBufferGetHeight(imageBuffer)
        let stride = CVPixelBufferGetBytesPerRow(imageBuffer)
        let data = Data(bytes: base, count: stride * h)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }
}
