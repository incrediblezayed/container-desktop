// Draws the Container Desktop app icon and writes AppIcon.appiconset.
// usage: swift Scripts/make-icon.swift ContainerDesktop/Assets.xcassets/AppIcon.appiconset
//
// Design: a teal macOS-grid plate (824pt squircle on a 1024 canvas) holding a frosted-glass
// app window. The window has a title bar and two container rows, each with a status light
// (green = running, amber = paused) and a neutral label bar. Sizes of 32px and below use a
// simplified, enlarged variant so the silhouette stays legible.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(size px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let small = px <= 32
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    // Flip so y grows downward, which makes the geometry below easier to read.
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)

    // Shadows ignore the CTM: offsets/blur are in device pixels with y pointing up.
    func shadow(dy: CGFloat, blur: CGFloat, _ color: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * s), blur: blur * s, color: color)
    }
    func linear(_ g: CGGradient, from a: CGPoint, to b: CGPoint) {
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // --- Plate: macOS icon grid, 824pt rounded square centred on a 1024 canvas. ---
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = rounded(plate, 185)
    ctx.saveGState()
    shadow(dy: 12, blur: 26, rgb(0x000000, 0.30))
    ctx.addPath(platePath); ctx.setFillColor(rgb(0x0B5A78)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath); ctx.clip()
    linear(gradient([(0, rgb(0x3ADBC8)), (0.5, rgb(0x0E97A8)), (1, rgb(0x0A4A7A))]),
           from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    // Soft light pooling in the top-left, and a darker falloff bottom-right.
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.30)), (1, rgb(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: 300, y: 190), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 190), endRadius: 560, options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0x062A4F, 0.35)), (1, rgb(0x062A4F, 0))]),
                           startCenter: CGPoint(x: 800, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 800, y: 900), endRadius: 520, options: [])
    ctx.restoreGState()
    // Inner rim light along the top edge of the plate.
    ctx.saveGState()
    ctx.addPath(platePath); ctx.clip()
    ctx.addPath(rounded(plate.insetBy(dx: 3, dy: 3), 182)); ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    linear(gradient([(0, rgb(0xFFFFFF, 0.45)), (0.35, rgb(0xFFFFFF, 0.06)), (1, rgb(0x000000, 0.12))]),
           from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    ctx.restoreGState()

    // --- Window geometry (enlarged a little at tiny sizes). ---
    let win = small ? CGRect(x: 186, y: 214, width: 652, height: 596)
                    : CGRect(x: 208, y: 240, width: 608, height: 544)
    let winR: CGFloat = small ? 96 : 92
    let barH: CGFloat = small ? 132 : 112
    let winPath = rounded(win, winR)

    // Window drop shadow.
    ctx.saveGState()
    ctx.addPath(platePath); ctx.clip()
    shadow(dy: 26, blur: 46, rgb(0x04243F, 0.45))
    ctx.addPath(winPath); ctx.setFillColor(rgb(0x0C6F8C, 0.55)); ctx.fillPath()
    ctx.restoreGState()

    // Frosted glass body.
    ctx.saveGState()
    ctx.addPath(winPath); ctx.clip()
    linear(gradient([(0, rgb(0xE9FFFB, 0.46)), (1, rgb(0xBFF3F0, 0.24))]),
           from: CGPoint(x: 512, y: win.minY), to: CGPoint(x: 512, y: win.maxY))
    // Title bar: a brighter band of glass.
    ctx.setFillColor(rgb(0xFFFFFF, small ? 0.42 : 0.34))
    ctx.fill(CGRect(x: win.minX, y: win.minY, width: win.width, height: barH))
    ctx.setFillColor(rgb(0x0A4A6A, 0.16))
    ctx.fill(CGRect(x: win.minX, y: win.minY + barH - 2, width: win.width, height: 4))
    // Glossy sheen sweeping across the top-left.
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.30)), (1, rgb(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: win.minX + 60, y: win.minY), startRadius: 0,
                           endCenter: CGPoint(x: win.minX + 60, y: win.minY), endRadius: 420, options: [])
    ctx.restoreGState()

    // Glass rim: bright at the top, fading out toward the bottom.
    ctx.saveGState()
    ctx.addPath(rounded(win.insetBy(dx: 2.5, dy: 2.5), winR - 2.5)); ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    linear(gradient([(0, rgb(0xFFFFFF, 0.95)), (0.5, rgb(0xFFFFFF, 0.35)), (1, rgb(0xFFFFFF, 0.18))]),
           from: CGPoint(x: win.minX, y: win.minY), to: CGPoint(x: win.maxX, y: win.maxY))
    ctx.restoreGState()

    // Title-bar controls: three neutral glass dots (omitted at tiny sizes).
    if !small {
        let cy = win.minY + barH / 2
        for i in 0..<3 {
            let c = CGPoint(x: win.minX + 74 + CGFloat(i) * 58, y: cy)
            ctx.setFillColor(rgb(0xFFFFFF, 0.92))
            ctx.fillEllipse(in: CGRect(x: c.x - 17, y: c.y - 17, width: 34, height: 34))
        }
    }

    // --- Container rows. ---
    let pad: CGFloat = small ? 34 : 36
    let bodyTop = win.minY + barH
    let rowH = (win.maxY - bodyTop - pad * 3) / 2
    let lights: [(UInt32, UInt32)] = [(0x5BE584, 0x16A34A), (0xFFD166, 0xF08C00)]
    for (i, light) in lights.enumerated() {
        let row = CGRect(x: win.minX + pad, y: bodyTop + pad + CGFloat(i) * (rowH + pad),
                         width: win.width - pad * 2, height: rowH)
        let rowPath = rounded(row, small ? 44 : 50)
        ctx.saveGState()
        shadow(dy: 10, blur: 20, rgb(0x053A5C, 0.35))
        ctx.addPath(rowPath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(rowPath); ctx.clip()
        linear(gradient([(0, rgb(0xFFFFFF)), (1, rgb(0xE3F4F6))]),
               from: CGPoint(x: 0, y: row.minY), to: CGPoint(x: 0, y: row.maxY))
        ctx.restoreGState()

        // Status light on the left.
        let dr: CGFloat = small ? rowH * 0.34 : rowH * 0.25
        let dc = CGPoint(x: row.minX + (small ? rowH * 0.56 : rowH * 0.52), y: row.midY)
        let dot = CGRect(x: dc.x - dr, y: dc.y - dr, width: dr * 2, height: dr * 2)
        ctx.saveGState()
        if !small { shadow(dy: 4, blur: 14, rgb(light.1, 0.55)) }
        ctx.addEllipse(in: dot); ctx.setFillColor(rgb(light.1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: dot); ctx.clip()
        ctx.drawRadialGradient(gradient([(0, rgb(light.0)), (1, rgb(light.1))]),
                               startCenter: CGPoint(x: dc.x - dr * 0.3, y: dc.y - dr * 0.4), startRadius: 0,
                               endCenter: dc, endRadius: dr * 1.15, options: [.drawsAfterEndLocation])
        ctx.restoreGState()

        // Neutral label bar standing in for the container name.
        let bh: CGFloat = small ? rowH * 0.30 : rowH * 0.20
        let bx = dc.x + dr + (small ? 40 : 44)
        let bw = (row.maxX - (small ? 44 : 56) - bx) * (i == 0 ? 1.0 : 0.66)
        ctx.addPath(rounded(CGRect(x: bx, y: row.midY - bh / 2, width: bw, height: bh), bh / 2))
        ctx.setFillColor(rgb(0x0B5F7E, small ? 0.42 : 0.30)); ctx.fillPath()
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try draw(size: pt * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(outDir.path)")
