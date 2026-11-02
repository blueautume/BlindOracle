import SwiftUI

enum InkTheme {
    static let paper = Color(red: 0.963, green: 0.949, blue: 0.918)
    static let ink = Color(red: 0.17, green: 0.19, blue: 0.17)
    static let secondary = Color(red: 0.45, green: 0.46, blue: 0.41)
    static let cinnabar = Color(red: 0.61, green: 0.25, blue: 0.20)
    static let line = Color(red: 0.82, green: 0.80, blue: 0.74)
    static let sage = Color(red: 0.43, green: 0.49, blue: 0.41)
    static let wash = Color(red: 0.92, green: 0.92, blue: 0.87)
}

struct PaperBackground: View {
    var body: some View {
        InkTheme.paper.overlay {
            Canvas { context, size in
                for index in 0..<340 {
                    let x = CGFloat((index * 73 + 19) % 997) / 997 * size.width
                    let y = CGFloat((index * 127 + 41) % 991) / 991 * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(InkTheme.ink.opacity(0.035)))
                }
            }.allowsHitTesting(false)
        }.ignoresSafeArea()
    }
}

struct PaperCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(InkTheme.line.opacity(0.65), lineWidth: 0.7))
    }
}

struct SectionEyebrow: View {
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(InkTheme.cinnabar).frame(width: 3, height: 12)
            Text(text).font(.system(size: 12, weight: .medium)).tracking(2).foregroundStyle(InkTheme.secondary)
        }
    }
}

struct OracleMark: View {
    var size: CGFloat = 38
    var body: some View {
        Image("OraclePortrait").resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().stroke(InkTheme.line.opacity(0.7), lineWidth: 0.6))
            .accessibilityHidden(true)
    }
}

struct InkPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .medium, design: .serif))
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(InkTheme.paper)
            .background(InkTheme.ink.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct InkPill: View {
    var text: String
    var color: Color = InkTheme.sage
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.09), in: Capsule())
    }
}
