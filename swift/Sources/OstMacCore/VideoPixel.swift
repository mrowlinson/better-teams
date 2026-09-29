// VideoPixel.swift — om-liveav: shared CVPixelBuffer -> CGImage convert.
// One path used by the one-shot H264Decode and the live stream decoder.
// HWACCEL: no pixel copy — the CGImage wraps the decoder's IOSurface
// buffer (retained + read-locked until the image is released).
import CoreGraphics
import CoreVideo
import Foundation

public enum VideoPixel {
    /// BGRA pixel buffer to CGImage. Nil when the buffer has no base address.
    public static func cgImage(from imageBuffer: CVImageBuffer) -> CGImage? {
        HWVideo.cgImage(wrapping: imageBuffer)
    }
}
