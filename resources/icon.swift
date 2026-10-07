// Génère AppIcon.icns à partir de la mascotte pixel art.
// À relancer seulement si tu changes le dessin dans src/main.swift :
//
//   swiftc -O -o /tmp/icongen resources/icon.swift && /tmp/icongen /tmp/icon.png
//   rm -rf /tmp/i.iconset && mkdir /tmp/i.iconset
//   for s in 16 32 128 256 512; do
//     sips -z $s $s /tmp/icon.png --out /tmp/i.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) /tmp/icon.png --out /tmp/i.iconset/icon_${s}x${s}@2x.png
//   done
//   iconutil -c icns /tmp/i.iconset -o resources/AppIcon.icns

import AppKit

let art = ["...#####...", "..#######..", ".#########.", ".##.###.##.",
           ".##.###.##.", ".#########.", ".#########.", ".#.#.#.#.#.", "#..#...#..#"]

let side: CGFloat = 1024
let img = NSImage(size: NSSize(width: side, height: side))
img.lockFocus()

NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.12, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
             xRadius: side * 0.22, yRadius: side * 0.22).fill()

let cols: CGFloat = 11, rows: CGFloat = 9
let u = side * 0.62 / cols
let ox = (side - cols * u) / 2, oy = (side - rows * u) / 2

NSColor(calibratedRed: 0.94, green: 0.45, blue: 0.16, alpha: 1).setFill()
for (y, line) in art.enumerated() {
    for (x, ch) in line.enumerated() where ch == "#" {
        // repère AppKit : origine en bas à gauche, on inverse donc y
        NSRect(x: ox + CGFloat(x) * u,
               y: oy + (rows - 1 - CGFloat(y)) * u,
               width: u, height: u).fill()
    }
}
img.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✅ \(out)")
