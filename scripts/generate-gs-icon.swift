// Renders the PokeTokenBar_gs app icon from the egg pixel art (`assets/googlesave/egg.png`).
// Usage: swift scripts/generate-gs-icon.swift <egg.png> <output.png> <size>
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

// 3. Draw.
guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: out) else { exit(1) }
NSGraphicsContext.current = context
let cg = context.cgContext
cg.clear(CGRect(x: 0, y: 0, width: size, height: size))

let s = CGFloat(size) / 1024
let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
// Soft mint tile, slightly lighter at the top, with a thin darker rim.
cg.saveGState()
cg.addPath(tilePath); cg.clip()
let colors = [NSColor(srgbRed: 0.91, green: 0.97, blue: 0.93, alpha: 1).cgColor,
              NSColor(srgbRed: 0.78, green: 0.91, blue: 0.84, alpha: 1).cgColor] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
}
cg.restoreGState()
if size >= 64 {
    cg.addPath(tilePath)
    cg.setStrokeColor(NSColor(srgbRed: 0.18, green: 0.55, blue: 0.40, alpha: 0.35).cgColor)
    cg.setLineWidth(max(1, 6 * s))
    cg.strokePath()
}

// Egg: its painted cells (not the sprite's empty margin) fill ~68% of the tile, with an integer
// pixel size whenever a cell is at least two output pixels.
let painted = (0..<grid).flatMap { y in (0..<grid).compactMap { x in cells[y][x] == nil ? nil : (x, y) } }
let minX = painted.map(\.0).min()!, maxX = painted.map(\.0).max()!
let minY = painted.map(\.1).min()!, maxY = painted.map(\.1).max()!
let cols = maxX - minX + 1, rows = maxY - minY + 1
let raw = tile.width * 0.68 / CGFloat(max(cols, rows))
let cell = raw >= 2 ? floor(raw) : raw
let origin = CGPoint(x: (tile.midX - cell * CGFloat(cols) / 2).rounded(),
                     y: (tile.midY - cell * CGFloat(rows) / 2).rounded())
cg.setShouldAntialias(cell < 2)
for (x, y) in painted {
    cg.setFillColor(cells[y][x]!.cgColor)
    // Bitmap rows run top-down; Core Graphics runs bottom-up.
    cg.fill(CGRect(x: origin.x + CGFloat(x - minX) * cell, y: origin.y + CGFloat(maxY - y) * cell,
                   width: cell, height: cell))
}

NSGraphicsContext.current = nil
guard let png = out.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
