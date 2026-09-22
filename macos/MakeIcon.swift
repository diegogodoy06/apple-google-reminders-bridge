import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: MakeIcon.swift output.png")
}

// Two overlapping leaves drawn only in black and white: a calendar outline
// and a reminder list, joined into one continuous mark.
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()

func stroke(_ points: [NSPoint], color: NSColor, width: CGFloat) {
    guard let first = points.first else { return }
    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = width
    path.move(to: first)
    for point in points.dropFirst() { path.line(to: point) }
    color.setStroke()
    path.stroke()
}

func outline(_ rect: NSRect, radius: CGFloat, color: NSColor, width: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

let black = NSColor(calibratedWhite: 0.055, alpha: 1)
let white = NSColor.white
let mutedWhite = NSColor(calibratedWhite: 1, alpha: 0.48)

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()

let tile = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 205, yRadius: 205)
black.setFill()
tile.fill()

// The second sheet is intentionally offset and quieter than the front leaf.
outline(NSRect(x: 274, y: 202, width: 552, height: 585), radius: 88, color: mutedWhite, width: 24)
outline(NSRect(x: 191, y: 247, width: 576, height: 585), radius: 88, color: white, width: 27)

// Calendar binding and header rule.
stroke([NSPoint(x: 340, y: 868), NSPoint(x: 340, y: 750)], color: white, width: 26)
stroke([NSPoint(x: 618, y: 868), NSPoint(x: 618, y: 750)], color: white, width: 26)
stroke([NSPoint(x: 205, y: 667), NSPoint(x: 753, y: 667)], color: white, width: 23)

// Reminder entries: the last one is still open.
for (index, y) in [560.0, 462.0, 364.0].enumerated() {
    let circle = NSBezierPath(ovalIn: NSRect(x: 266, y: y - 27, width: 54, height: 54))
    circle.lineWidth = 16
    white.setStroke()
    circle.stroke()
    if index < 2 {
        stroke(
            [NSPoint(x: 277, y: y), NSPoint(x: 289, y: y - 12), NSPoint(x: 314, y: y + 17)],
            color: white,
            width: 12
        )
    }
    stroke(
        [NSPoint(x: 370, y: y), NSPoint(x: index == 1 ? 632 : 674, y: y)],
        color: white,
        width: 18
    )
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("Unable to render icon") }

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
