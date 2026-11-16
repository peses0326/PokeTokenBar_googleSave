// Renders the PokeTokenBar_gs app icon from the egg pixel art (`assets/googlesave/egg.png`).
// Usage: swift scripts/generate-gs-icon.swift <egg.png> <output.png|output.svg> <size>
//
// egg.png is a 24×24 sprite upscaled 5× on a white background. Each output size is drawn from
// the 24×24 grid with nearest-neighbour scaling (integer factors where they fit), cropped to the painted cells, so the pixels
// stay crisp, on a rounded-square tile that follows the macOS icon grid (824/1024 tile, 100 inset).
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), size > 0 else {
    FileHandle.standardError.write("usage: generate-gs-icon.swift <egg.png> <output.png> <size>\n".data(using: .utf8)!)
    exit(2)
}
guard let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[1]))) else { exit(1) }

// 1. Recover the native grid: sample the centre of each block.
let grid = 24
let block = source.pixelsWide / grid
precondition(block * grid == source.pixelsWide && source.pixelsWide == source.pixelsHigh, "expected a square 24-cell sprite")
var cells = [[NSColor?]](repeating: [NSColor?](repeating: nil, count: grid), count: grid)
for y in 0..<grid { for x in 0..<grid {
    cells[y][x] = source.colorAt(x: x * block + block / 2, y: y * block + block / 2)?.usingColorSpace(.sRGB)
} }

// 2. The white background connected to the border becomes transparent (the cream shell stays).
func isBackground(_ c: NSColor?) -> Bool {
    guard let c else { return true }
    return c.redComponent > 0.99 && c.greenComponent > 0.99 && c.blueComponent > 0.99
}
var stack = (0..<grid).flatMap { [(0, $0), (grid - 1, $0), ($0, 0), ($0, grid - 1)] }
var cleared = Set<Int>()
while let (x, y) = stack.popLast() {
    guard (0..<grid).contains(x), (0..<grid).contains(y), !cleared.contains(y * grid + x), isBackground(cells[y][x]) else { continue }
    cleared.insert(y * grid + x)
    cells[y][x] = nil
    stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
}

// SVG output (`icon.svg`): the large layout as vector rects, so it scales without blur.
if args[2].hasSuffix(".svg") {
    func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
               Int((c.blueComponent * 255).rounded()))
    }
    let painted = (0..<grid).flatMap { y in (0..<grid).compactMap { x in cells[y][x] == nil ? nil : (x, y) } }
    let minX = painted.map(\.0).min()!, maxX = painted.map(\.0).max()!
    let minY = painted.map(\.1).min()!, maxY = painted.map(\.1).max()!
    let cols = maxX - minX + 1, rows = maxY - minY + 1
    let cell = floor(824 * 0.68 / Double(max(cols, rows)))
    let ox = (512 - cell * Double(cols) / 2).rounded(), oy = (512 - cell * Double(rows) / 2).rounded()
    var body = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" shape-rendering="crispEdges">
      <defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E8F7ED"/><stop offset="1" stop-color="#C7E8D6"/></linearGradient></defs>
      <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)" stroke="#2E8C66" stroke-opacity="0.35" stroke-width="6" shape-rendering="geometricPrecision"/>

    """
    for (x, y) in painted {
        body += "  <rect x=\"\(Int(ox + Double(x - minX) * cell))\" y=\"\(Int(oy + Double(y - minY) * cell))\" width=\"\(Int(cell))\" height=\"\(Int(cell))\" fill=\"\(hex(cells[y][x]!))\"/>\n"
    }
    body += "</svg>\n"
    try body.write(toFile: args[2], atomically: true, encoding: .utf8)
    exit(0)
}

// 3. Draw.
guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: out) else { exit(1) }
NSGraphicsContext.current = context
let cg = context.cgContext
cg.clear(CGRect(x: 0, y: 0, width: size, height: size))

let s = CGFloat(size) / 1024
// List-sized icons (Activity Monitor, Finder lists, menus: 16–64 px) get their own layout: the
// macOS grid's 10% inset and the pale tile wash the egg out at that size, so the tile nearly fills
// the canvas, the mint is deeper and the egg takes more of it.
let small = size <= 64
let tile = small
    ? CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: max(1, CGFloat(size) * 0.04), dy: max(1, CGFloat(size) * 0.04))
    : CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let corner = small ? tile.width * 0.22 : 185 * s
let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
// Mint tile, slightly lighter at the top, with a thin darker rim.
cg.saveGState()
cg.addPath(tilePath); cg.clip()
let top = small ? NSColor(srgbRed: 0.80, green: 0.93, blue: 0.86, alpha: 1) : NSColor(srgbRed: 0.91, green: 0.97, blue: 0.93, alpha: 1)
let bottom = small ? NSColor(srgbRed: 0.56, green: 0.82, blue: 0.69, alpha: 1) : NSColor(srgbRed: 0.78, green: 0.91, blue: 0.84, alpha: 1)
if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
}
cg.restoreGState()
if size >= 32 {
    cg.addPath(tilePath)
    cg.setStrokeColor(NSColor(srgbRed: 0.18, green: 0.55, blue: 0.40, alpha: small ? 0.6 : 0.35).cgColor)
    cg.setLineWidth(small ? 1 : max(1, 6 * s))
    cg.strokePath()
}

// Egg: its painted cells (not the sprite's empty margin) fill ~68% of the tile (86% when small).
// A cell of at least one output pixel is drawn at an integer size, so every pixel stays sharp;
// below that (16 px) the egg is drawn once at one pixel per cell and scaled down smoothly.
let painted = (0..<grid).flatMap { y in (0..<grid).compactMap { x in cells[y][x] == nil ? nil : (x, y) } }
let minX = painted.map(\.0).min()!, maxX = painted.map(\.0).max()!
let minY = painted.map(\.1).min()!, maxY = painted.map(\.1).max()!
let cols = maxX - minX + 1, rows = maxY - minY + 1
let raw = tile.width * (small ? 0.86 : 0.68) / CGFloat(max(cols, rows))
let cell = raw >= 1 ? floor(raw) : raw

func drawEgg(in context: CGContext, origin: CGPoint, cell: CGFloat) {
    context.setShouldAntialias(false)
    for (x, y) in painted {
        context.setFillColor(cells[y][x]!.cgColor)
        // Bitmap rows run top-down; Core Graphics runs bottom-up.
        context.fill(CGRect(x: origin.x + CGFloat(x - minX) * cell, y: origin.y + CGFloat(maxY - y) * cell,
                            width: cell, height: cell))
    }
}
let eggSize = CGSize(width: cell * CGFloat(cols), height: cell * CGFloat(rows))
let origin = CGPoint(x: (tile.midX - eggSize.width / 2).rounded(), y: (tile.midY - eggSize.height / 2).rounded())
if raw >= 1 {
    drawEgg(in: cg, origin: origin, cell: cell)
} else if let sprite = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
    drawEgg(in: sprite, origin: .zero, cell: 1)
    if let image = sprite.makeImage() {
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(origin: origin, size: eggSize))
    }
}

NSGraphicsContext.current = nil
guard let png = out.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
