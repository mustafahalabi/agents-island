// Renders the install-window background for AgentsIsland.dmg.
// Usage: swift scripts/gen-dmg-background.swift <output.png>
// Window is 660x420 pt; we emit EXACTLY 1320x840 px (@2x) regardless of the
// screen's own scale, so Finder maps it 1:1 into the Retina window.
import AppKit

let ptW: CGFloat = 660, ptH: CGFloat = 420
let scale = 2
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(ptW) * scale, pixelsHigh: Int(ptH) * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: ptW, height: ptH)   // draw in points; context scales to px

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: subtle vertical gradient in the app's dark notch palette.
NSGradient(colors: [
    NSColor(calibratedWhite: 0.13, alpha: 1),
    NSColor(calibratedWhite: 0.06, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: ptW, height: ptH), angle: -90)

// Title + subtitle, centered along the top (coordinates are bottom-left origin).
func center(_ text: String, size: CGFloat, weight: NSFont.Weight, white: CGFloat, top: CGFloat) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: white, alpha: 1),
        .paragraphStyle: style,
    ]
    (text as NSString).draw(in: NSRect(x: 0, y: ptH - top - size * 1.3, width: ptW, height: size * 1.4),
                            withAttributes: attrs)
}
center("Agents Island", size: 30, weight: .bold, white: 1.0, top: 40)
center("Drag the app onto the Applications folder to install",
       size: 14, weight: .regular, white: 0.68, top: 82)

// Icons sit at y = 230 pt from the TOP (create-dmg places them there), i.e.
// y = 190 pt from the bottom. Draw a soft arrow spanning the gap between them.
let iconCenterY = ptH - 230
let arrow = NSBezierPath()
arrow.lineWidth = 3.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
let x0: CGFloat = 258, x1: CGFloat = 402
arrow.move(to: NSPoint(x: x0, y: iconCenterY))
arrow.line(to: NSPoint(x: x1, y: iconCenterY))
arrow.move(to: NSPoint(x: x1 - 13, y: iconCenterY + 10))
arrow.line(to: NSPoint(x: x1, y: iconCenterY))
arrow.line(to: NSPoint(x: x1 - 13, y: iconCenterY - 10))
NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.40, alpha: 0.8).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
let dims = "\(rep.pixelsWide)x\(rep.pixelsHigh)"
print("wrote \(CommandLine.arguments[1]) (\(dims) px)")
