// make-icon.swift — draw the Better Teams chat-bubble icon (1024px PNG) to argv[1].
// Usage: swift scripts/make-icon.swift /tmp/icon-1024.png
import AppKit
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

guard CommandLine.arguments.count == 2 else { fail("usage: make-icon.swift OUT.png") }
let out = CommandLine.arguments[1]

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// Background: rounded square, teal -> blue gradient.
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S), xRadius: 230, yRadius: 230)
let grad = NSGradient(
    starting: NSColor(srgbRed: 0.06, green: 0.55, blue: 0.85, alpha: 1),
    ending: NSColor(srgbRed: 0.05, green: 0.30, blue: 0.68, alpha: 1))
grad?.draw(in: bg, angle: 90)

// White speech bubble + tail.
NSColor.white.setFill()
let bw: CGFloat = 640, bh: CGFloat = 440
let bx = (S - bw) / 2, by = (S - bh) / 2 + 60
NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: bh), xRadius: 110, yRadius: 110).fill()
let tail = NSBezierPath()
tail.move(to: NSPoint(x: bx + 150, y: by + 10))
tail.line(to: NSPoint(x: bx + 130, y: by - 150))
tail.line(to: NSPoint(x: bx + 300, y: by + 10))
tail.close()
tail.fill()

// Three typing dots.
NSColor(srgbRed: 0.05, green: 0.42, blue: 0.72, alpha: 1).setFill()
for i in 0 ..< 3 {
    let cx = S / 2 + CGFloat(i - 1) * 130
    let r: CGFloat = 52
    NSBezierPath(ovalIn: NSRect(x: cx - r, y: by + bh / 2 - r, width: r * 2, height: r * 2)).fill()
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fail("icon encode failed") }
do {
    try Data(png).write(to: URL(fileURLWithPath: out))
} catch {
    fail("icon write failed: \(error)")
}
print("wrote \(out)")
