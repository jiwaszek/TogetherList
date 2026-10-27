// Adds App Store captions to the raw simulator screenshots.
//   swift scripts/compose-screenshots.swift AppStore
// Reads  AppStore/screenshots/raw/<lang>/<device>/<n>-<name>.png
// Writes AppStore/screenshots/<lang>/<device>/<n>-<name>.png at the same pixel
// size (which is what App Store Connect expects for that device).
import AppKit

let captions: [String: [String: (String, String)]] = [
    "en": [
        "list": ("Your list, sorted by aisle", "Products are grouped automatically — in English and Polish."),
        "checkout": ("Check out and split the bill", "Tick what you bought, enter the total, choose who paid."),
        "balances": ("Always know who owes whom", "Settle up with a tap once the money is sent."),
        "invite": ("Invite with a QR code or AirDrop", "Or simply bring your iPhones together."),
        "history": ("Every shop, remembered", "Search what you bought and how much you spent."),
        "lists": ("Shared and private lists", "Changes sync instantly — and it works offline."),
    ],
    "pl": [
        "list": ("Lista ułożona według działów", "Produkty grupują się same — po polsku i po angielsku."),
        "checkout": ("Rozlicz zakupy i podziel koszty", "Zaznacz, co kupiono, wpisz kwotę i kto płacił."),
        "balances": ("Wiesz, kto komu ile oddaje", "Po przelewie lub BLIKU rozliczysz się jednym stuknięciem."),
        "invite": ("Zaproś kodem QR lub przez AirDrop", "Albo po prostu zbliż do siebie iPhone’y."),
        "history": ("Wszystkie zakupy w jednym miejscu", "Sprawdź, co kupiono i ile wydaliście."),
        "lists": ("Wspólne i prywatne listy", "Zmiany widać od razu u wszystkich — działa też offline."),
    ],
]

let green = NSColor(srgbRed: 0x22 / 255, green: 0x98 / 255, blue: 0x60 / 255, alpha: 1)
let darkGreen = NSColor(srgbRed: 0x17 / 255, green: 0x6E / 255, blue: 0x45 / 255, alpha: 1)

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

func compose(_ input: URL, _ output: URL, headline: String, subline: String) throws {
    guard let shot = NSImage(contentsOf: input),
          let rep = shot.representations.first else { throw CocoaError(.fileReadCorruptFile) }
    let W = CGFloat(rep.pixelsWide), H = CGFloat(rep.pixelsHigh)
    let isPad = W / H > 0.6

    let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    canvas.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    let ctx = NSGraphicsContext.current!.cgContext

    // Background
    NSGradient(starting: green, ending: darkGreen)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Text (AppKit's origin is bottom-left)
    let margin = W * (isPad ? 0.08 : 0.07)
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineBreakMode = .byWordWrapping
    let headAttrs: [NSAttributedString.Key: Any] = [
        .font: roundedFont(W * (isPad ? 0.052 : 0.074), .bold), .foregroundColor: NSColor.white, .paragraphStyle: para]
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: roundedFont(W * (isPad ? 0.027 : 0.038), .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        .paragraphStyle: para]
    let textWidth = W - margin * 2
    let head = NSAttributedString(string: headline, attributes: headAttrs)
    let sub = NSAttributedString(string: subline, attributes: subAttrs)
    let headSize = head.boundingRect(with: NSSize(width: textWidth, height: H), options: [.usesLineFragmentOrigin])
    let subSize = sub.boundingRect(with: NSSize(width: textWidth, height: H), options: [.usesLineFragmentOrigin])
    var top = H * (isPad ? 0.045 : 0.055)
    head.draw(with: NSRect(x: margin, y: H - top - headSize.height, width: textWidth, height: headSize.height),
              options: [.usesLineFragmentOrigin])
    top += headSize.height + H * 0.012
    sub.draw(with: NSRect(x: margin, y: H - top - subSize.height, width: textWidth, height: subSize.height),
             options: [.usesLineFragmentOrigin])
    top += subSize.height + H * (isPad ? 0.035 : 0.04)

    // Screenshot in a dark rounded "device" frame, running off the bottom edge.
    let scale: CGFloat = isPad ? 0.80 : 0.84
    let shotW = W * scale, shotH = H * scale
    let border = W * (isPad ? 0.012 : 0.022)
    let shotRect = NSRect(x: (W - shotW) / 2, y: H - top - shotH, width: shotW, height: shotH)
    let frameRect = shotRect.insetBy(dx: -border, dy: -border)
    let radius = shotW * (isPad ? 0.035 : 0.12)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -W * 0.01), blur: W * 0.04,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(white: 0.08, alpha: 1).setFill()
    NSBezierPath(roundedRect: frameRect, xRadius: radius + border, yRadius: radius + border).fill()
    ctx.restoreGState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: shotRect, xRadius: radius, yRadius: radius).addClip()
    shot.draw(in: shotRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()

    // App Store screenshots must not have an alpha channel.
    guard let cg = canvas.cgImage,
          let opaque = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    opaque.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    let png = NSBitmapImageRep(cgImage: opaque.makeImage()!).representation(using: .png, properties: [:])!
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output)
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppStore")
let raw = root.appendingPathComponent("screenshots/raw")
let fm = FileManager.default
for lang in (try fm.contentsOfDirectory(atPath: raw.path)).sorted() where captions[lang] != nil {
    for device in try fm.contentsOfDirectory(atPath: raw.appendingPathComponent(lang).path).sorted() where !device.hasPrefix(".") {
        let dir = raw.appendingPathComponent(lang).appendingPathComponent(device)
        for file in try fm.contentsOfDirectory(atPath: dir.path).sorted() where file.hasSuffix(".png") {
            let key = String(file.dropLast(4).split(separator: "-", maxSplits: 1).last ?? "")
            guard let (headline, subline) = captions[lang]?[key] else { continue }
            let out = root.appendingPathComponent("screenshots/\(lang)/\(device)/\(file)")
            try compose(dir.appendingPathComponent(file), out, headline: headline, subline: subline)
            print("  \(lang)/\(device)/\(file)")
        }
    }
}
