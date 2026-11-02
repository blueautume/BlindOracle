import SwiftUI

/// Shows recorded application work. Only a new activity changes the current title.
struct OracleProcessingView: View {
    let activities: [OracleActivity]
    let isBusy: Bool
    var onExpansionChanged: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var current: OracleActivity? { activities.last }
    private var completedCount: Int { activities.filter { $0.status == .completed }.count }

    var body: some View {
        if let current {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.toggle() }
                    onExpansionChanged(expanded)
                } label: {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 8) {
                            Text(summary(for: current)).font(.system(size: 10, weight: .medium)).tracking(1)
                            if completedCount > 0 {
                                Text("· 已完成 \(completedCount) 项").font(.system(size: 10))
                            }
                            Spacer(minLength: 0)
                            Text(expanded ? "收起" : "展开").font(.system(size: 10))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }.foregroundStyle(InkTheme.secondary)
                        HStack(alignment: .center, spacing: 10) {
                            statusMark(current.status).frame(width: 17, height: 17)
                            ZStack(alignment: .leading) {
                                Text(current.text)
                                    .font(.system(size: 13, design: .serif)).foregroundStyle(InkTheme.ink)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(current.id)
                                    .transition(reduceMotion ? .identity : .asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
                                    .accessibilityIdentifier("progressCurrentTitle")
                            }
                            .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
                            .clipped()
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: current.id)
                            elapsed(for: current).font(.system(size: 10)).monospacedDigit().foregroundStyle(InkTheme.secondary)
                        }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("progressToggle")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .accessibilityHint(expanded ? "收起完整任务步骤" : "查看完整任务步骤")

                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        Divider().overlay(InkTheme.line).padding(.top, 16).padding(.bottom, 15)
                        ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                            step(activity, isLast: index == activities.count - 1)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("progressSteps")
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 14).padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InkTheme.wash, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(InkTheme.line.opacity(0.7), lineWidth: 0.6))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("oracleProcessing")
        }
    }

    private func step(_ activity: OracleActivity, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 7) {
                statusMark(activity.status).frame(width: 15, height: 18)
                if !isLast { Rectangle().fill(InkTheme.line).frame(width: 0.7).frame(minHeight: 22, maxHeight: .infinity) }
            }.frame(width: 17)
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.text).font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = activity.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 10)).lineSpacing(3).foregroundStyle(InkTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 7) {
                    Text(statusTitle(activity.status))
                    Text("·")
                    Text(activity.date, format: .dateTime.hour().minute().second())
                }.font(.system(size: 9)).monospacedDigit().foregroundStyle(InkTheme.secondary.opacity(0.85))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, isLast ? 0 : 17)
            elapsed(for: activity).font(.system(size: 10)).monospacedDigit().foregroundStyle(InkTheme.secondary)
                .padding(.top, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("progressStep-\(activity.id.uuidString)")
    }

    @ViewBuilder private func elapsed(for activity: OracleActivity) -> some View {
        if let duration = activity.duration {
            Text(durationText(duration))
        } else if activity.status == .running {
            TimelineView(.periodic(from: activity.date, by: 1)) { context in
                Text(durationText(max(0, context.date.timeIntervalSince(activity.date))))
            }
        } else if activity.status == .waiting {
            Text("待确认")
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        if duration < 1 { return "<1 秒" }
        if duration < 60 { return "\(Int(duration)) 秒" }
        return "\(Int(duration) / 60) 分 \(Int(duration) % 60) 秒"
    }

    private func summary(for activity: OracleActivity) -> String {
        if isBusy { return "正在处理" }
        return switch activity.status {
        case .waiting: "等你继续"
        case .failed: "暂未完成"
        case .cancelled: "已停下"
        case .completed: "已完成"
        case .running: "正在处理"
        }
    }

    private func statusTitle(_ status: OracleActivityStatus) -> String {
        switch status {
        case .running: "进行中"
        case .completed: "已完成"
        case .waiting: "等待确认"
        case .failed: "未完成"
        case .cancelled: "已停止"
        }
    }

    private func statusMark(_ status: OracleActivityStatus) -> some View {
        let symbol: String
        let color: Color
        switch status {
        case .running: symbol = "circle.dotted"; color = InkTheme.cinnabar
        case .completed: symbol = "checkmark.circle.fill"; color = InkTheme.sage
        case .waiting: symbol = "pause.circle"; color = InkTheme.secondary
        case .failed: symbol = "exclamationmark.circle"; color = InkTheme.cinnabar
        case .cancelled: symbol = "stop.circle"; color = InkTheme.secondary
        }
        return Image(systemName: symbol).font(.system(size: 13, weight: .regular)).foregroundStyle(color)
            .accessibilityLabel(statusTitle(status))
    }
}
