import Foundation

/// Selects methods for the question actually asked. Explicit method choices
/// and the method scope of a referenced reading are handled by the caller.
enum AutomaticReadingMethods {
    static func select(question: String, proposed: [OracleMethod] = [],
                       available: Set<OracleMethod>) -> [OracleMethod] {
        let needs = readingNeeds(in: question)
        let candidates = OracleMethod.allCases.filter(available.contains)
        let proposedOrder = proposed.reduce(into: [OracleMethod: Int]()) { order, method in
            if order[method] == nil { order[method] = order.count }
        }
        if needs.isEmpty {
            // If the local wording is unfamiliar, keep a small model proposal.
            // Name grids and bone weight need their own specific question.
            return Array(proposedOrder.keys.filter {
                available.contains($0) && $0 != .xingming && $0 != .chenggu
            }.sorted { proposedOrder[$0, default: 0] < proposedOrder[$1, default: 0] }.prefix(3))
        }

        let fits = needs.map(\.methodFits)
        let selected = Set(fits.flatMap { scores -> [OracleMethod] in
            let supported = scores.filter { available.contains($0.key) }
            guard let strongest = supported.values.max() else { return [] }
            // For each distinct need, include its direct fits. If none is
            // loaded, use the strongest available method for that need.
            let cutoff = min(5, strongest)
            return supported.filter { $0.value >= cutoff }.map(\.key)
        })
        return candidates.enumerated().compactMap { position, method -> RatedMethod? in
            guard selected.contains(method) else { return nil }
            let scores = fits.compactMap { $0[method] }
            return RatedMethod(method: method, strongest: scores.max() ?? 0, coverage: scores.reduce(0, +),
                               suggestedOrder: proposedOrder[method] ?? .max, stableOrder: position)
        }.sorted { lhs, rhs in
            if lhs.strongest != rhs.strongest { return lhs.strongest > rhs.strongest }
            if lhs.coverage != rhs.coverage { return lhs.coverage > rhs.coverage }
            if lhs.suggestedOrder != rhs.suggestedOrder { return lhs.suggestedOrder < rhs.suggestedOrder }
            return lhs.stableOrder < rhs.stableOrder
        }.map(\.method)
    }

    private struct RatedMethod {
        var method: OracleMethod
        var strongest: Int
        var coverage: Int
        var suggestedOrder: Int
        var stableOrder: Int
    }

    /// Local capabilities, corresponding to the descriptors' supported
    /// questions. Scores 5 and 6 denote a direct fit; 4 denotes a fallback.
    private enum Need: Hashable {
        case decision, progress, actionTiming, workingRelationship, personalRelationship
        case longCycle, currentStage, selfReflection, name, traditionalVerse

        var methodFits: [OracleMethod: Int] {
            switch self {
            case .decision: [.liuyao: 6, .tarot: 6, .meihua: 4, .qimen: 4]
            case .progress: [.meihua: 6, .xiaoliuren: 5, .liuyao: 4, .tarot: 4]
            case .actionTiming: [.qimen: 6, .meihua: 5, .astrology: 4, .xiaoliuren: 4]
            case .workingRelationship: [.liuyao: 6, .qimen: 5, .meihua: 4, .tarot: 4]
            case .personalRelationship: [.tarot: 6, .meihua: 5, .liuyao: 4]
            case .longCycle: [.bazi: 6, .ziwei: 6, .astrology: 4]
            case .currentStage: [.astrology: 6, .bazi: 5, .ziwei: 4]
            case .selfReflection: [.tarot: 6, .bazi: 5, .astrology: 4]
            case .name: [.xingming: 6]
            case .traditionalVerse: [.chenggu: 6]
            }
        }
    }

    private static func readingNeeds(in question: String) -> Set<Need> {
        // Examples and negated tasks do not authorize extra methods.
        let unquoted = question.replacingOccurrences(of: #"“[^”]*”|「[^」]*」|『[^』]*』|"[^"]*""#, with: " ", options: .regularExpression)
        let clauses = unquoted.components(separatedBy: CharacterSet(charactersIn: "，,。；;！？!?\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var needs = Set<Need>()
        var lead = ""
        for clause in clauses where !clause.isEmpty {
            if matches(#"^(?:我(?:们)?\s*)?(?:先|暂时)?\s*(?:别(?:看|问|算|分析)|暂不|不(?:用|要|必|想|看|问|谈|考虑|分析)|不是(?:要|想|问)|(?:please\s+)?(?:don't|do not|no need to)\b)"#, in: clause) {
                lead = ""
                continue
            }
            let direct = classify(clause)
            let current = direct.isEmpty && !lead.isEmpty ? classify(lead + " " + clause) : direct
            needs.formUnion(current)
            // A short heading may carry the actor or the period into the
            // following clause, such as “下周，我这份工作会有进展吗？”
            lead = current.isEmpty ? clause : ""
        }
        return needs
    }

    private static func classify(_ clause: String) -> Set<Need> {
        var result = Set<Need>()
        let name = matches(#"改名|取名|起名|名字(?:结构|寓意|吉凶|好吗|好不好|怎么样|适合)|(?:名字|姓名|笔名|藝名|艺名).{0,14}(?:分析|寓意|解析|五格|笔画|合适|适合|好不好|怎么选)|(?:这个|這個|这些|這些)字.{0,10}(?:名字|笔名|藝名|艺名)|\b(?:name analysis|name meaning|choose a name|pen name|stage name|check my name)\b"#, in: clause)
        let traditional = matches(#"骨重|称骨诗|稱骨詩|命重几两|命重幾兩|传统命诗|傳統命詩|\b(?:bone weight|traditional fortune verse)\b"#, in: clause)
        if name { result.insert(.name) }
        if traditional { result.insert(.traditionalVerse) }

        let longHorizon = matches(#"未来(?:的)?(?:几年|幾年|[一二两兩三四五六七八九十百0-9]+年)|接下来(?:的)?(?:几年|幾年|[两兩三四五六七八九十0-9]+年)|往后(?:的)?(?:几年|幾年|[两兩三四五六七八九十0-9]+年)|长期|長期|中长期|中長期|人生阶段|人生階段|十年|未来半年|未来一年|今明两年|今年和明年|今年|明年|\b(?:long[- ]term|over the next (?:few|several|[0-9]+|two|three|five|ten) years|next year|this year|decade)\b"#, in: clause)
        let nearHorizon = matches(#"最近|近期|近来|近來|这阵子|這陣子|这段时间|這段時間|现在|現在|目前|眼下|当下|當下|本周|这周|這周|下周|下週|未来.{0,3}周|接下来.{0,3}周|几周|幾週|两周|兩週|本月|下个月|下個月|这几天|這幾天|明天|后天|後天|今天|这次|這次|\b(?:right now|today|tomorrow|this (?:week|month)|next (?:week|month)|near[- ]term|recent(?:ly)?|currently|the next \w+ weeks)\b"#, in: clause)
        let lifeTopic = matches(#"事业|事業|职场|職場|职业|職業|工作|感情|恋爱|戀愛|婚姻|财务|財務|财运|財運|收入|学业|學業|运势|運勢|人生|个人发展|個人發展|\b(?:career|work|financ(?:e|es|ial)|relationship|marriage|life|studies)\b"#, in: clause)
        let careerPath = matches(#"(?:继续|繼續|做|走|当|當|转|轉)(?:往|向|做)?(?:管理|技术|技術|创业|創業)|(?:管理|技术|技術)(?:岗|崗|路线|路線|方向)|\b(?:management track|technical track|career path|career change)\b"#, in: clause)
        let outlook = matches(#"发展|發展|走向|趋势|趨勢|走势|走勢|变化|變化|前景|影响|影響|如何|怎么样|怎麼樣|会怎样|會怎樣|方向|什么阶段|什麼階段|机会|機會|\b(?:outlook|develop|development|trend|direction|progress|impact|effect|opportunities|how|expect)\b"#, in: clause)
        let currentStage = matches(#"(?:当前|當前|目前|现在|現在|眼下|当下|當下|现阶段|現階段|这个月|這個月|本月|未来几个月|未來幾個月|接下来几个月|最近几个月).{0,14}(?:阶段|階段|周期|週期|转折|轉折)|(?:个人|個人|人生|我).{0,10}(?:处在|處在|处于|處於|进入|進入).{0,8}(?:阶段|階段|周期|週期)|\b(?:my current life phase|personal cycle|current life phase)\b"#, in: clause)
        let reflection = matches(#"自我(?:梳理|反思|探索|认识|認識)|我为什么总|我為什麼總|我的性格|我的行为模式|我的行為模式|我的情绪模式|我的情緒模式|\b(?:self[- ]reflection|my (?:personality|emotional patterns)|why do i always)\b"#, in: clause)
        let conciseOutlook = matches(#"^(?:想看|看看|帮我看|想问)?\s*(?:今年|明年|今明两年|未来半年|未来一年)\s*(?:我(?:的)?)?\s*(?:事业|财运|工作运|运势|学业|感情|婚姻)$"#, in: clause)
        if longHorizon && (lifeTopic && outlook || careerPath || conciseOutlook) { result.insert(.longCycle) }
        if currentStage && !result.contains(.longCycle) { result.insert(.currentStage) }
        if reflection { result.insert(.selfReflection) }

        // A name choice belongs to naming and a life-cycle trend belongs to
        // personal methods. Separate concrete decision clauses still add their
        // own methods through readingNeeds.
        if name || traditional || result.contains(.longCycle) { return result }

        let decision = matches(#"该不该|該不該|要不要|应不应该|應不應該|(?:是否|是不是)(?:该|該|要|应该|應該|适合|適合|值得)|适不适合|適不適合|值不值得|做不做|接不接|去不去|留不留|辞不辞|辭不辭|(?:进|進)(?:一步)?还是(?:该|該)?(?:守|稳|穩|退)|(?:待|留|接|换|換|转|轉|守|辞|辭|进|進).{0,16}(?:还是|還是).{0,12}(?:待|留|接|换|換|转|轉|守|辞|辭|进|進|别|別|先|稳|穩|退|等|继续|繼續)|(?:该|該|应该|應該|要).{0,12}(?:还是|還是)|怎么选|怎麼選|如何选择|如何選擇|\b(?:(?:should|do) (?:i|we)|what should (?:i|we) do|which option|how (?:do|should) (?:i|we) decide)\b"#, in: clause)
        let timing = matches(#"(?:什么时候|什麼時候|何时|何時|哪(?:天|个时间|個時間|个时机|個時機)|哪个时间段|哪個時間段).{0,12}(?:最适合|最適合|合适|合適|行动|行動|推进|推進|出发|出發|提出|联系|聯繫|谈|談|投递|投遞|决定|決定)|择时|擇時|行动节奏|行動節奏|(?:合适|合適|合宜|最佳)(?:的)?(?:时机|時機|时间|時間)|\b(?:when should (?:i|we)|best time to|right time to|timing of)\b"#, in: clause)
        let progress = matches(#"进展|進展|后续如何|後續如何|接下来会怎样|接下來會怎樣|会不会顺利|會不會順利|什么结果|什麼結果|有没有回应|有沒有回應|有消息吗|有消息嗎|(?:入职|入職|试用期|試用期).{0,14}(?:适应|適應|顺利|順利)|\b(?:status|progress|developments|how (?:will|is) it go|what happens next)\b"#, in: clause)
        let relationshipQuestion = matches(#"怎么相处|怎麼相處|该怎么沟通|該怎麼溝通|如何相处|如何相處|如何沟通|如何溝通|关系如何|關係如何|关系怎么样|關係怎麼樣|对方怎么想|對方怎麼想|会不会联系|會不會聯繫|相处模式|相處模式|\b(?:how .* communicate|how .* get along|what .* relationship like|relationship dynamics)\b"#, in: clause)
        let professional = matches(#"合作|同事|协作|協作|团队|團隊|工作沟通|工作溝通|项目|項目|\b(?:colleague|team|workplace|collaboration|project|working relationship)\b"#, in: clause)
        let asksIfSuitable = matches(#"(?:适合|適合|合适|合適).{0,16}(?:吗|嗎|么|麼|呢)$"#, in: clause)
        if (decision || asksIfSuitable) && !(timing && matches(#"^\s*(?:when should|what(?:'s| is) the best time)\b"#, in: clause)) { result.insert(.decision) }
        if timing { result.insert(.actionTiming) }
        if progress || nearHorizon && lifeTopic && outlook && !decision && !asksIfSuitable && !timing && !currentStage { result.insert(.progress) }
        if relationshipQuestion { result.insert(professional ? .workingRelationship : .personalRelationship) }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
