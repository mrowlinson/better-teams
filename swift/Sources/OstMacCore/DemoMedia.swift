// DemoMedia.swift — om-richmedia: offline `demo://` image fixtures.
//
// Programmatic PNGs (no binary blobs): seed 1 is a sunset, seed 2 a lake
// dawn. Deterministic pixels; unknown names throw (failure-state demo).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum DemoMedia {
    public static let photo1 = "demo://photo-1"
    public static let photo2 = "demo://photo-2"
    /// Full-res viewer variants (om-imgfull): same scene at 2×.
    public static let photo1Full = "demo://photo-1-full"
    public static let photo2Full = "demo://photo-2-full"
    /// Animated GIF fixture (om-gif-playback): 4-frame looping sunset,
    /// disc arcs left→right as the sky cools. No binary blobs, like PNGs.
    public static let gif1 = "demo://gif-1"
    public static let gif1Full = "demo://gif-1-full"
    /// Frame count of the GIF fixtures (probe/decode tests pin this).
    public static let gifFrameCount = 4
    /// Per-frame delay of the GIF fixtures, seconds.
    public static let gifFrameDelay = 0.25

    public static func data(for url: String) throws -> Data {
        switch url {
        case photo1: return render(seed: 1)
        case photo2: return render(seed: 2)
        case photo1Full: return render(seed: 1, width: 960, height: 640)
        case photo2Full: return render(seed: 2, width: 960, height: 640)
        case gif1: return renderGif()
        case gif1Full: return renderGif(width: 960, height: 640)
        default: throw MediaFetchError.failed("unknown demo media: \(url)")
        }
    }

    /// Programmatic animated GIF (no binary blob): the sunset scene
    /// with its disc arcing left→right and the sky cooling per frame,
    /// so every frame's pixels differ. Loops forever.
    static func renderGif(width: Int = 480, height: Int = 320) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        var frames: [CGImage] = []
        for i in 0 ..< gifFrameCount {
            let f = Double(i) / Double(gifFrameCount - 1) // 0…1 across the loop
            let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            let w = CGFloat(width), h = CGFloat(height)
            // Sky cools dusk→night across frames.
            let top = CGColor(
                red: 0.13 - 0.06 * f, green: 0.16 - 0.08 * f,
                blue: 0.38 - 0.10 * f, alpha: 1)
            let bottom = CGColor(
                red: 0.98 - 0.55 * f, green: 0.55 - 0.30 * f,
                blue: 0.30 + 0.10 * f, alpha: 1)
            let grad = CGGradient(
                colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(
                grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
            // Disc arcs left→right and sinks as it sets.
            ctx.setFillColor(CGColor(red: 1, green: 0.85 - 0.25 * f, blue: 0.55, alpha: 1))
            let dx = w * (0.15 + 0.55 * f)
            let dy = h * (0.58 - 0.22 * f)
            ctx.fillEllipse(in: CGRect(x: dx, y: dy, width: w * 0.14, height: w * 0.14))
            // Ground strip (constant anchor).
            ctx.setFillColor(CGColor(red: 0.12, green: 0.20, blue: 0.34, alpha: 0.92))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.22))
            frames.append(ctx.makeImage()!)
        }
        let out = CFDataCreateMutable(nil, 0)!
        let dest = CGImageDestinationCreateWithData(
            out, UTType.gif.identifier as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: gifFrameDelay],
        ] as CFDictionary
        for cg in frames { CGImageDestinationAddImage(dest, cg, frameProps) }
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func render(seed: Int, width: Int = 480, height: Int = 320) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let w = CGFloat(width), h = CGFloat(height)
        // Sky gradient (seed picks the palette).
        let top: CGColor = seed == 1
            ? CGColor(red: 0.13, green: 0.16, blue: 0.38, alpha: 1)
            : CGColor(red: 0.08, green: 0.23, blue: 0.42, alpha: 1)
        let bottom: CGColor = seed == 1
            ? CGColor(red: 0.98, green: 0.55, blue: 0.30, alpha: 1)
            : CGColor(red: 0.62, green: 0.86, blue: 0.95, alpha: 1)
        let grad = CGGradient(
            colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        // Sun / moon disc.
        ctx.setFillColor(seed == 1
            ? CGColor(red: 1, green: 0.85, blue: 0.55, alpha: 1)
            : CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.52, width: w * 0.16, height: w * 0.16))
        // Mountain silhouettes.
        ctx.setFillColor(CGColor(red: 0.16, green: 0.14, blue: 0.26, alpha: 1))
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: w * 0.28, y: h * 0.52))
        ctx.addLine(to: CGPoint(x: w * 0.55, y: 0))
        ctx.closePath()
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.20, alpha: 1))
        ctx.move(to: CGPoint(x: w * 0.38, y: 0))
        ctx.addLine(to: CGPoint(x: w * 0.70, y: h * 0.62))
        ctx.addLine(to: CGPoint(x: w, y: 0))
        ctx.closePath()
        ctx.fillPath()
        // Lake strip.
        ctx.setFillColor(CGColor(red: 0.12, green: 0.20, blue: 0.34, alpha: 0.92))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.22))
        let img = ctx.makeImage()!
        let out = CFDataCreateMutable(nil, 0)!
        let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
