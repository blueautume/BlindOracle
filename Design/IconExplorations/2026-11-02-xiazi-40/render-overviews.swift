import AppKit
import Foundation
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let filenames = ["01.png", "02.png", "03.png", "04.png", "05.png", "06.png", "07.png", "08.png", "09.png", "10.png", "11.png", "12.png", "13.png", "14.png", "15.png", "16.png", "17.png", "18.png", "19.png", "20.png", "21.png", "22.png", "23.png", "24.png", "25.png", "26.png", "27.png", "28.png", "29.png", "30.png", "31.png", "32.png", "33.png", "34.png", "35.png", "36.png", "37.png", "38.png", "39.png", "40.png"]
let titles = ["都市夜行", "月下黑猫", "少年道士", "未来无眼者", "乌鸦占卜", "瞎子字标", "蒙眼达摩", "负空间之门", "赛博修女", "星海水母", "都市男巫", "洞穴蝾螈", "静听比丘尼", "触点星轨", "拼贴预言家", "折纸白狐", "琥珀水晶球", "沙漠星语", "无眼云团", "石雕之手", "街头塔罗师", "狐灵少女", "黑洞之门", "机甲禅僧", "闭眼夜枭", "数据神谕", "马赛克掌月", "蛙仙", "梦境面具", "彗星鲲", "蛇环占星", "故障少女", "金缮骨面", "星际问卜", "一笔未见", "白蝠听星", "漆海游鱼", "听风之耳", "CRT通灵机", "盲盒宇宙"]

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

func render(offset: Int, output: String) throws {
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
text("瞎子 · 40 种想象", x: 72, y: 57, font: NSFont(name: chineseMedium, size: 50) ?? .systemFont(ofSize: 50, weight: .medium), color: ink)
text(String(format: "%02d–%02d / 人物、非人、符号与未来想象", offset + 1, offset + 20), x: 75, y: 134, font: NSFont(name: chinese, size: 25) ?? .systemFont(ofSize: 25), color: muted)
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
for localIndex in 0..<20 {
    let index = offset + localIndex
    let column = localIndex % 4
    let row = localIndex / 4
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
try data.write(to: directory.appendingPathComponent(output))
}

try render(offset: 0, output: "xiazi-01-20.png")
try render(offset: 20, output: "xiazi-21-40.png")
let json = try JSONSerialization.data(withJSONObject: ["project": "瞎子", "generator": "Built-in ImageGen", "date": "2026-11-02", "count": 40, "icons": manifest], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: directory.appendingPathComponent("manifest.json"))
print("Rendered two 1496×2316 comparison sheets; validated 40 square originals and 40 prompt files.")
