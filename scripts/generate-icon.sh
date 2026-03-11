#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/assets"
ICONSET_DIR="$ASSETS_DIR/AppIcon.iconset"
OUTPUT_ICNS="$ASSETS_DIR/AppIcon.icns"
BASE_PNG="$ASSETS_DIR/AppIcon-1024.png"

mkdir -p "$ASSETS_DIR" "$ICONSET_DIR"

swift -e '
import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.24, alpha: 1.0).setFill()
NSBezierPath(roundedRect: rect, xRadius: 224, yRadius: 224).fill()

let insetRect = rect.insetBy(dx: 112, dy: 112)
NSColor(calibratedRed: 0.34, green: 0.66, blue: 0.98, alpha: 1.0).setFill()
NSBezierPath(roundedRect: insetRect, xRadius: 160, yRadius: 160).fill()

let stripeRect = NSRect(x: 224, y: 470, width: 576, height: 84)
NSColor.white.withAlphaComponent(0.92).setFill()
NSBezierPath(roundedRect: stripeRect, xRadius: 42, yRadius: 42).fill()

let stemRect = NSRect(x: 470, y: 240, width: 84, height: 544)
NSColor.white.withAlphaComponent(0.92).setFill()
NSBezierPath(roundedRect: stemRect, xRadius: 42, yRadius: 42).fill()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("Failed to generate PNG icon data.")
}

let outputPath = CommandLine.arguments[1]
try png.write(to: URL(fileURLWithPath: outputPath))
' "$BASE_PNG"

cp "$BASE_PNG" "$ICONSET_DIR/icon_512x512@2x.png"
sips -z 512 512   "$BASE_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 256 256   "$BASE_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
cp "$ICONSET_DIR/icon_512x512.png" "$ICONSET_DIR/icon_256x256@2x.png"
sips -z 128 128   "$BASE_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
cp "$ICONSET_DIR/icon_256x256.png" "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 64 64     "$BASE_PNG" --out "$ICONSET_DIR/icon_64x64.png" >/dev/null
cp "$ICONSET_DIR/icon_128x128.png" "$ICONSET_DIR/icon_64x64@2x.png"
sips -z 32 32     "$BASE_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
cp "$ICONSET_DIR/icon_64x64.png" "$ICONSET_DIR/icon_32x32@2x.png"
sips -z 16 16     "$BASE_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
cp "$ICONSET_DIR/icon_32x32.png" "$ICONSET_DIR/icon_16x16@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

echo "Generated icon: $OUTPUT_ICNS"
