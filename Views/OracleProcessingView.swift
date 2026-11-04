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
                VStack(alignment: .leading, spacing: 11) {
                    Button(action: toggleExpansion) {
                        HStack(spacing: 8) {
                            Text(summary(for: current)).font(.system(size: 10, weight: .medium)).tracking(1)
                            if completedCount > 0 {
                                Text(L10n.text("· 已完成 \(completedCount) 项", "· \(completedCount) complete")).font(.system(size: 10))
                            }
                            Spacer(minLength: 0)
                            Text(expanded ? L10n.text("收起", "Collapse") : L10n.text("展开", "Expand")).font(.system(size: 10))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }.foregroundStyle(InkTheme.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("progressHeaderToggle")
                    .accessibilityValue(expanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
                    HStack(alignment: .center, spacing: 10) {
                        statusMark(current.status).frame(width: 17, height: 17)
                            .onTapGesture(perform: toggleExpansion)
                        Button(action: toggleExpansion) {
                          HStack(alignment: .center, spacing: 10) {
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
                          }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("progressToggle")
                        .accessibilityValue(expanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
                        .accessibilityHint(expanded ? L10n.text("收起完整任务步骤", "Collapse all steps") : L10n.text("查看完整任务步骤", "Show all steps"))
                    }
                }

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

    private func toggleExpansion() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.toggle() }
        onExpansionChanged(expanded)
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
            Text(L10n.text("待确认", "Awaiting confirmation"))
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        if duration < 1 { return L10n.text("<1 秒", "<1 sec") }
        if duration < 60 { return L10n.text("\(Int(duration)) 秒", "\(Int(duration)) sec") }
        return L10n.text("\(Int(duration) / 60) 分 \(Int(duration) % 60) 秒", "\(Int(duration) / 60) min \(Int(duration) % 60) sec")
    }

    private func summary(for activity: OracleActivity) -> String {
        if isBusy { return L10n.text("正在处理", "Working") }
        return switch activity.status {
        case .waiting: L10n.text("等你继续", "Ready when you are")
        case .failed: L10n.text("暂未完成", "Couldn’t finish")
        case .cancelled: L10n.text("已停下", "Stopped")
        case .completed: L10n.text("已完成", "Complete")
        case .running: L10n.text("正在处理", "Working")
        }
    }

    private func statusTitle(_ status: OracleActivityStatus) -> String {
        switch status {
        case .running: L10n.text("进行中", "In progress")
        case .completed: L10n.text("已完成", "Complete")
        case .waiting: L10n.text("等待确认", "Awaiting confirmation")
        case .failed: L10n.text("未完成", "Incomplete")
        case .cancelled: L10n.text("已停止", "Stopped")
        }
    }

    @ViewBuilder private func statusMark(_ status: OracleActivityStatus) -> some View {
        if status == .running {
            // The spinner sits outside the task-title transition. Its native
            // animation continues while title text and elapsed time update.
            ProgressView().progressViewStyle(.circular).controlSize(.mini).tint(InkTheme.cinnabar)
                .accessibilityElement()
                .accessibilityLabel(L10n.text("进行中", "In progress")).accessibilityIdentifier("progressRunningIndicator")
        } else {
            let symbol: String = switch status {
            case .running: "circle.dotted"
            case .completed: "checkmark.circle.fill"
            case .waiting: "pause.circle"
            case .failed: "exclamationmark.circle"
            case .cancelled: "stop.circle"
            }
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
                .foregroundStyle(status == .completed ? InkTheme.sage : status == .failed ? InkTheme.cinnabar : InkTheme.secondary)
                .accessibilityLabel(statusTitle(status))
        }
    }
}
