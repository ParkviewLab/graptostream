// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Draws graptostream's icon (sound turning into written lines) and writes
// brand/app-icon/AppIcon.iconset, from which iconutil makes AppIcon.icns.
// Run: swift scripts/make-icon.swift && iconutil -c icns brand/app-icon/AppIcon.iconset -o brand/app-icon/AppIcon.icns

import AppKit

func draw(size s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.22, blue: 0.52, alpha: 1),
                        NSColor(srgbRed: 0.27, green: 0.18, blue: 0.47, alpha: 1)])!.draw(in: shape, angle: -90)

    // Left: a waveform. Right: the same rhythm as lines of writing.
    let mid = s * 0.5
    let bars: [CGFloat] = [0.10, 0.22, 0.34, 0.18, 0.28, 0.12]
    let barWidth = s * 0.035
    NSColor(white: 1, alpha: 0.95).setFill()
    for (i, h) in bars.enumerated() {
        let x = tile.minX + s * 0.09 + CGFloat(i) * barWidth * 1.9
        let rect = NSRect(x: x, y: mid - s * h / 2, width: barWidth, height: s * h)
        NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    let lines: [CGFloat] = [0.22, 0.17, 0.20, 0.11]
    let lineHeight = s * 0.045
    for (i, w) in lines.enumerated() {
        let y = mid + s * 0.15 - CGFloat(i) * lineHeight * 2.2
        let rect = NSRect(x: tile.maxX - s * 0.09 - s * w, y: y - lineHeight / 2, width: s * w, height: lineHeight)
        NSBezierPath(roundedRect: rect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "brand/app-icon/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: dir.appendingPathComponent(name))
    }
}
print("wrote \(dir.path)")
