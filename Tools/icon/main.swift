import AppKit

// Cuecard app icon: a cream index card, tilted a little, on a dark squircle. A red header rule and faint ruled
// lines, with one line lit amber: the cue. A second card peeks out behind it. Usage: make-icon <output.iconset>
let output = CommandLine.arguments.dropFirst().first ?? "Cuecard.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
                               (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"),
                               (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let small = px <= 32
    let inset = s * 0.09
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [rgb(0.18, 0.16, 0.15), rgb(0.08, 0.07, 0.07)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    let card = CGRect(x: -s * 0.3, y: -s * 0.2, width: s * 0.6, height: s * 0.4)
    let radius = s * 0.035

    // The card behind: rotated the other way, darker, only its edge shows.
    ctx.saveGState()
    ctx.translateBy(x: s * 0.54, y: s * 0.53)
    ctx.rotate(by: 0.16)
    ctx.setFillColor(rgb(0.55, 0.5, 0.44))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // The front card.
    ctx.saveGState()
    ctx.translateBy(x: s * 0.49, y: s * 0.47)
    ctx.rotate(by: -0.1)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.04, color: rgb(0, 0, 0, 0.45))
    ctx.setFillColor(rgb(0.98, 0.95, 0.88))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)

    let left = card.minX + s * 0.05, right = card.maxX - s * 0.05
    // Red header rule, as on a real index card.
    let header = card.maxY - s * 0.085
    ctx.setFillColor(rgb(0.86, 0.33, 0.3))
    ctx.fill(CGRect(x: card.minX, y: header, width: card.width, height: max(1, s * (small ? 0.02 : 0.012))))
    // Ruled lines, one of them lit: the cue.
    let rows: [(y: CGFloat, width: CGFloat, cue: Bool)] = [(header - s * 0.075, 0.55, false), (header - s * 0.155, 0.9, true),
                                                            (header - s * 0.235, 0.7, false)]
    for row in rows {
        let length = (right - left) * row.width
        let height = s * (row.cue ? 0.05 : (small ? 0.03 : 0.022))
        let bar = CGRect(x: left, y: row.y - height / 2, width: length, height: height)
        ctx.setFillColor(row.cue ? rgb(0.97, 0.69, 0.25) : rgb(0.36, 0.52, 0.72, small ? 0.8 : 0.55))
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}
for (px, name) in sizes { try? render(px)?.write(to: URL(fileURLWithPath: "\(output)/\(name)")) }
