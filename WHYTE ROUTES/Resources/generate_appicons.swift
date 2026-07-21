import Foundation
import AppKit

// Resolve the script directory so paths are stable regardless of working dir
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// Asset catalog path relative to this script file. Adjust if your layout differs.
// This points to: WHYTE ROUTES/Resources/Assets.xcassets/AppIcon.appiconset relative to script location.
let iconsetRelativePath = "WHYTE ROUTES/Resources/Assets.xcassets/AppIcon.appiconset"
let iconsetURL = URL(fileURLWithPath: iconsetRelativePath, relativeTo: scriptDir).standardized
let iconsetPath = iconsetURL.path

let icons: [(filename: String, width: Int, height: Int, idiom: String, size: String, scale: String)] = [
    // iPhone
    ("icon-20x20@2x.png", 40, 40, "iphone", "20x20", "2x"),
    ("icon-20x20@3x.png", 60, 60, "iphone", "20x20", "3x"),
    ("icon-29x29@2x.png", 58, 58, "iphone", "29x29", "2x"),
    ("icon-29x29@3x.png", 87, 87, "iphone", "29x29", "3x"),
    ("icon-40x40@2x.png", 80, 80, "iphone", "40x40", "2x"),
    ("icon-40x40@3x.png", 120, 120, "iphone", "40x40", "3x"),
    ("icon-60x60@2x.png", 120, 120, "iphone", "60x60", "2x"),
    ("icon-60x60@3x.png", 180, 180, "iphone", "60x60", "3x"),

    // iPad
    ("icon-20x20~ipad@1x.png", 20, 20, "ipad", "20x20", "1x"),
    ("icon-20x20~ipad@2x.png", 40, 40, "ipad", "20x20", "2x"),
    ("icon-29x29~ipad@1x.png", 29, 29, "ipad", "29x29", "1x"),
    ("icon-29x29~ipad@2x.png", 58, 58, "ipad", "29x29", "2x"),
    ("icon-40x40~ipad@1x.png", 40, 40, "ipad", "40x40", "1x"),
    ("icon-40x40~ipad@2x.png", 80, 80, "ipad", "40x40", "2x"),
    ("icon-76x76~ipad@1x.png", 76, 76, "ipad", "76x76", "1x"),
    ("icon-76x76~ipad@2x.png", 152, 152, "ipad", "76x76", "2x"),
    ("icon-83.5x83.5~ipad@2x.png", 167, 167, "ipad", "83.5x83.5", "2x"),

    // App Store (iOS marketing)
    ("icon-1024x1024@1x.png", 1024, 1024, "ios-marketing", "1024x1024", "1x")
]

let overwriteAll = false

func fileExists(_ path: String) -> Bool {
    return FileManager.default.fileExists(atPath: path)
}

func createPlaceholderPNG(width: Int, height: Int, path: String) {
    if fileExists(path) && !overwriteAll { return }
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(white: 0.75, alpha: 1.0).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    if let data = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: data),
       let pngData = rep.representation(using: .png, properties: [:]) {
        try? pngData.write(to: URL(fileURLWithPath: path))
        print("Created \(path)")
    } else {
        print("Failed to create \(path)")
    }
}

struct AppIconImage: Codable {
    let size: String
    let idiom: String
    let filename: String
    let scale: String
}

struct AppIconContents: Codable {
    let images: [AppIconImage]
    let info: Info

    struct Info: Codable { let version: Int; let author: String }
}

func writeContentsJSON(images: [AppIconImage], path: String) {
    let sorted = images.sorted { (a, b) -> Bool in
        if a.idiom != b.idiom { return a.idiom < b.idiom }
        if a.size != b.size { return a.size < b.size }
        return a.scale < b.scale
    }
    let contents = AppIconContents(images: sorted, info: .init(version: 1, author: "xcode"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(contents)
        try data.write(to: URL(fileURLWithPath: path))
        print("Wrote Contents.json")
    } catch {
        print("Failed to write Contents.json: \(error)")
    }
}

// Ensure the iconset path exists (create it if missing)
let fileManager = FileManager.default
if !fileManager.fileExists(atPath: iconsetPath) {
    do {
        try fileManager.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true, attributes: nil)
        print("Created missing AppIcon.appiconset at: \(iconsetPath)")
    } catch {
        print("ERROR: Failed to create AppIcon.appiconset at: \(iconsetPath): \(error)")
        exit(1)
    }
}

func cleanupUnassignedPNGs(in directory: String, keepFilenames: Set<String>) {
    do {
        let items = try FileManager.default.contentsOfDirectory(atPath: directory)
        for item in items where item.lowercased().hasSuffix(".png") {
            if !keepFilenames.contains(item) {
                let path = (directory as NSString).appendingPathComponent(item)
                try? FileManager.default.removeItem(atPath: path)
                print("Removed unassigned image: \(item)")
            } else {
                print("Keeping assigned image: \(item)")
            }
        }
    } catch {
        print("Failed to enumerate appiconset: \(error)")
    }
}

// Remove any leftover PNGs that are not part of our defined set
let keep = Set(icons.map { $0.filename })
cleanupUnassignedPNGs(in: iconsetPath, keepFilenames: keep)

var contentsImages: [AppIconImage] = []
for icon in icons {
    // Create placeholder only if missing or overwriteAll is true
    let filePath = "\(iconsetPath)/\(icon.filename)"
    createPlaceholderPNG(width: icon.width, height: icon.height, path: filePath)
    contentsImages.append(AppIconImage(size: icon.size, idiom: icon.idiom, filename: icon.filename, scale: icon.scale))
}

let contentsPath = "\(iconsetPath)/Contents.json"
writeContentsJSON(images: contentsImages, path: contentsPath)

