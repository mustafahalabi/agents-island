// Renders the Agents Island pixel-bot mascot to a 1024px PNG for the app icon.
// Usage: swift scripts/gen-icon.swift <output.png>
import AppKit

let sprite = """
.....+......
.....#......
..########..
..#OO##OO#..
..########..
..#======#..
..########..
.#.######.#.
.#..####..#.
....#..#....
...##..##...
"""

let grid = sprite.split(separator: "\n").map(Array.init)
let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Dark rounded-square background (macOS icon grid: ~82% with rounded corners).
let bgRect = NSRect(x: canvas * 0.09, y: canvas * 0.09, width: canvas * 0.82, height: canvas * 0.82)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: canvas * 0.185, yRadius: canvas * 0.185)
NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
bg.fill()

// Bot pixels, tinted "working" green.
let rows = grid.count
let cols = grid[0].count
let cell = (canvas * 0.56) / CGFloat(cols)
let gridWidth = cell * CGFloat(cols)
let gridHeight = cell * CGFloat(rows)
let originX = (canvas - gridWidth) / 2
let originY = (canvas - gridHeight) / 2
let tint = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.40, alpha: 1)

for (y, row) in grid.enumerated() {
    for (x, char) in row.enumerated() {
        let color: NSColor?
        switch char {
        case "#": color = tint
        case "O": color = .white
        case "=": color = NSColor.black.withAlphaComponent(0.6)
        case "+": color = .white
        default: color = nil
        }
        guard let color else { continue }
        color.setFill()
        let rect = NSRect(
            x: originX + CGFloat(x) * cell,
            y: originY + CGFloat(rows - 1 - y) * cell,
            width: cell + 0.5,
            height: cell + 0.5
        )
        NSBezierPath(rect: rect).fill()
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
