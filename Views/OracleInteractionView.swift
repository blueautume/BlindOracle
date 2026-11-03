import SwiftUI
import UIKit

/// A local, resumable step between confirming the question and interpreting its result.
struct OracleInteractionView: View {
    let session: OracleInteractionSession
    let onProgress: (OracleInteractionResponse) -> Void
    let onComplete: (OracleInteractionResponse) -> Void
    let onCancelClarification: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var response: OracleInteractionResponse
    @State private var hasShuffled: Bool
    @State private var isShuffling = false
    @State private var shuffleTurns = 0
    @State private var tossing = false
    @State private var coinTurns = 0
    @State private var flipping = false
    @State private var isCompleting = false

    private var isYarrow: Bool { session.input.castingStyle?.lowercased() == "yarrow" }
    private var clarificationNumber: Int { (session.input.tarotClarificationRounds?.count ?? 0) + 1 }
    private var navigationTitle: String {
        guard let request = session.currentRequest else { return "留一份心意" }
        if request.tarotClarification != nil { return "第\(clarificationNumber)次补牌" }
        if request.kind == .coins, isYarrow { return "蓍草成卦" }
        return request.title
    }

    init(session: OracleInteractionSession,
         onProgress: @escaping (OracleInteractionResponse) -> Void,
         onComplete: @escaping (OracleInteractionResponse) -> Void,
         onCancelClarification: (() -> Void)? = nil) {
        self.session = session
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onCancelClarification = onCancelClarification
        let requestID = session.currentRequest?.id ?? ""
        let restored = session.draft.flatMap { session.isValid($0, complete: false) ? $0 : nil }
            ?? OracleInteractionResponse(requestID: requestID)
        _response = State(initialValue: restored)
        _hasShuffled = State(initialValue: !restored.tarotDraws.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                if let request = session.currentRequest {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            heading(request)
                            switch request.kind {
                            case .numbers: numberSelection
                            case .coins: coinCasting
                            case .tarot: tarotReading(request)
                            }
                        }
                        .frame(maxWidth: 650)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { footer(for: request) }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.currentRequest?.tarotClarification != nil, response.revealedCount == 0, let onCancelClarification {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消补牌", role: .cancel, action: onCancelClarification)
                            .font(.system(size: 13)).foregroundStyle(InkTheme.secondary)
                            .accessibilityIdentifier("cancelTarotClarification")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后继续") { dismiss() }
                        .font(.system(size: 13)).foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("deferInteraction")
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(InkTheme.cinnabar)
        .onAppear {
            if session.currentRequest?.kind == .numbers, response.numbers.count != 3 {
                updateResponse { $0.numbers = [1, 1, 1] }
            }
        }
        .sensoryFeedback(.selection, trigger: response.numbers)
        .sensoryFeedback(.impact(weight: .light), trigger: response.lines.count)
        .sensoryFeedback(.selection, trigger: response.tarotDraws.count)
        .sensoryFeedback(.impact(weight: .light), trigger: response.revealedCount)
    }

    private func heading(_ request: OracleInteractionRequest) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionEyebrow(text: request.tarotClarification != nil ? "第\(clarificationNumber)次补牌 · 一张牌"
                    : request.kind == .tarot ? "首轮 · 三张牌" : "此刻 · 此问")
                    .accessibilityIdentifier(request.kind == .tarot ? "tarotRoundTitle" : "interactionStepTitle")
                Spacer()
                Text("\(session.currentIndex + 1) / \(session.requests.count)")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(InkTheme.secondary)
                    .accessibilityLabel("第\(session.currentIndex + 1)步，共\(session.requests.count)步")
            }
            if let clarification = request.tarotClarification {
                Text(clarification.focus)
                    .font(.system(size: 23, design: .serif)).lineSpacing(7)
                    .foregroundStyle(InkTheme.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("tarotClarificationFocus")
                if let position = clarification.originalPosition {
                    Text("对应牌位 · \(TarotDeck.localizedTitle(for: position))")
                        .font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar)
                }
            } else {
                Text(request.prompt.isEmpty ? defaultPrompt(for: request.kind) : request.prompt)
                    .font(.system(size: 23, design: .serif)).lineSpacing(7)
                    .foregroundStyle(InkTheme.ink).fixedSize(horizontal: false, vertical: true)
            }
            Text(session.input.question).font(.system(size: 13, design: .serif)).lineSpacing(5)
                .foregroundStyle(InkTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func defaultPrompt(for kind: OracleInteractionKind) -> String {
        switch kind {
        case .numbers: "把这三个数，留给此刻。"
        case .coins: isYarrow ? "心中留一问，三变定一爻。" : "心中留一问，六掷成一卦。"
        case .tarot: "静下心来，选出你的三张牌。"
        }
    }

    private var numberSelection: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 20) {
                Text("慢慢转动，留下三个想到的数。")
                    .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary)
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        VStack(spacing: 8) {
                            Text(["壹", "贰", "叁"][index]).font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                            Picker("第\(index + 1)个数字", selection: numberBinding(at: index)) {
                                ForEach(1...999, id: \.self) { value in Text("\(value)").tag(value) }
                            }
                            .pickerStyle(.wheel).frame(maxWidth: .infinity).frame(height: 170).clipped()
                            .accessibilityIdentifier("interactionNumber-\(index)")
                        }
                    }
                }
                Text("没有对错，停在你愿意留下的位置就好。")
                    .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
            }
        }
    }

    private func numberBinding(at index: Int) -> Binding<Int> {
        Binding(get: { response.numbers.indices.contains(index) ? response.numbers[index] : 1 }, set: { value in
            updateResponse {
                if $0.numbers.count != 3 { $0.numbers = [1, 1, 1] }
                $0.numbers[index] = value
            }
        })
    }

    private func updateResponse(_ update: (inout OracleInteractionResponse) -> Void) {
        var updated = response
        update(&updated)
        guard updated != response else { return }
        response = updated
        onProgress(updated)
    }

    private var coinCasting: some View {
        VStack(spacing: 22) {
            PaperCard {
                VStack(spacing: 24) {
                    HStack {
                        Text(response.lines.count == 6 ? "六爻已成" : isYarrow ? "第\(response.lines.count + 1)爻 · 三变归奇" : "第\(response.lines.count + 1)次投掷")
                            .font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                        Spacer()
                        Text("\(response.lines.count) / 6").font(.system(size: 12)).monospacedDigit().foregroundStyle(InkTheme.secondary)
                    }
                    if isYarrow {
                        yarrowCasting
                    } else {
                        HStack(spacing: 17) {
                            ForEach(0..<3, id: \.self) { index in
                                coin(at: index)
                                    .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(coinTurns) * 720), axis: (x: 1, y: 0.35, z: 0))
                                    .offset(y: tossing && !reduceMotion ? -14 : 0)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    Text(response.lines.isEmpty ? (isYarrow ? "四十九策，静候三变。" : "心中留着这一问，再投下三枚铜钱。") : lineDescription(response.lines.last!))
                        .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
                    Button(action: tossCoins) {
                        Label(castButtonTitle, systemImage: isYarrow ? "line.3.horizontal" : "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                            .background(InkTheme.cinnabar.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(response.lines.count == 6 || tossing)
                        .accessibilityIdentifier("castCoins")
                }
            }
            PaperCard {
                VStack(alignment: .leading, spacing: 17) {
                    SectionEyebrow(text: "由下往上，依次留爻")
                    ForEach((0..<6).reversed(), id: \.self) { index in
                        HStack(spacing: 15) {
                            Text(["初爻", "二爻", "三爻", "四爻", "五爻", "上爻"][index])
                                .font(.system(size: 11, design: .serif)).foregroundStyle(InkTheme.secondary).frame(width: 32)
                            if response.lines.indices.contains(index) {
                                hexagramLine(response.lines[index])
                                Text(lineName(response.lines[index])).font(.system(size: 10)).foregroundStyle(InkTheme.secondary).frame(width: 28)
                            } else {
                                Rectangle().fill(InkTheme.line.opacity(0.45)).frame(height: 1)
                                Text("待投").font(.system(size: 10)).foregroundStyle(InkTheme.secondary.opacity(0.6)).frame(width: 28)
                            }
                        }.frame(height: 22)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("castLine-\(index)")
                    }
                }
            }
        }
    }

    private var coinFaces: [[Int]] {
        var random = OracleSeededRandom(seed: session.seed)
        return (0..<6).map { _ in (0..<3).map { _ in Int.random(in: 2...3, using: &random) } }
    }

    private var yarrowCasts: [(value: Int, removals: [Int])] {
        var random = OracleSeededRandom(seed: session.seed)
        return (0..<6).map { _ in LiuyaoPlugin.yarrowCast(using: &random) }
    }

    private var castButtonTitle: String {
        if response.lines.count == 6 { return "六爻已成" }
        if isYarrow { return response.lines.isEmpty ? "归奇，留下初爻" : "再行三变" }
        return response.lines.isEmpty ? "投下铜钱" : "再投一次"
    }

    private var yarrowCasting: some View {
        VStack(spacing: 18) {
            Canvas { context, size in
                for index in 0..<49 {
                    let group = index / 17
                    let column = index % 17
                    let x = CGFloat(column) * 4 + CGFloat(group) * 79 + 7
                    let lift = CGFloat((index * 7) % 11)
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 9 + lift))
                    path.addLine(to: CGPoint(x: x + CGFloat(index % 3 - 1) * 2, y: size.height - 10 - lift))
                    context.stroke(path, with: .color(InkTheme.sage.opacity(0.65)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }.frame(width: 238, height: 94)
                .offset(x: tossing && !reduceMotion ? 5 : 0)
                .accessibilityHidden(true)
            if let index = response.lines.indices.last {
                let cast = yarrowCasts[index]
                HStack(spacing: 7) {
                    Text("49")
                    ForEach(Array(cast.removals.enumerated()), id: \.offset) { _, removal in Text("− \(removal)") }
                    Text("= \(cast.value * 4)").foregroundStyle(InkTheme.ink)
                }.font(.system(size: 15, weight: .medium, design: .serif)).monospacedDigit().foregroundStyle(InkTheme.secondary)
                    .contentTransition(.numericText())
                Text("三变余\(cast.value * 4)策，四策为一，得\(cast.value)。")
                    .font(.system(size: 11, design: .serif)).foregroundStyle(InkTheme.secondary)
            } else {
                Text("一变 · 二变 · 三变").font(.system(size: 13, design: .serif)).tracking(3).foregroundStyle(InkTheme.secondary)
            }
        }.frame(maxWidth: .infinity)
    }

    private func coin(at index: Int) -> some View {
        let last = max(0, response.lines.count - 1)
        let face = response.lines.isEmpty ? 2 : coinFaces[last][index]
        return ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.73, green: 0.61, blue: 0.39), Color(red: 0.58, green: 0.47, blue: 0.29)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().stroke(InkTheme.paper.opacity(0.5), lineWidth: 1).padding(5)
            RoundedRectangle(cornerRadius: 1).fill(InkTheme.paper).frame(width: 13, height: 13)
            VStack {
                Text(face == 3 ? "乾" : "背").font(.system(size: 10, design: .serif))
                Spacer()
                Text(face == 3 ? "隆" : "钱").font(.system(size: 10, design: .serif))
            }.padding(.vertical, 9).foregroundStyle(InkTheme.ink.opacity(0.7))
        }.frame(width: 66, height: 66)
            .shadow(color: InkTheme.ink.opacity(0.1), radius: 3, y: 3)
            .accessibilityLabel(response.lines.isEmpty ? "铜钱" : "铜钱\(index + 1)，\(face == 3 ? "正面" : "背面")")
    }

    private func tossCoins() {
        guard response.lines.count < 6, !tossing else { return }
        tossing = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.48)) { coinTurns += 1 }
        let value = isYarrow ? yarrowCasts[response.lines.count].value : coinFaces[response.lines.count].reduce(0, +)
        updateResponse { $0.lines.append(value) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 480))
            tossing = false
        }
    }

    private func hexagramLine(_ value: Int) -> some View {
        HStack(spacing: 12) {
            if value == 7 || value == 9 { Rectangle().fill(InkTheme.ink).frame(height: 5) }
            else {
                Rectangle().fill(InkTheme.ink).frame(height: 5)
                Rectangle().fill(InkTheme.ink).frame(height: 5)
            }
        }.overlay(alignment: .trailing) {
            if value == 6 || value == 9 { Circle().stroke(InkTheme.cinnabar, lineWidth: 1).frame(width: 10, height: 10).offset(x: 15) }
        }.padding(.trailing, 18).accessibilityHidden(true)
    }

    private func lineName(_ value: Int) -> String {
        switch value { case 6: "老阴"; case 7: "少阳"; case 8: "少阴"; default: "老阳" }
    }

    private func lineDescription(_ value: Int) -> String {
        "这一爻为\(lineName(value))\(value == 6 || value == 9 ? "，记作动爻。" : "，已为你记下。")"
    }

    private func tarotReading(_ request: OracleInteractionRequest) -> some View {
        let cards = session.availableTarotCards
        let drawCount = request.tarotPositions.count
        return VStack(alignment: .leading, spacing: 24) {
            if drawCount == 0 || cards.count < drawCount {
                PaperCard {
                    Text("牌暂时没有备齐，请稍后再试。")
                        .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary)
                }
            } else if !hasShuffled {
                shuffleDeck
            } else if response.tarotDraws.count < drawCount {
                cardSelection(for: request, cards: cards)
            } else {
                cardRevelation(for: request)
            }
        }
    }

    private var shuffleDeck: some View {
        PaperCard {
            VStack(spacing: 22) {
                ZStack {
                    ForEach(0..<5, id: \.self) { index in
                        TarotCardBack()
                            .frame(width: 118, height: 200)
                            .rotationEffect(.degrees(Double(index - 2) * (shuffleTurns == 0 ? 6 : 10)))
                            .offset(x: CGFloat(index - 2) * (shuffleTurns == 0 ? 5 : 11))
                    }
                }.frame(height: 245).frame(maxWidth: .infinity).accessibilityHidden(true)
                Text("想着这一问，让牌慢慢归位。")
                    .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary)
                Button {
                    isShuffling = true
                    withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.7)) { shuffleTurns += 1 }
                    Task { @MainActor in
                        if !reduceMotion { try? await Task.sleep(for: .milliseconds(550)) }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { hasShuffled = true }
                        isShuffling = false
                    }
                } label: {
                    Label(isShuffling ? "正在洗牌…" : "洗牌，开始选牌", systemImage: "shuffle")
                        .font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                        .padding(.vertical, 12)
                }.buttonStyle(.plain).disabled(isShuffling).accessibilityIdentifier("shuffleTarot")
            }
        }
    }

    private func cardSelection(for request: OracleInteractionRequest, cards: [TarotCard]) -> some View {
        let drawCount = request.tarotPositions.count
        let isClarification = request.tarotClarification != nil
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isClarification ? "从余下的牌中选一张。" : "从牌中，选出与你有缘的三张。")
                    .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.ink)
                Spacer(minLength: 4)
                Text("\(response.tarotDraws.count) / \(drawCount)")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(InkTheme.cinnabar)
                    .accessibilityLabel("已选\(response.tarotDraws.count)张，共\(drawCount)张")
                    .accessibilityIdentifier("tarotSelectionCount")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 6), spacing: 12) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    let selection = response.tarotDraws.firstIndex { $0.cardID == card.id }
                    Button { selectCard(card, for: request) } label: {
                        TarotCardBack()
                            .aspectRatio(0.59, contentMode: .fit)
                            .overlay {
                                if let selection {
                                    Circle().fill(InkTheme.paper).frame(width: 25, height: 25)
                                        .overlay(Text(["壹", "贰", "叁"][selection]).font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.cinnabar))
                                }
                            }
                            .offset(y: selection == nil || reduceMotion ? 0 : -4)
                            .opacity(selection == nil ? 1 : 0.5)
                    }.buttonStyle(.plain).disabled(selection != nil)
                        .accessibilityLabel("第\(index + 1)张牌\(selection == nil ? "" : "，已选")")
                        .accessibilityIdentifier("tarotCard-\(index)")
                }
            }
            Text(isClarification ? "这张牌用于澄清本轮的焦点。" : "已选的牌会依次留在「现状、影响、建议」三个位置。")
                .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
        }
    }

    private func selectCard(_ card: TarotCard, for request: OracleInteractionRequest) {
        let index = response.tarotDraws.count
        guard request.tarotPositions.indices.contains(index),
              !response.tarotDraws.contains(where: { $0.cardID == card.id }) else { return }
        let draw = TarotDraw(cardID: card.id, isReversed: TarotDeck.isReversed(seed: session.seed, cardID: card.id),
                             position: request.tarotPositions[index])
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            updateResponse { $0.tarotDraws.append(draw) }
        }
    }

    private func cardRevelation(for request: OracleInteractionRequest) -> some View {
        let allRevealed = response.revealedCount == request.tarotPositions.count
        let isClarification = request.tarotClarification != nil
        let instruction = isClarification ? (allRevealed ? "补牌已翻开。" : "轻触翻开这张补牌。")
            : (allRevealed ? "三张牌已翻开，看看它们带来的线索。" : "按照顺序，一张一张翻开。")
        return VStack(alignment: .leading, spacing: 21) {
            Text(instruction)
                .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(response.tarotDraws.enumerated()), id: \.offset) { index, draw in
                    let title = TarotDeck.localizedTitle(for: draw.position)
                    VStack(spacing: 12) {
                        Text(title).font(.system(size: 13, weight: .medium, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                        Button { revealCard(at: index) } label: {
                            let revealed = index < response.revealedCount
                            ZStack {
                                TarotCardBack().opacity(revealed ? 0 : 1)
                                    .rotation3DEffect(.degrees(reduceMotion ? 0 : revealed ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                                if let card = TarotDeck.card(id: draw.cardID) {
                                    TarotCardFace(card: card, reversed: draw.isReversed)
                                        .opacity(revealed ? 1 : 0)
                                        .rotation3DEffect(.degrees(reduceMotion ? 0 : revealed ? 0 : -180), axis: (x: 0, y: 1, z: 0))
                                }
                            }.aspectRatio(0.59, contentMode: .fit)
                        }.buttonStyle(.plain).disabled(index != response.revealedCount || flipping)
                            .accessibilityLabel(index < response.revealedCount ? revealedLabel(draw, title: title) : "翻开第\(index + 1)张牌，\(title)")
                            .accessibilityIdentifier("revealTarot-\(index)")
                        if index < response.revealedCount, let card = TarotDeck.card(id: draw.cardID) {
                            Text(card.name).font(.system(size: 12, weight: .medium, design: .serif)).multilineTextAlignment(.center).foregroundStyle(InkTheme.ink)
                            Text(draw.isReversed ? "逆位" : "正位").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                        } else {
                            Text(index == response.revealedCount ? "轻触翻牌" : "静候片刻")
                                .font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: isClarification ? 158 : .infinity)
            .frame(maxWidth: .infinity)
            if allRevealed {
                PaperCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(response.tarotDraws.enumerated()), id: \.offset) { _, draw in
                            if let card = TarotDeck.card(id: draw.cardID) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(TarotDeck.localizedTitle(for: draw.position)) · \(card.name)")
                                        .font(.system(size: 13, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                                    Text((draw.isReversed ? card.reversed : card.upright).joined(separator: " · "))
                                        .font(.system(size: 12, design: .serif)).lineSpacing(4).foregroundStyle(InkTheme.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func revealedLabel(_ draw: TarotDraw, title: String) -> String {
        "\(title)，\(TarotDeck.card(id: draw.cardID)?.name ?? draw.cardID)，\(draw.isReversed ? "逆位" : "正位")"
    }

    private func revealCard(at index: Int) {
        guard index == response.revealedCount, response.tarotDraws.indices.contains(index), !flipping else { return }
        if reduceMotion {
            updateResponse { $0.revealedCount += 1 }
        } else {
            flipping = true
            withAnimation(.easeInOut(duration: 0.48), completionCriteria: .removed) {
                updateResponse { $0.revealedCount += 1 }
            } completion: {
                flipping = false
            }
        }
    }

    private func footer(for request: OracleInteractionRequest) -> some View {
        let ready = !tossing && !flipping && session.isValid(response, complete: true)
        return VStack(spacing: 8) {
            Button {
                guard ready, !isCompleting else { return }
                isCompleting = true
                onComplete(response)
            } label: {
                if request.tarotClarification != nil {
                    Text("确认补牌，继续解读")
                } else {
                    Text(session.currentIndex + 1 == session.requests.count ? "确认，听听解读" : "确认，继续下一步")
                }
            }.buttonStyle(InkPrimaryButton()).disabled(!ready || isCompleting).opacity(ready ? 1 : 0.4)
                .accessibilityIdentifier("confirmInteraction")
            Text("暂时离开也没关系，已留好的会替你保留。")
                .font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
        }.frame(maxWidth: 650).padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
            .frame(maxWidth: .infinity).background(InkTheme.paper)
    }
}

private struct TarotCardBack: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(InkTheme.ink)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(InkTheme.paper.opacity(0.5), lineWidth: 0.6).padding(4))
            .overlay {
                GeometryReader { geometry in
                    ZStack {
                        Circle().stroke(InkTheme.paper.opacity(0.3), lineWidth: 0.6).padding(geometry.size.width * 0.18)
                        Image(systemName: "sparkle").font(.system(size: max(12, geometry.size.width * 0.24), weight: .ultraLight)).foregroundStyle(InkTheme.paper.opacity(0.8))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.shadow(color: InkTheme.ink.opacity(0.12), radius: 3, y: 2)
    }
}

private struct TarotCardFace: View {
    let card: TarotCard
    let reversed: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(InkTheme.paper)
            if let url = TarotDeck.imageURL(for: card), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit().rotationEffect(.degrees(reversed ? 180 : 0))
            } else {
                Text(card.name).font(.system(size: 15, design: .serif)).multilineTextAlignment(.center).padding(8)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(InkTheme.line, lineWidth: 0.6))
            .shadow(color: InkTheme.ink.opacity(0.1), radius: 3, y: 2)
    }
}
