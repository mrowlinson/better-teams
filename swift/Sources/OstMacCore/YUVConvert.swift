// YUVConvert.swift — om-av: planar I420 -> BGRA CGImage (remote video display).
// Integer BT.601; inverse of the Rust bgra_to_i420 path. Pure + testable.
import CoreGraphics
import Foundation

public enum YUVConvert {
    /// Convert planar I420 (`w*h*3/2` bytes) to a BGRA CGImage. Nil on bad size.
    public static func cgImage(i420: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else { return nil }
        let ySize = width * height
        let uvSize = ySize / 4
        guard i420.count >= ySize + uvSize * 2 else { return nil }

        var bgra = Data(count: ySize * 4)
        i420.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            bgra.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let y = src.baseAddress!
                let u = y + ySize
                let v = u + uvSize
                let out = dst.baseAddress!
                for row in 0 ..< height {
                    for col in 0 ..< width {
                        let yy = Int(y.load(fromByteOffset: row * width + col, as: UInt8.self))
                        let uu = Int(u.load(
                            fromByteOffset: (row / 2) * (width / 2) + col / 2, as: UInt8.self)) - 128
                        let vv = Int(v.load(
                            fromByteOffset: (row / 2) * (width / 2) + col / 2, as: UInt8.self)) - 128
                        // BT.601 integer (256x): R=256Y+359V, G=256Y-88U-183V, B=256Y+454U
                        var r = (256 * yy + 359 * vv) >> 8
                        var g = (256 * yy - 88 * uu - 183 * vv) >> 8
                        var b = (256 * yy + 454 * uu) >> 8
                        r = min(255, max(0, r)); g = min(255, max(0, g)); b = min(255, max(0, b))
                        let o = (row * width + col) * 4
                        out.storeBytes(of: UInt8(b), toByteOffset: o, as: UInt8.self)
                        out.storeBytes(of: UInt8(g), toByteOffset: o + 1, as: UInt8.self)
                        out.storeBytes(of: UInt8(r), toByteOffset: o + 2, as: UInt8.self)
                        out.storeBytes(of: UInt8(255), toByteOffset: o + 3, as: UInt8.self)
                    }
                }
            }
        }

        let provider = CGDataProvider(data: bgra as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }

}
