import AppKit
import Foundation
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let filenames = ["01-ink-oracle.png", "02-cinnabar-seal.png", "03-jade-relief.png", "04-celadon-oracle.png", "05-black-gold-astrolabe.png", "06-cyber-oracle.png", "07-holographic-trigram.png", "08-pixel-sage.png", "09-bauhaus-fate.png", "10-swiss-minimal.png", "11-paper-cut.png", "12-woodcut-oracle.png", "13-cloisonne-star.png", "14-clay-sage.png", "15-monoline-moon.png", "16-ukiyoe-oracle.png", "17-art-nouveau.png", "18-liquid-chrome.png", "19-embroidered-sage.png", "20-gradient-oracle.png"]
let titles = ["水墨先知", "朱砂篆印", "青玉浮雕", "宋瓷先知", "黑金星盘", "赛博霓虹", "全息琉璃", "复古像素", "包豪斯", "瑞士极简", "层叠剪纸", "靛蓝木刻", "景泰蓝星盘", "温暖陶偶", "月弧线描", "浮世绘", "新艺术曲线", "液态铬", "丝线刺绣", "流体渐变"]

var images: [NSImage] = []
var manifest: [[String: Any]] = []
for (index, filename) in filenames.enumerated() {
    let fileURL = directory.appendingPathComponent(filename)
    guard let image = NSImage(contentsOf: fileURL), let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width == height else {
        fatalError("Missing, invalid or non-square image: \(filename)")
    }
    let id = String(format: "%02d", index + 1)
    let promptFile = "prompt-\(id).txt"
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(promptFile).path) else { fatalError("Missing prompt: \(promptFile)") }
    images.append(image)
    manifest.append(["id": id, "title": titles[index], "file": filename, "promptFile": promptFile, "width": width, "height": height])
}

let width = 1496, height = 2316
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
let rawContext = NSGraphicsContext(bitmapImageRep: bitmap)!
rawContext.cgContext.translateBy(x: 0, y: CGFloat(height))
rawContext.cgContext.scaleBy(x: 1, y: -1)
let context = NSGraphicsContext(cgContext: rawContext.cgContext, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let paper = NSColor(red: 0.965, green: 0.953, blue: 0.929, alpha: 1)
let ink = NSColor(red: 0.16, green: 0.19, blue: 0.17, alpha: 1)
let muted = NSColor(red: 0.44, green: 0.47, blue: 0.43, alpha: 1)
let cinnabar = NSColor(red: 0.62, green: 0.26, blue: 0.20, alpha: 1)
paper.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

func text(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
}
let chinese = "PingFangSC-Regular"
let chineseMedium = "PingFangSC-Medium"
text("盲眼先知 · 图标提案", x: 72, y: 57, font: NSFont(name: chineseMedium, size: 50) ?? .systemFont(ofSize: 50, weight: .medium), color: ink)
text("20 种风格 / 选择你喜欢的编号", x: 75, y: 134, font: NSFont(name: chinese, size: 25) ?? .systemFont(ofSize: 25), color: muted)
cinnabar.setFill()
NSRect(x: 72, y: 197, width: 48, height: 5).fill()
NSColor(red: 0.83, green: 0.82, blue: 0.77, alpha: 1).setStroke()
let line = NSBezierPath()
line.move(to: NSPoint(x: 136, y: 199))
line.line(to: NSPoint(x: 1424, y: 199))
line.lineWidth = 1
line.stroke()

let iconSize: CGFloat = 300
let gutter: CGFloat = 50.6666667
let rowHeight: CGFloat = 394
for index in 0..<20 {
    let column = index % 4
    let row = index / 4
    let x = 72 + CGFloat(column) * (iconSize + gutter)
    let y = 247 + CGFloat(row) * rowHeight
    let frame = NSRect(x: x, y: y, width: iconSize, height: iconSize)
    let rounded = NSBezierPath(roundedRect: frame, xRadius: 63, yRadius: 63)
    NSGraphicsContext.saveGraphicsState()
    rounded.addClip()
    images[index].draw(in: frame, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0.2, alpha: 0.09).setStroke()
    rounded.lineWidth = 1
    rounded.stroke()
    text(String(format: "%02d", index + 1), x: x + 1, y: y + 319, font: .monospacedDigitSystemFont(ofSize: 25, weight: .semibold), color: cinnabar)
    text(titles[index], x: x + 47, y: y + 316, font: NSFont(name: chineseMedium, size: 26) ?? .systemFont(ofSize: 26, weight: .medium), color: ink)
}

text("独立原图与提示词已保留 · 圆角仅用于此预览", x: 74, y: 2244, font: NSFont(name: chinese, size: 20) ?? .systemFont(ofSize: 20), color: muted)
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode PNG") }
try data.write(to: directory.appendingPathComponent("icon-overview.png"))
let json = try JSONSerialization.data(withJSONObject: ["project": "盲眼先知 · BlindOracle", "generator": "Built-in ImageGen", "date": "2026-11-02", "count": 20, "icons": manifest], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: directory.appendingPathComponent("manifest.json"))
print("Rendered icon-overview.png (\(width)×\(height)); validated 20 square originals and 20 prompt files.")
