// Generates the DMG window background (1x + 2x PNGs).
// Run from the repo root:  swift Support/make-dmg-background.swift
// Then combine:  tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out Support/dmg/background.tiff
import AppKit

let W: CGFloat = 660, H: CGFloat = 420

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

    // Soft vertical gradient, light and neutral.
    NSGradient(starting: NSColor(calibratedWhite: 0.985, alpha: 1),
               ending: NSColor(calibratedWhite: 0.945, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Wordmark, top center.
    let title = NSAttributedString(string: "SonoMac", attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
    ])
    let ts = title.size()
    title.draw(at: NSPoint(x: (W - ts.width) / 2, y: H - 64))

    let subtitle = NSAttributedString(string: "Drag to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
    ])
    let ss = subtitle.size()
    subtitle.draw(at: NSPoint(x: (W - ss.width) / 2, y: H - 86))

    // Arrow between the two icon positions (icons sit at Finder y=200, i.e. 220 from bottom).
    if let sym = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil),
       let configured = sym.withSymbolConfiguration(.init(pointSize: 34, weight: .medium)) {
        let size = configured.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        configured.draw(in: NSRect(origin: .zero, size: size))
        NSColor(calibratedWhite: 0.72, alpha: 1).set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: W / 2 - size.width / 2,
                               y: 220 - size.height / 2,
                               width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
try? fm.createDirectory(atPath: "build", withIntermediateDirectories: true)
try? fm.createDirectory(atPath: "Support/dmg", withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "build/dmg-bg.png"), (CGFloat(2), "build/dmg-bg@2x.png")] {
    let data = render(scale: scale).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: name))
}
print("backgrounds rendered")
