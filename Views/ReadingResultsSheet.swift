import SwiftUI

/// A reply's reference sheet is bound to that reply's run, never the latest run.
struct ReadingResultsSheet: View {
    let runID: UUID
    @EnvironmentObject private var store: OracleStore
    @Environment(\.dismiss) private var dismiss

    private var run: OracleRun? { store.runs.first { $0.id == runID } }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let run {
                            questionHeader(run)
                            if run.results.isEmpty {
                                PaperCard {
                                    Text("此次推演尚无方法返回结果。已填写的资料仍保存在本机。")
                                        .font(.system(size: 14, design: .serif))
                                        .foregroundStyle(InkTheme.secondary)
                                        .lineSpacing(5)
                                }
                            } else {
                                ForEach(run.results) { result in
                                    ReadingResultReferenceCard(result: result)
                                }
                            }
                        } else {
                            PaperCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("这份推演暂时无法读取。")
                                        .font(.system(size: 18, design: .serif))
                                        .foregroundStyle(InkTheme.ink)
                                    Text("当前页面只对应这条回复，不会用其他推演替代。")
                                        .font(.system(size: 12))
                                        .foregroundStyle(InkTheme.secondary)
                                }
                            }
                        }
                    }
                    .padding(22)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .accessibilityIdentifier("runResultsSheet")
            }
            .navigationTitle("此次推演")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 14))
                        .accessibilityIdentifier("closeRunResults")
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(InkTheme.cinnabar)
        .presentationDragIndicator(.visible)
    }

    private func questionHeader(_ run: OracleRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(text: "这次问事的直接结果")
            Text(run.input.question)
                .font(.system(size: 22, design: .serif))
                .foregroundStyle(InkTheme.ink)
                .lineSpacing(6)
                .textSelection(.enabled)
                .accessibilityIdentifier("runResultsQuestion")
            Text(castingTime(run))
                .font(.system(size: 11))
                .foregroundStyle(InkTheme.secondary)
            Text("仅列出此次使用方法的原始返回，按方法分别查看。")
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(InkTheme.secondary)
                .lineSpacing(4)
        }
    }

    private func castingTime(_ run: OracleRun) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = TimeZone(identifier: run.input.profile.currentTimeZoneID) ?? .gmt
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: run.input.castingDate) + " · " + run.input.profile.currentTimeZoneID
    }
}

/// The first rows are immediately readable; remaining data expands in place.
/// No intermediate method-detail navigation and no combined AI interpretation.
private struct ReadingResultReferenceCard: View {
    let result: OracleResult
    @State private var showRemainingRows = false
    @State private var showEvidence = false

    private let previewRowCount = 4
    private var statusTitle: String {
        switch result.status {
        case .complete: "已完成"
        case .partial: "部分结果"
        case .unavailable: "资料未定"
        case .failed: "未完成"
        }
    }

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: result.method.symbol)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(InkTheme.cinnabar)
                    Text(result.displayTitle)
                        .font(.system(size: 18, design: .serif))
                        .foregroundStyle(InkTheme.ink)
                    Spacer(minLength: 4)
                    InkPill(text: statusTitle, color: result.status == .complete ? InkTheme.sage : InkTheme.cinnabar)
                }
                Text(result.headline)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(InkTheme.ink)
                    .lineSpacing(5)
                    .textSelection(.enabled)

                if let draws = result.tarotDraws, !draws.isEmpty { TarotSpreadView(draws: draws) }

                if !result.rows.isEmpty {
                    Divider().overlay(InkTheme.line.opacity(0.6))
                    rows(Array(result.rows.prefix(previewRowCount)), startingAt: 0)
                    if result.rows.count > previewRowCount {
                        DisclosureGroup(isExpanded: $showRemainingRows) {
                            rows(Array(result.rows.dropFirst(previewRowCount)), startingAt: previewRowCount)
                                .padding(.top, 12)
                        } label: {
                            Text(showRemainingRows ? "收起其余原始数据" : "展开其余 \(result.rows.count - previewRowCount) 项原始数据")
                                .font(.system(size: 12))
                                .foregroundStyle(InkTheme.secondary)
                        }
                        .accessibilityIdentifier("expandRows-\(result.method.rawValue)")
                    }
                }

                if !result.evidence.isEmpty {
                    DisclosureGroup(isExpanded: $showEvidence) {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(InkTheme.cinnabar.opacity(0.65))
                                        .frame(width: 4, height: 4).padding(.top, 7)
                                    Text(evidence.statement)
                                        .font(.system(size: 13, design: .serif))
                                        .foregroundStyle(InkTheme.ink)
                                        .lineSpacing(5)
                                        .textSelection(.enabled)
                                }
                            }
                        }.padding(.top, 12)
                    } label: {
                        Text("规则线索 · \(result.evidence.count) 条")
                            .font(.system(size: 12))
                            .foregroundStyle(InkTheme.secondary)
                    }
                }

                if !result.limitations.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(result.limitations.enumerated()), id: \.offset) { _, limitation in
                            Text(limitation)
                                .font(.system(size: 11))
                                .foregroundStyle(InkTheme.secondary)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 2)
                }
                Text("版本 \(result.version) · \(String(format: "%.0f", result.durationMilliseconds)) ms · \(result.provenance)")
                    .font(.system(size: 10))
                    .foregroundStyle(InkTheme.secondary.opacity(0.85))
                    .lineSpacing(3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("result-\(result.method.rawValue)")
    }

    private func rows(_ values: [OracleRow], startingAt offset: Int) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(InkTheme.secondary)
                    Text(row.value)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(InkTheme.ink)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("resultRow-\(result.method.rawValue)-\(offset + index)")
            }
        }
    }
}
