import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: MakeIcon.swift output.png")
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.24)
shadow.shadowBlurRadius = 44
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()

let tile = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 205, yRadius: 205)
NSColor(calibratedRed: 0.094, green: 0.129, blue: 0.169, alpha: 1).setFill()
tile.fill()

NSGraphicsContext.current?.saveGraphicsState()
let accent = NSBezierPath(roundedRect: NSRect(x: 188, y: 205, width: 648, height: 614), xRadius: 150, yRadius: 150)
NSColor(calibratedRed: 0.075, green: 0.475, blue: 0.357, alpha: 1).setFill()
accent.fill()
NSGraphicsContext.current?.restoreGraphicsState()

let sizeConfig = NSImage.SymbolConfiguration(pointSize: 345, weight: .semibold)
let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
let config = sizeConfig.applying(colorConfig)
if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    symbol.draw(
        in: NSRect(x: 275, y: 340, width: 474, height: 344),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: nil
    )
}

image.unlockFocus()
guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("Unable to render icon") }

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
