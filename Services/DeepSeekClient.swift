import Foundation

struct AIConversationTurn: Codable, Sendable {
    var role: String
    var content: String
}

/// Connection evidence contains only transport/model metadata, never messages,
/// credentials or the provider's hidden reasoning content.
struct AIConnectionReport: Codable, Sendable {
    var requestedModel: String
    var actualModel: String?
    var host: String
    var elapsed: TimeInterval
    var checkedAt: Date
    var finishReason: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var reasoningTokens: Int?
}

struct DeepSeekTokenUsage: Decodable, Sendable {
    var promptTokens: Int? = nil
    var completionTokens: Int? = nil
    var totalTokens: Int? = nil
    var reasoningTokens: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
        case reasoningTokens = "reasoning_tokens", completionDetails = "completion_tokens_details"
    }
    private struct CompletionDetails: Decodable { var reasoning_tokens: Int? }

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int? {
            guard let value = try values.decodeIfPresent(Int.self, forKey: key), value >= 0 else { return nil }
            return value
        }
        promptTokens = try count(.promptTokens)
        completionTokens = try count(.completionTokens)
        totalTokens = try count(.totalTokens)
        let details = try values.decodeIfPresent(CompletionDetails.self, forKey: .completionDetails)
        if let nestedReasoning = details?.reasoning_tokens, nestedReasoning >= 0 { reasoningTokens = nestedReasoning }
        else { reasoningTokens = try count(.reasoningTokens) }
    }

    mutating func merge(_ next: DeepSeekTokenUsage) {
        promptTokens = next.promptTokens ?? promptTokens
        completionTokens = next.completionTokens ?? completionTokens
        totalTokens = next.totalTokens ?? totalTokens
        reasoningTokens = next.reasoningTokens ?? reasoningTokens
    }
}

enum DeepSeekError: LocalizedError, Sendable {
    case missingKey
    case signInRequired
    case dataSharingConsentRequired
    case invalidResponse
    case malformedJSON
    case truncated
    case http(Int)
    case gateway(status: Int, code: String)
    case provider(String)
    case missingResponseModel
    case unexpectedModel(requested: String, actual: String)
    var errorDescription: String? {
        switch self {
        case .gateway(let status, let code):
            AIGatewayFailure.message(status: status, code: code) ?? DeepSeekError.http(status).errorDescription
        case .malformedJSON:
            L10n.text("收到的回答不完整，请重试；已填写的资料仍保留。", "The reply was incomplete. Try again. Your details are saved.")
        case .truncated:
            L10n.text("回答在传输中中断，请重试；推演结果已保留。", "The reply was interrupted in transit. Try again. Your reading is saved.")
        case .http(409):
            L10n.text("这次请求已提交，服务未重复生成。若回答未完成，可稍后重试。", "This request was already submitted and was not generated again. If the reply is incomplete, try again later.")
        case .http(402):
            L10n.text("请先在数据页补充额度，再继续新的问事。", "Replenish your allowance in Data before starting a new reading.")
        case .http(401):
            L10n.text("登录状态已过期，请重新登录后再试。", "Your sign-in has expired. Sign in again and retry.")
        case .http(429):
            L10n.text("解读服务暂时繁忙，请稍后再试。", "The reading service is busy. Try again in a moment.")
        case .signInRequired:
            L10n.text("请先打开「数据 → 账号」，使用 Apple 登录后再进行在线解读。", "Open Data → Account and sign in with Apple before requesting an online reading.")
        case .dataSharingConsentRequired:
            L10n.text("请先在对话页右上角查看并同意「AI 数据使用」，再开始在线解读。", "Review and agree to AI data use at the top right of Chat before requesting an online reading.")
        case .missingKey, .invalidResponse, .http, .provider, .missingResponseModel, .unexpectedModel:
            L10n.text("解读服务暂时无法完成回答，请检查网络后重试。", "The reading service couldn’t finish this reply. Check your connection and try again.")
        }
    }
}

/// Remote language-only orchestration. All numeric charts are produced by local plugins.
actor DeepSeekClient {
    private let session: URLSession
    private let endpoint = DeepSeekConfiguration.endpoint
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let credential: String?
    private let accountSessions: AccountSessionManager
    private let quotaTasks: AIQuotaTaskService
    private let manageQuota: Bool
    private let dataSharingConsent: AIDataSharingConsentStore
    private let generationWaitPolicy: GatewayGenerationWaitPolicy
    #if DEBUG
    private let bypassConsentForFixture: Bool
    #endif
    private(set) var lastSuccessfulConnection: AIConnectionReport?
    private(set) var lastResponseReport: AIConnectionReport?

    private static let answerGuidelines = """
    旧版本的分歧选项选择、方法偏好权重不再参与判断；不要从历史反馈恢复此机制。用户明确提供的现实事实仍可作为语境。
    首句直接回答本条问题。问行不行，就给判断；问选哪个，就给首选；问怎么办，就给下一步。
    用日常口语下判断。结论有条件就把条件说清楚。不要用“我押”“我赌”“我断”或英文里“My bet is”等押注式开场，也不要沿用旧回复里的这类口头禅。
    只问一个判断、一个取舍或一个动作（包括“靠谱吗”“今天怎么回”），就用一小段两到三句话答完。最多挑一条依据，不逐项解释所有结果，不把同一个建议说两遍。问怎么回，就先给能直接发出去的话，不先铺垫，也不在后面重新复盘。用户要求展开，或问了多个需要分别作答的问题，再写详细。
    用实际返回的盘面线索和用户已说过的事实解释判断。普通娱乐问题可以给鲜明的象征性倾向。别编造盘面、日期、金额、成功率、他人心思或未来事实，也别把“两次取消且没约新时间”说成“关系已经断裂”。
    有分歧就说目前倾向哪边，以及哪一条现实条件会让判断反转。只能判断到一部分时，首句说清能回答到哪一步。只交代会改变结论的限制一次，避免“各有利弊”“顺其自然”或连用几个“可能”。
    """

    private static let methodReadinessGuidelines = """
    方法能否执行以应用给出的资料与准备状态为准，不把可选资料说成必需：八字采用设备本地真太阳时，必需出生日期、出生时区及有效出生地坐标（可从内置区县目录读取）；出生时间用于时柱及真太阳日期，时辰未知只给年、月、日柱候选，不固定可能跨日的日柱，不输出时柱。排盘性别只影响起运、大运。称骨必需出生日期、出生时区及有效出生地坐标，按真太阳日期和时辰查表；未知时辰枚举完整可能日期与时辰给骨重范围。紫微必需出生日期、出生时辰、排盘性别、出生时区和有效出生地坐标，本命按当地真太阳时排盘，运限查询保留结果注明的民用时间口径，缺项时不能生成唯一命盘。西方占星必需出生日期和出生时区，未知时刻可给全天星位区间；准确出生时刻和经纬度用于上升点、天顶和宫位，不是全部占星结果的前提。塔罗、六爻、梅花、奇门、小六壬不索取出生日期或排盘性别；奇门、小六壬以及梅花的时间/双数起卦需要本次确认的起卦地点坐标及当地时区，由统一表单选择。梅花三数定卦不需要地点。起卦地点独立于每位参与人的出生地，不从服务器位置或其他人档案猜测。姓名五格只必需分别提供姓和名。
    用户问“需要准备什么”“为什么要性别”“能不能先算”“这是什么”属于能力或资料咨询，先回答问题，不因提到方法就发起推演、补算、抽牌或收集新档案。咨询和明确执行命令分在不同分句时分别处理。没有关联推演时也要依据已有人员资料和待表单的实际缺项回答，不说完全没有资料；缺少可选字段应说明可做的范围，不笼统说不能继续。既有结果仍按当时已确认的快照解释，不能用后来修改的资料冒充原结果。
    """

    private static func voiceInstructions(_ voice: OracleVoiceStyle, language: AppLanguage) -> String {
        let direction: String
        let example: String
        switch voice {
        case .classic:
            direction = "像原版瞎子，平实、稳重，讲清关键线索和它为什么支持这个判断。按事情本身说话，不加包袱或比喻。"
            example = L10n.text("这次先等对方提出时间。对方两次取消，还没给新时间。等他把日期定下来，再决定要不要赴约。",
                                "Wait for them to suggest a time. They’ve canceled twice without rescheduling. Once they offer a date, decide if you still want to go.", language: language)
        case .deadpan:
            direction = "像熟人当面说实话，句子短，语气干脆。拿不准就说清卡在哪。俏皮话顺口时可以留一句，笑点放在事情上，别挖苦当事人。话说清楚就收住。"
            example = L10n.text("这周多半见不上。前两次都取消了，也没定新时间。周末你先排自己的。",
                                "You probably won’t meet this week. They canceled twice and haven’t picked another time. Go ahead and make your own weekend plans.", language: language)
        case .warm:
            direction = "像一位温和、有主见的参谋。先给明确建议，再用体谅的口吻把下一步拆到容易做到。可以承认眼下的为难，别替用户定义情绪或泛泛安慰。"
            example = L10n.text("我建议这次先等对方来约。两次取消都没补时间，你不用继续腾出周末。可以轻松回一句“定好时间再叫我”，然后照常安排。",
                                "I’d let them make the next invitation. They canceled twice without rescheduling, so you don’t need to keep your weekend open. A simple ‘Let me know when you’ve picked a time’ is enough.", language: language)
        case .storyteller:
            direction = "像江湖说书人，用自然口语和一个具体画面把局面讲透。先把判断说清，再用一个短比喻带出行动；不要写开场白、古腔、长故事或神秘预言。"
            example = L10n.text("这周我看难见上。对方两次取消都没补时间，像两趟船都没靠岸，犯不着一直站在码头。你先过你的周末，等他报准了时间再出门。",
                                "I doubt you’ll meet this week. They’ve canceled twice without offering a time, like two ferries that never docked. Leave the pier, enjoy your weekend, and go when you have a departure time.", language: language)
        }
        return """
        本轮回答风格：\(voice.title(language: language))
        \(direction)
        口吻示例（仅供模仿节奏，不能带入示例中的事实）：\(example)
        本轮按以上口吻回答，即使历史回复采用其他口吻。不要报出风格名。
        """
    }

    static func languageInstruction(_ language: AppLanguage) -> String {
        L10n.text(
            "用简体中文撰写所有面向用户的文字和对话摘要。按约定原样返回 JSON 键、方法 ID、字段 ID、对象值、牌位等结构化值；不要翻译姓名、问题原文或其他引用。历史的语言不改变本次回复语言。",
            "Write all user-facing text and summaries in natural English, including notes, interaction prompts, option titles and descriptions, and clarifying questions. Use BaZi (Four Pillars), Zi Wei Dou Shu, I Ching, Western astrology, and Tarot consistently. Keep JSON keys, action, method and field IDs, subject values (本人, 他人, 事件, 多人), sex values (男, 女), and Tarot position values exactly as the schema specifies. Preserve names, quoted text, and the original question. Older messages and result data may be in Chinese; explain them in English.",
            language: language
        )
    }

    private static let englishPlanExample = """
    Example: {"action":"intake","intent":"Career decision","subject":"本人","methods":["tarot"],"requiredFields":[],"note":"Let's review the details before we draw.","question":"Should I apply for the new job?","understanding":{"relation":"newQuestion","resolvedQuestion":"Should I apply for the new job?","execution":{"operation":"calculate","coverage":"changed","evidence":"Should I apply for the new job?"}},"interactions":[{"method":"tarot","kind":"tarot","prompt":"Choose three cards."}]}
    """

    init(accessToken: String? = nil, accountSessions: AccountSessionManager = .shared, quotaTasks: AIQuotaTaskService = .shared, manageQuota: Bool = true, sessionConfiguration: URLSessionConfiguration? = nil, dataSharingConsent: AIDataSharingConsentStore? = nil, generationWaitPolicy: GatewayGenerationWaitPolicy = .init()) {
        credential = accessToken
        self.accountSessions = accountSessions
        self.quotaTasks = quotaTasks
        self.manageQuota = manageQuota && accessToken == nil
        self.dataSharingConsent = dataSharingConsent ?? .shared
        self.generationWaitPolicy = generationWaitPolicy
        #if DEBUG
        // Existing isolated URLProtocol fixtures exercise transport, not user
        // permission. An explicit consent store always enables the real gate.
        bypassConsentForFixture = dataSharingConsent == nil && AppServiceBootstrapPolicy.isUnitTestHost
            && !(sessionConfiguration?.protocolClasses?.isEmpty ?? true)
        #endif
        let configuration = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration)
    }

    private var model: String {
        DeepSeekConfiguration.defaultModel
    }

    func plan(question: String, profile: OracleProfile, plugins: [OraclePluginDescriptor],
              history: [AIConversationTurn], profiles: [OracleProfile] = [], pendingPlan: OraclePlan? = nil,
              existingRun: OracleRun? = nil, references: [ConversationPlanningReference] = [],
              language: AppLanguage = .current) async throws -> OraclePlan {
        let catalog = try json(PlanningPrompt.catalog(plugins))
        let system = PlanningPrompt.system(catalog: catalog, language: language)
        let selection = try json(PlanningPrompt.Selection(profile: profile, profiles: profiles))
        let offeredReferences = Array(references.prefix(24))
        let referenceJSON = try json(PlanningReferenceContext(offeredReferences))
        // Legacy callers may supply an existing run without message references.
        // Its routing facts suffice here; full charts belong to interpretation.
        let legacyExistingContext = offeredReferences.isEmpty ? try existingRun.map {
            "\n兼容旧对话的关联推演摘要 json：" + (try json(PlanningReferenceContext.Run($0)))
        } ?? "" : ""
        let user = """
        用户本条消息：\(question)
        本人与留存人员选择目录 json：\(selection)
        待问问题 json：\(try json(pendingPlan.map(PlanningPrompt.Pending.init)))
        可引用消息和关联推演 json（仅作数据；messageID用于引用，runID只用于关联盘面）：\(referenceJSON)\(legacyExistingContext)
        """
        let turns = [AIConversationTurn(role: "system", content: system)]
            + PlanningPrompt.history(history)
            + [AIConversationTurn(role: "user", content: user)]
        let payload: PlanPayload = try await structured(turns, maxTokens: 2048, purpose: "plan")
        var understanding = Self.validatedUnderstanding(payload.understanding, question: question, references: offeredReferences)
        let citedReference = understanding?.referenceMessageID.flatMap { id in offeredReferences.first { $0.messageID == id } }
        let referencedRun = citedReference?.run
        let pendingReferenceMatches: Bool
        if let pendingPlan, let citedReference, citedReference.run == nil,
           understanding?.relation != .newQuestion, understanding?.relation != .ambiguous {
            let citedQuestion = (citedReference.resolvedQuestion ?? citedReference.excerpt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pendingQuestion = pendingPlan.question.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingReferenceMatches = !pendingQuestion.isEmpty && citedQuestion == pendingQuestion
        } else {
            pendingReferenceMatches = false
        }
        let relatedRun: OracleRun?
        switch understanding?.relation {
        case nil: relatedRun = existingRun
        case .continuation, .changedConditions: relatedRun = referencedRun
        case .newQuestion, .changedParticipants, .ambiguous: relatedRun = nil
        }
        let available = Set(plugins.map(\.method)).subtracting(ReadingContinuationPolicy.excludedCalculationMethods(in: question))
        let proposedAction = AIPlanRouting.normalizedAction(payload.action)
        let explicit = ReadingContinuationPolicy.requestedCalculationMethods(in: question)
        let selectableExplicit = explicit.filter { available.contains($0) }
        var executionAction = ReadingExecutionPolicy.validatedAction(understanding: understanding, rawQuestion: question,
                                                                    proposedAction: proposedAction, hasRelatedRun: relatedRun != nil)
        if executionAction == "clarify", understanding?.relation == .newQuestion,
           AIPlanRouting.asksForMethodSelection(payload.note),
           !ReadingExecutionPolicy.isNonExecutingRequest(question),
           !ReadingContinuationPolicy.isMethodConsultation(question),
           var intent = understanding?.execution,
           intent.operation == .clarify || intent.operation == .calculate,
           !AutomaticReadingMethods.select(question: question, available: available).isEmpty {
            // A method-selection question from the planner can be recovered
            // when the user's own question already identifies a reading.
            intent.operation = .calculate; intent.coverage = .changed
            understanding?.execution = intent
            executionAction = "intake"
        }
        if executionAction == "clarify", understanding?.relation != .ambiguous,
           !explicit.isEmpty,
           AIPlanRouting.shouldOpenFormForProfileRequest(action: proposedAction, note: payload.note,
               question: question, hasPendingQuestion: pendingPlan != nil),
           var intent = understanding?.execution {
            // The question and requested method are already explicit. Missing
            // profile facts belong in the form and never authorize a substitute.
            intent.operation = .calculate
            intent.coverage = relatedRun == nil ? .changed : .additional
            understanding?.execution = intent
            executionAction = relatedRun == nil ? "intake" : "supplement"
        }
        var action: String
        if let executionAction {
            // Resolve the work before selectedMethods can discard a planner's
            // methods merely because its action was incorrectly labelled reply.
            action = executionAction
        } else if understanding?.relation == .ambiguous {
            action = "clarify"
        } else if proposedAction == "supplement", understanding?.relation == .changedParticipants {
            action = "intake"
        } else if proposedAction == "supplement", relatedRun == nil {
            action = "reply"
        } else {
            action = proposedAction
        }
        let mayResume = understanding == nil ? action != "supplement"
            : pendingReferenceMatches && ["intake", "collect"].contains(action)
        // A new calculation can inherit the bound form's methods, not its
        // original question or partially confirmed interaction. Actual data
        // collection and old plans keep their existing resume semantics.
        let allowsPendingResume = understanding?.execution == nil || understanding?.execution?.operation == .collect
        var resume = mayResume && allowsPendingResume && payload.resumePending == true && pendingPlan != nil
        var requestedMethods = resume ? pendingPlan!.methods.map(\.rawValue) : payload.methods ?? []
        var selectionFailure: String?
        var usedAutomaticSelection = false
        if ["intake", "supplement"].contains(action) {
            let proposed = AIPlanRouting.selectedMethods(action: action, requested: requestedMethods, available: available)
            let inherited = (referencedRun ?? relatedRun).map { run in
                unique(run.plan.methods + run.results.filter { [.complete, .partial].contains($0.status) }.map(\.method))
                    .filter { available.contains($0) }
            } ?? []
            let pendingMethods = pendingReferenceMatches
                ? (pendingPlan?.methods ?? []).filter { available.contains($0) } : []
            let inheritedMethods = inherited.isEmpty ? pendingMethods : inherited
            let bareRecast = understanding?.execution?.operation == .recast
                && ReadingContinuationPolicy.isBareRecastRequest(question)
            let preserveSelection = resume || (bareRecast && !inheritedMethods.isEmpty)
            let onlyRetained = relatedRun.flatMap { run -> [OracleMethod]? in
                guard action == "supplement", understanding?.relation == .continuation,
                      !AIPlanRouting.requestsCombinedMethods(question),
                      question.range(of: #"再(?:加|补)(?:一|两|几)(?:种|个)方法|\b(?:add|try) (?:one |an?)?other method\b"#,
                                     options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
                let original = run.input.question
                guard AIPlanRouting.limitsMethods(original) else { return nil }
                let selected = ReadingContinuationPolicy.requestedCalculationMethods(in: original).filter { available.contains($0) }
                return selected.isEmpty ? nil : selected
            }
            let methods: [OracleMethod]
            if !explicit.isEmpty {
                if selectableExplicit.count != explicit.count {
                    methods = []
                    selectionFailure = L10n.text("这次指定的方法暂不可用。", "A method you requested is currently unavailable.", language: language)
                } else if AIPlanRouting.requestsCombinedMethods(question) {
                    let ranked = AutomaticReadingMethods.select(question: question, proposed: proposed, available: available)
                    methods = unique(selectableExplicit + ranked)
                    usedAutomaticSelection = true
                } else {
                    methods = selectableExplicit
                }
            } else if let onlyRetained {
                methods = onlyRetained
            } else if preserveSelection {
                methods = bareRecast ? inheritedMethods : proposed
            } else if executionAction != nil || proposed.isEmpty {
                let scope = citedReference != nil ? understanding?.resolvedQuestion ?? question : question
                let direct = AutomaticReadingMethods.select(question: question, available: available)
                let ranked = AutomaticReadingMethods.select(question: direct.isEmpty ? scope : question,
                                                            proposed: proposed, available: available)
                usedAutomaticSelection = !ranked.isEmpty
                // Only a validated reference can lend its prior methods; a
                // new topic never borrows the latest reading as a default.
                methods = ranked.isEmpty ? inheritedMethods : ranked
            } else {
                methods = proposed
            }
            requestedMethods = methods.map(\.rawValue)
            if methods.isEmpty {
                selectionFailure = selectionFailure ?? L10n.text("你这次最想判断的是哪件事？", "What specific situation would you like to look at?", language: language)
                action = "clarify"; resume = false
                understanding = ConversationUnderstanding(relation: .ambiguous, resolvedQuestion: question, referenceMessageID: nil)
            }
        }
        let isAmbiguous = understanding?.relation == .ambiguous
        let suppressRoutingDetails = isAmbiguous || executionAction == "clarify"
        let methods = AIPlanRouting.selectedMethods(action: action, requested: requestedMethods, available: available)
        let subject = ["本人", "他人", "事件", "多人"].contains(payload.subject) ? payload.subject : "事件"
        let methodSet = Set(methods)
        let derived = plugins.filter { methodSet.contains($0.method) }.flatMap(\.requiredFields)
        let requested = (payload.requiredFields ?? []).compactMap(OracleField.init(rawValue:))
        let permitted = Set(plugins.filter { methodSet.contains($0.method) }.flatMap { $0.requiredFields + $0.optionalFields })
        let fields = unique(derived + requested.filter { permitted.contains($0) })
        let note: String
        if let selectionFailure {
            note = selectionFailure
        } else if ["intake", "supplement"].contains(action), AIPlanRouting.asksForMethodSelection(payload.note) {
            note = L10n.text("请先核对这次问事的资料。", "Review the details for this reading.", language: language)
        } else if suppressRoutingDetails && (proposedAction != "clarify" || payload.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            note = L10n.text("你想接着问的是哪件事，还是换个新问题？", "Which earlier topic did you mean, or is this a new question?", language: language)
        } else {
            note = payload.note
        }
        var plan = OraclePlan(intent: String(payload.intent.prefix(40)), subject: subject,
                              methods: methods, requiredFields: fields,
                              note: String(note.prefix(400)), question: resume ? pendingPlan!.question : question)
        plan.action = action
        plan.understanding = understanding
        if action == "reply", (understanding?.relation == .continuation || (understanding == nil && pendingPlan == nil)), let relatedRun {
            plan.tarotClarification = Self.validatedTarotClarification(payload.tarotClarification, for: relatedRun)
        }
        // Personal facts are entered or selected in the local form. A model
        // response must not become authority to autofill or alter saved people.
        plan.profileUpdates = nil
        plan.participantIDs = suppressRoutingDetails ? nil : payload.participantIDs?.compactMap(UUID.init(uuidString:))
        plan.participantNames = suppressRoutingDetails ? nil : payload.participantNames?.map { String($0.prefix(80)) }
        plan.relationship = suppressRoutingDetails ? nil : payload.relationship.map { String($0.prefix(80)) }
        plan.resumesPendingQuestion = resume
        plan.mandatoryMethods = suppressRoutingDetails || usedAutomaticSelection ? nil : payload.mandatoryMethods?
            .compactMap(OracleMethod.init(rawValue:)).filter { methodSet.contains($0) }
        if ["intake", "supplement"].contains(action), !suppressRoutingDetails {
            // Preserve an explicit user requirement even when a valid model
            // plan omits its optional mandatoryMethods field. The same positive
            // request parser excludes consultations, negations and quotations.
            let mandatoryExplicit = selectableExplicit.filter { methodSet.contains($0) }
            if !mandatoryExplicit.isEmpty {
                plan.mandatoryMethods = unique((plan.mandatoryMethods ?? []) + mandatoryExplicit)
            }
            if understanding?.execution?.operation == .recast {
                plan.mandatoryMethods = unique((plan.mandatoryMethods ?? []) + methods)
            }
        }
        if resume {
            plan.mandatoryMethods = plan.mandatoryMethods ?? pendingPlan?.mandatoryMethods
            if plan.participantIDs == nil && plan.participantNames == nil {
                plan.participantIDs = pendingPlan?.participantIDs
                plan.participantNames = pendingPlan?.participantNames
            }
            plan.relationship = plan.relationship ?? pendingPlan?.relationship
        }
        if action == "supplement", let relatedRun {
            plan.baseRunID = relatedRun.id
            plan.followUpQuestion = question
            plan.question = relatedRun.input.question
            plan.subject = relatedRun.input.subject
            if (plan.participantIDs ?? []).isEmpty && (plan.participantNames ?? []).isEmpty {
                plan.participantIDs = relatedRun.input.readingParticipants.map(\.id)
                plan.participantNames = relatedRun.input.readingParticipants.map(\.resolvedName).filter { !$0.isEmpty }
            }
            plan.relationship = relatedRun.input.relationship ?? plan.relationship
        }
        let requests = (payload.interactions ?? []).compactMap { item -> OracleInteractionRequest? in
            guard let method = OracleMethod(rawValue: item.method), let kind = OracleInteractionKind(rawValue: item.kind) else { return nil }
            return OracleInteractionRequest(method: method, kind: kind, prompt: item.prompt ?? "")
        }
        plan.interactions = resume && payload.interactions == nil ? pendingPlan?.interactions : requests
        if action == "supplement", let relatedRun {
            plan.interactions = (relatedRun.plan.interactions ?? []) + requests
        }
        plan.interactions = ["intake", "supplement"].contains(action) ? OracleInteractionPolicy.requests(for: plan) : []
        return plan
    }

    func synthesize(run: OracleRun, history: [AIConversationTurn],
                    language: AppLanguage = .current, voice: OracleVoiceStyle = .defaultStyle,
                    onProgress: (@Sendable (AIReadingProgress) async -> Void)? = nil,
                    onDelta: @escaping @Sendable (String) async -> Void) async throws -> ReadingSynthesis {
        await onProgress?(.preparing)
        let eligible = run.results.filter { $0.status == .complete || $0.status == .partial }
        guard !eligible.isEmpty else {
            throw DeepSeekError.provider(L10n.text("这次资料不足，尚未得到可解读的推演结果。请在「数据」里查看需要补充的项目。", "There are no reading results to interpret yet. Open Data to see which details are needed."))
        }
        let system = """
        你是“瞎子”，一位敏锐的盲眼先生。用自然的语言回应问题，不卖弄术语，不说自己看到了用户。
        \(Self.answerGuidelines)
        \(Self.methodReadinessGuidelines)
        \(Self.voiceInstructions(voice, language: language))
        如上下文包含补充追问，优先回答本条追问，结合已复用的结果与实际补充完成的结果；方法是否补充、哪些输入变化及哪些结果可复用已由客户端路由和执行。不能把仅提出的方法当成已完成，也不能声称重复计算或改动了仍沿用的牌面、爻值及人员快照。
        本次结果和已确认资料优先于历史回答。资料更正或撤回后重新计算的项目，只能按本次结果解读；出生时刻未知时不得沿用旧回答里的时柱、起运岁数或大运，历史中的精确结论不能作为本次依据。
        八字、紫微本命、称骨，以及奇门、小六壬、梅花时间/双数结果已由本地真太阳时算法完成，必须沿用返回的盘面与候选，不按原钟表时间另排或再次校正。三数梅花不套时间；西方占星沿真实UTC和经纬度天文计算，不套八字太阳钟面。出生类使用出生地，问事类使用已确认的起卦地点；纪日、子时和真实交节以结果的具体规则为准。
        当前阶段是可用结果计算完成后的解读。只按本轮实际可用的结果和确认状态判断完成了哪些方法；有已确认可用牌面或爻值时，其对应的历史“重抽”“再掷”等操作请求已经完成。直接解读本轮结果来回答问事，不再要求用户完成已有结果对应的抽牌、投掷或提供牌面，也不回答自己能否操作抽牌。没有已确认可用结果的方法仍不得作为判断依据。
        本条补充问题记录用户的实际追问或操作请求，本次确认的补牌焦点另列。有本次确认焦点时，首句直接回答焦点。用户有具体追问时，接着说明这如何细化该追问的答案。用户只说“补一张”等操作指令时，按焦点解读即可。本次没有确认补牌时，已存补牌只作为回答当前问题的背景。
        解读正文不堆砌方法名称，不输出盘面推演步骤。详细结果可通过对应回复下方的「翻看数据」查看。资料不足的说明可以明确写出相关方法名称及缺项。
        若 omittedMethods、partial 结果的 limitations 或资料说明会影响当前结论，点明影响的具体部分。unavailable/failed 不得参与判断。
        塔罗数据保留英文原文。按保存的牌位、牌名和正逆位理解牌义，正文只讲支撑本条判断的牌，用户没问就不用逐张讲。各轮已确认补牌只围绕各自的焦点。处理本条补牌焦点时，结合首阵、此前已确认的补牌和本轮实际牌面，先直接回答焦点，再说明哪条原判断得到支持、缩小范围或需要修正，以及哪张牌提供了依据。没有实质变化就说明哪些判断仍成立。没有看到先前解读时，可以说明首阵支持的原方向，不声称此前已有某个具体结论。保留不确定性，给出贴合焦点的行动或可观察条件。引用牌面时保留其所在轮次、牌位和正逆位，不改变牌面或补造卡牌。同一牌阵的多轮补牌仍属一种方法。
        text先给现有牌面支持的完整回答。仅当上下文标明补牌建议可用，且回答后仍有一处具体而重要的歧义值得澄清时，可在JSON另外填tarotClarification，focus是一条具体问题，originalPosition可填Current situation、Influences或Advice以关联原牌位。text不再另问用户是否抽牌，应用会单独呈现可选操作。用户已经拒绝补牌、已有结果足够、牌面无法支持现实事实的核查时省略。
        多人问题中，参与人员快照及每份结果的participantID/participantName明确归属。逐人理解后再结合姻缘、友情、家庭或合作主题分析互动与行动建议；不能合并或串用生辰，不能因method相同而忽略另一人的结果。没有专门计算的合盘、配对分数或相位不得编造，不能把单人盘称为已完成合盘；资料不足须保留限制。
        按participantID对应participantLabel称呼每个人，分别写明线索和建议。称呼可能是代称、姓名或匿名编号。
        多种解读确有明显分歧时，直接在 text 正文中说明各自依据、适用条件，以及什么现实线索会改变当前判断；轻微差异自然整合，不凭空制造冲突。
        不生成分歧选择卡片，不要求用户挑选更符合自己的解释，也不记录或推断解读偏好；不固定分歧数量，不输出 alternatives 字段。
        方法数量不代表事实可信度或预测准确率，不得编造百分比。
        关于疾病、寿命、灾祸、投资或法律，不作命定断言或危险指示，以可核实事实和专业帮助为准；这句话不要机械地附加到所有普通问题。
        不输出内部思维链、隐藏推理或 reasoning_content，只输出面向用户的结论。
        \(Self.languageInstruction(language))
        必须输出合法 json；第一个字段必须是 text，便于应用实时显示。结构如下：
        {"text":"首句直接回答问题，再说明具体依据和必要建议；确有分歧时在正文中说明依据与条件。"}
        有可选补牌时：{"text":"直接回答，并说明现有牌面支持的建议。","tarotClarification":{"focus":"眼下应先确认双方的分工，还是先解决资源不足？","originalPosition":"Influences"}}
        """
        let readingData = try ReadingContextBuilder.payload(run: run, language: language)
        let task = run.plan.followUpQuestion == nil
            ? "本轮可用结果已计算完成。现在请依据以上本轮结果回答这个问事：\(try json(run.input.question))。不要把历史中的重抽操作句当成本轮问事。"
            : "本轮可用的补充结果已计算完成。现在依据以上本轮结果、已确认补牌焦点及实际追问给出解读，不要求重复已经完成的操作。"
        let payload = readingData + "\n\n" + task
        let turns = [AIConversationTurn(role: "system", content: system)]
            + sanitizedHistory(history)
            + [AIConversationTurn(role: "user", content: payload)]
        var extractor = JSONTextStreamExtractor()
        var hasWrittenText = false
        await onProgress?(.requesting)
        let content = try await stream(turns, jsonMode: true, maxTokens: 4000, purpose: "synthesize") { piece in
            if let delta = extractor.append(piece), !delta.isEmpty {
                if !hasWrittenText { hasWrittenText = true; await onProgress?(.writing) }
                await onDelta(delta)
            }
        }
        await onProgress?(.validating)
        guard let data = content.data(using: .utf8),
              let result = try? decoder.decode(SynthesisPayload.self, from: data),
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if manageQuota { try? await quotaTasks.markRepair(AIQuotaTaskScope.stage, needed: true) }
            throw DeepSeekError.malformedJSON
        }
        if manageQuota { try? await quotaTasks.markRepair(AIQuotaTaskScope.stage, needed: false) }
        let supported = Set(eligible.map(\.method))
        let text = result.textWithLegacyConflictDetails(supported: supported)
        var synthesis = ReadingSynthesis(text: text)
        synthesis.tarotClarification = Self.validatedTarotClarification(result.tarotClarification, for: run)
        return synthesis
    }

    func followUp(question: String, run: OracleRun?, profile: OracleProfile,
                  history: [AIConversationTurn], resolvedQuestion: String? = nil, citedQuestion: String? = nil,
                  preparationContext: String? = nil,
                  language: AppLanguage = .current, voice: OracleVoiceStyle = .defaultStyle,
                  onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        let system = """
        你是“瞎子”，一位敏锐的盲眼先生。用自然的语言回应问题，不卖弄术语。用户问卦象、爻辞或牌义时，直接解释相关术语。
        \(Self.answerGuidelines)
        \(Self.methodReadinessGuidelines)
        \(Self.voiceInstructions(voice, language: language))
        追问首句就回答本条具体问题，不先重述整份解读，不用反问代替已有结果能够支持的回答。普通问候、感谢或闲聊简短自然回应，不套解读结构。
        用户要详细解读时，依据本次已有结果进一步展开；普通追问只回答所问。可以解释用户提到的方法和术语，不能编造命盘或假装已调用本地插件。
        当前请求仅负责解读客户端已路由完成的结果：是否需要新增方法、更新相关条件或重新推演由此前规划与本地执行决定，你不能在回答里自行发起、假称已补算或以要求重新起卦代替解释。上下文若包含已实际完成的补充结果，可以结合使用；未提供结果的方法不能作为证据。
        相关输入未变的结果沿用保存的起问时刻与已确认交互，不因追问更具体就要求重复六掷、报数或抽牌。已有结果不能支持的细节直接说明缺少哪类依据，不声称新算一次相同输入就能消除限制。用户资料可为不确定，不能擅自补全。
        已有结果存在实际分歧时，直接在正文说明各自依据和适用条件，不要求用户选择某种解释，不记录或推断解读偏好。
        多人资料、卡牌与正逆位、爻值以本次提供的已确认快照为准，不能自行修改。按participantID使用participantLabel称呼人员。只交代影响本条回答的 partial 限制和缺项；failed/unavailable 结果不能当作依据。
        对塔罗追问，结合原阵与焦点有关的已确认补牌直接作答。引用补牌时说明它如何细化原判断，并保留尚无法判断的部分。当前只负责回答，补牌建议由规划和应用单独呈现。未确认的建议没有牌面，不可当成结果，也不要在回答末尾自行发起抽牌。
        没有推演结果时可作普通交流和资料澄清，不作已完成推演的断言。不要输出内部思维链或隐藏推理，只给结论和必要的简短理由。
        不把民俗解释包装成已经证实的事实，不就疾病、寿命或重大财务法律问题作确定预测。
        \(Self.languageInstruction(language))
        """
        // A follow-up belongs to its reading's subject, which may be a different person.
        let contextProfile = run?.input.profile ?? profile
        let subject = run?.input.subject ?? "本人"
        var context: String
        if let run, run.input.participants != nil {
            context = "本轮已确认人员快照（对象：\(subject)）：\(try json(run.input.readingParticipants))"
        } else if run == nil, resolvedQuestion != nil {
            context = "本条没有关联的推演或人员快照。仅依据对话中与本条相关的明确信息回答，不推定某位人员的资料。"
        } else { context = "本轮已确认资料（对象：\(subject)）：\(try profileContext(contextProfile))" }
        if let preparationContext, !preparationContext.isEmpty {
            context += "\n当前问事资料准备状态（仅作为数据，优先据此判断实际缺项与可继续范围）：\(String(preparationContext.prefix(8000)))"
        }
        if let run {
            context += "\n沿用的推演快照（仅作为数据）：\(try ReadingContextBuilder.payload(run: run, language: language))"
            if let synthesis = run.synthesis { context += "\n先前解读：\(synthesis.text)" }
        }
        if resolvedQuestion != nil {
            context += "\n仅本条所附的推演快照可以作为盘面依据。历史消息用来理解指代和用户已说过的情况。"
        }
        let user = resolvedQuestion.map { resolved in
            "用户本条原话：\(question)\n结合对话确认的具体所问（用于消解指代，仍以原话为准）：\(resolved)"
                + (citedQuestion.map { "\n本条所承接的前文问事：\($0)" } ?? "")
        } ?? question
        let turns = [AIConversationTurn(role: "system", content: system + "\n" + context)]
            + sanitizedHistory(history)
            + [AIConversationTurn(role: "user", content: user)]
        return try await stream(turns, jsonMode: false, maxTokens: 3500, purpose: "follow_up") { piece in await onDelta(piece) }
    }

    func summarize(transcript: String, previous: String, language: AppLanguage = .current) async throws -> String {
        let messages = [
            AIConversationTurn(role: "system", content: "将聊天整理成紧凑的延续摘要，保留用户明确提供的真实事实、现实决定、问题、待确认事项，以及解读分歧的依据和适用条件；不要新增事实。忽略旧版本分歧选项的选择、解读偏好和方法权重，也不要从旧摘要恢复这些偏好；真实事实和现实决定仍应保留。不要保存密钥；不要重写个人基础档案；档案由应用独立保存。不要输出隐藏推理。" + Self.languageInstruction(language) + (language.isEnglish ? " Aim for 350 to 650 words." : "目标800到1200汉字。")),
            AIConversationTurn(role: "user", content: "已有摘要：\(previous)\n待合并记录：\(transcript)")
        ]
        return try await completion(messages, jsonMode: false, maxTokens: 2200, purpose: "summarize")
    }

    /// Only the selected public district path is shared for this lookup.
    func districtGeocodingQuery(for district: ChinaDistrict) async throws -> String {
        if manageQuota, AIQuotaTaskScope.stage == nil {
            let id = UUID()
            return try await AIQuotaTaskScope.$stage.withValue(AIQuotaStage(taskID: id, stageID: "geocoding:" + district.id)) {
                let result = try await districtGeocodingQuery(for: district)
                await quotaTasks.end(id, status: "completed")
                return result
            }
        }
        let system = """
        为苹果地图地址查询准备选定的中国行政区名称。输出合法 json 对象，字段 id 原样返回、query 为所给完整区划名称，可使用简繁字形与逗号分隔，内地可加“中国”。香港、澳门和台湾也可省略一级地区名称。不要输出地址、地标或经纬度，不要换到同名地区。
        """
        let user = try json(["id": district.id, "path": district.components.joined(separator: "，")])
        let payload: DistrictQueryPayload = try await structured([
            .init(role: "system", content: system), .init(role: "user", content: user)
        ], maxTokens: 200, purpose: "geocoding")
        let query = payload.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.id == district.id, district.acceptsLookupQuery(query) else { throw DeepSeekError.malformedJSON }
        return query
    }

    private struct DistrictQueryPayload: Decodable {
        let id: String
        let query: String
    }

    // MARK: - Transport

    /// Uses the same model and reasoning configuration as real interpretation,
    /// with synthetic text only. No profile or conversation is sent.
    func checkConnection() async throws -> AIConnectionReport {
        if manageQuota, AIQuotaTaskScope.stage == nil {
            let id = UUID()
            return try await AIQuotaTaskScope.$stage.withValue(AIQuotaStage(taskID: id, stageID: "diagnostic")) {
                let report = try await checkConnection()
                await quotaTasks.end(id, status: "completed")
                return report
            }
        }
        try Task.checkCancellation()
        let requestedModel = model
        let messages = [AIConversationTurn(role: "system", content: "Connection check only. Reply with exactly OK."),
                        AIConversationTurn(role: "user", content: "Reply OK.")]
        let started = Date()
        let (data, response) = try await gatewayData(messages, jsonMode: false,
            maxTokens: DeepSeekConfiguration.outputTokenBudget, purpose: "diagnostic", requestID: UUID().uuidString)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIGatewayFailure.error(status: http.statusCode, body: data) }
        let result = try decoder.decode(CompletionEnvelope.self, from: data)
        let report = Self.report(result, requestedModel: requestedModel,
            host: http.url?.host ?? endpoint.host ?? "", started: started)
        lastResponseReport = report
        try Self.validateConnectionResponse(result, requestedModel: requestedModel)
        lastSuccessfulConnection = report
        return report
    }

    /// Exposes only the request payload so parameter regressions can be checked
    /// without credentials or a network request.
    static func requestBody(_ messages: [AIConversationTurn], jsonMode: Bool,
                            streaming: Bool, maxTokens: Int, purpose: String = "follow_up") -> [String: Any] {
        var body: [String: Any] = [
            "model": DeepSeekConfiguration.defaultModel,
            "purpose": purpose,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": streaming,
            "max_tokens": max(DeepSeekConfiguration.outputTokenBudget, maxTokens),
            "reasoning_effort": DeepSeekConfiguration.reasoningEffort,
            "thinking": ["type": DeepSeekConfiguration.thinkingEnabled ? "enabled" : "disabled"]
        ]
        if purpose == "plan" {
            // A versioned routing contract lets the gateway keep old admitted
            // stages replayable while applying the fast policy to new plans.
            body["planning_version"] = PlanningPrompt.version
            body["thinking"] = ["type": "disabled"]
            body.removeValue(forKey: "reasoning_effort")
            body["max_tokens"] = 2_048
        }
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        return body
    }

    private func request(_ messages: [AIConversationTurn], jsonMode: Bool, streaming: Bool,
                         maxTokens: Int, purpose: String, requestID: String, sessionGeneration: UUID? = nil) async throws -> URLRequest {
        try await requireDataSharingConsent()
        let key: String
        if let credential { key = credential }
        else {
            do { key = try await accountSessions.accessToken(expectedGeneration: sessionGeneration) }
            catch AccountAPIError.unauthorized { throw DeepSeekError.signInRequired }
        }
        guard !key.isEmpty else { throw DeepSeekError.signInRequired }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue(requestID, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        let proposedBody = try JSONSerialization.data(withJSONObject: Self.requestBody(messages,
            jsonMode: jsonMode, streaming: streaming, maxTokens: maxTokens, purpose: purpose))
        if manageQuota {
            let stage = AIQuotaTaskScope.stage ?? AIQuotaStage(taskID: UUID(uuidString: requestID) ?? UUID(), stageID: purpose)
            let prepared: PreparedAIStage
            do { prepared = try await quotaTasks.prepare(stage: stage, body: proposedBody, purpose: purpose) }
            catch AccountAPIError.server(let status, let code) { throw AIGatewayFailure.error(status: status, code: code) }
            request.httpBody = prepared.body
            request.setValue(prepared.taskID.uuidString.lowercased(), forHTTPHeaderField: "X-Task-ID")
            request.setValue(prepared.stageID, forHTTPHeaderField: "X-Stage-ID")
            request.setValue(prepared.admissionToken, forHTTPHeaderField: "X-Task-Token")
            if prepared.needsRepair { request.setValue("1", forHTTPHeaderField: "X-Stage-Repair") }
        } else { request.httpBody = proposedBody }
        return request
    }

    private func requireDataSharingConsent() async throws {
        #if DEBUG
        if bypassConsentForFixture { return }
        #endif
        do { try await dataSharingConsent.requireAuthorization() }
        catch { throw DeepSeekError.dataSharingConsentRequired }
    }

    private func renewGatewaySession(rejectedRequest: URLRequest, expectedGeneration: UUID?) async throws {
        try await requireDataSharingConsent()
        let rejectedToken = String((rejectedRequest.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        do { _ = try await accountSessions.refreshAfterRejection(of: rejectedToken, expectedGeneration: expectedGeneration) }
        catch { throw DeepSeekError.signInRequired }
    }

    private func gatewayData(_ messages: [AIConversationTurn], jsonMode: Bool, maxTokens: Int,
                             purpose: String, requestID: String, sessionGeneration: UUID? = nil) async throws -> (Data, URLResponse) {
        let currentGeneration = await accountSessions.sessionGeneration()
        let expected = sessionGeneration ?? currentGeneration
        var preparedRequest = try await request(messages, jsonMode: jsonMode, streaming: false,
            maxTokens: maxTokens, purpose: purpose, requestID: requestID, sessionGeneration: expected)
        var refreshedSession = false
        var wait = GenerationWaitState(delay: generationWaitPolicy.initialDelay,
            onChanged: AIQuotaTaskScope.stage?.onGenerationWaitChanged)
        do {
            while true {
                try await validateGatewayContext(expectedGeneration: expected)
                let result = try await session.data(for: preparedRequest)
                try await validateGatewayContext(expectedGeneration: expected, checkConsent: false)
                if let http = result.1 as? HTTPURLResponse {
                    if http.statusCode == 401, credential == nil {
                        guard !refreshedSession else {
                            try? await accountSessions.invalidate(expectedGeneration: expected)
                            throw DeepSeekError.signInRequired
                        }
                        try await renewGatewaySession(rejectedRequest: preparedRequest, expectedGeneration: expected)
                        preparedRequest = try await request(messages, jsonMode: jsonMode, streaming: false,
                            maxTokens: maxTokens, purpose: purpose, requestID: requestID, sessionGeneration: expected)
                        refreshedSession = true
                        continue
                    }
                    if manageQuota, let rejection = GatewayGenerationWaitPolicy.rejection(status: http.statusCode, body: result.0) {
                        try await waitForGeneration(rejection, state: &wait, expectedGeneration: expected)
                        continue
                    }
                }
                await finishGenerationWait(&wait)
                try await validateGatewayContext(expectedGeneration: expected, checkConsent: false)
                return result
            }
        } catch {
            await finishGenerationWait(&wait)
            throw error
        }
    }

    private func gatewayBytes(_ messages: [AIConversationTurn], jsonMode: Bool, maxTokens: Int,
                              purpose: String, requestID: String, sessionGeneration: UUID) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var preparedRequest = try await request(messages, jsonMode: jsonMode, streaming: true,
            maxTokens: maxTokens, purpose: purpose, requestID: requestID, sessionGeneration: sessionGeneration)
        var refreshedSession = false
        var wait = GenerationWaitState(delay: generationWaitPolicy.initialDelay,
            onChanged: AIQuotaTaskScope.stage?.onGenerationWaitChanged)
        do {
            while true {
                try await validateGatewayContext(expectedGeneration: sessionGeneration)
                let result = try await session.bytes(for: preparedRequest)
                do { try await validateGatewayContext(expectedGeneration: sessionGeneration, checkConsent: false) }
                catch { result.0.task.cancel(); throw error }
                if let http = result.1 as? HTTPURLResponse {
                    if http.statusCode == 401, credential == nil {
                        result.0.task.cancel()
                        guard !refreshedSession else {
                            try? await accountSessions.invalidate(expectedGeneration: sessionGeneration)
                            throw DeepSeekError.signInRequired
                        }
                        try await renewGatewaySession(rejectedRequest: preparedRequest, expectedGeneration: sessionGeneration)
                        preparedRequest = try await request(messages, jsonMode: jsonMode, streaming: true,
                            maxTokens: maxTokens, purpose: purpose, requestID: requestID, sessionGeneration: sessionGeneration)
                        refreshedSession = true
                        continue
                    }
                    // AsyncBytes cannot be replayed after consuming an error
                    // body. Handle only candidate rejection statuses here; all
                    // other responses retain the ordinary streaming parser.
                    if manageQuota, (http.statusCode == 409 || http.statusCode == 429) {
                        let body = try await gatewayRejectionBody(result.0)
                        if let rejection = GatewayGenerationWaitPolicy.rejection(status: http.statusCode, body: body) {
                            try await waitForGeneration(rejection, state: &wait, expectedGeneration: sessionGeneration)
                            continue
                        }
                        throw AIGatewayFailure.error(status: http.statusCode, body: body)
                    }
                }
                await finishGenerationWait(&wait)
                do { try await validateGatewayContext(expectedGeneration: sessionGeneration, checkConsent: false) }
                catch { result.0.task.cancel(); throw error }
                return result
            }
        } catch {
            await finishGenerationWait(&wait)
            throw error
        }
    }

    private struct GenerationWaitState {
        var deadline: ContinuousClock.Instant?
        var delay: Duration
        var didNotify = false
        var onChanged: (@Sendable (Bool) async -> Void)?
    }

    private func validateGatewayContext(expectedGeneration: UUID, checkConsent: Bool = true) async throws {
        try Task.checkCancellation()
        // Withdrawal prevents new transmissions; it does not revoke a response
        // for a request that was already sent with permission.
        if checkConsent { try await requireDataSharingConsent() }
        try Task.checkCancellation()
        if credential == nil, await accountSessions.sessionGeneration() != expectedGeneration {
            throw AccountAPIError.staleSession
        }
        try Task.checkCancellation()
    }

    private func waitForGeneration(_ rejection: DeepSeekError, state: inout GenerationWaitState,
                                   expectedGeneration: UUID) async throws {
        let now = ContinuousClock.now
        if state.deadline == nil { state.deadline = now.advanced(by: generationWaitPolicy.timeout) }
        guard let deadline = state.deadline, now < deadline else { throw rejection }
        if !state.didNotify {
            state.didNotify = true
            await state.onChanged?(true)
        }
        try await validateGatewayContext(expectedGeneration: expectedGeneration)
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw rejection }
        try await Task.sleep(for: min(state.delay, remaining))
        try await validateGatewayContext(expectedGeneration: expectedGeneration)
        guard ContinuousClock.now < deadline else { throw rejection }
        state.delay = min(generationWaitPolicy.maximumDelay, state.delay * 2)
    }

    private func finishGenerationWait(_ state: inout GenerationWaitState) async {
        guard state.didNotify else { return }
        // Consume the notification before suspension. A cancellation or account
        // change detected after this callback must not notify completion twice.
        state.didNotify = false
        await state.onChanged?(false)
    }

    private func gatewayRejectionBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        defer { bytes.task.cancel() }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            body.append(byte)
            if body.count == AIGatewayFailure.maximumBodyBytes { break }
        }
        return body
    }

    static func modelsMatch(requested: String, returned: String) -> Bool {
        let requested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let returned = returned.trimmingCharacters(in: .whitespacesAndNewlines)
        return !requested.isEmpty && (returned == requested || returned.hasPrefix(requested + "-"))
    }

    /// Pure parser shared with the probe's validation, for fixture-based checks.
    static func connectionReport(from data: Data, requestedModel: String, host: String,
                                 elapsed: TimeInterval, checkedAt: Date = Date()) throws -> AIConnectionReport {
        let result = try JSONDecoder().decode(CompletionEnvelope.self, from: data)
        try validateConnectionResponse(result, requestedModel: requestedModel)
        return report(result, requestedModel: requestedModel, host: host,
                      elapsed: elapsed, checkedAt: checkedAt)
    }

    private static func reportedModel(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        return model
    }

    private static func verifyModel(requested: String, actual: String?, required: Bool = false) throws {
        guard let actual = reportedModel(actual) else {
            if required { throw DeepSeekError.missingResponseModel }
            return
        }
        guard modelsMatch(requested: requested, returned: actual) else {
            throw DeepSeekError.unexpectedModel(requested: String(requested.prefix(120)), actual: String(actual.prefix(120)))
        }
    }

    private static func validateConnectionResponse(_ result: CompletionEnvelope, requestedModel: String) throws {
        try verifyModel(requested: requestedModel, actual: result.model, required: true)
        guard let choice = result.choices.first else { throw DeepSeekError.invalidResponse }
        if choice.finish_reason == "length" { throw DeepSeekError.truncated }
        guard choice.finish_reason == "stop", let text = choice.message.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeepSeekError.invalidResponse }
    }

    private static func report(_ result: CompletionEnvelope, requestedModel: String, host: String,
                               started: Date) -> AIConnectionReport {
        let checkedAt = Date()
        return report(result, requestedModel: requestedModel, host: host,
                      elapsed: checkedAt.timeIntervalSince(started), checkedAt: checkedAt)
    }

    private static func report(_ result: CompletionEnvelope, requestedModel: String, host: String,
                               elapsed: TimeInterval, checkedAt: Date) -> AIConnectionReport {
        report(requestedModel: requestedModel, actualModel: result.model, host: host, elapsed: elapsed,
               checkedAt: checkedAt, finishReason: result.choices.first?.finish_reason, usage: result.usage)
    }

    private static func report(requestedModel: String, actualModel: String?, host: String, elapsed: TimeInterval,
                               checkedAt: Date, finishReason: String?, usage: DeepSeekTokenUsage?) -> AIConnectionReport {
        AIConnectionReport(requestedModel: requestedModel, actualModel: reportedModel(actualModel), host: host,
            elapsed: max(0, elapsed), checkedAt: checkedAt, finishReason: finishReason,
            promptTokens: usage?.promptTokens, completionTokens: usage?.completionTokens,
            totalTokens: usage?.totalTokens, reasoningTokens: usage?.reasoningTokens)
    }

    private func structured<T: Decodable>(_ messages: [AIConversationTurn], maxTokens: Int, purpose: String) async throws -> T {
        for attempt in 0..<2 {
            let text = try await completion(messages, jsonMode: true, maxTokens: maxTokens, purpose: purpose)
            if let data = text.data(using: .utf8), let value = try? decoder.decode(T.self, from: data) {
                if manageQuota { try? await quotaTasks.markRepair(AIQuotaTaskScope.stage, needed: false) }
                return value
            }
            if manageQuota { try? await quotaTasks.markRepair(AIQuotaTaskScope.stage, needed: true) }
            if attempt == 1 { throw DeepSeekError.malformedJSON }
        }
        throw DeepSeekError.malformedJSON
    }

    private func completion(_ messages: [AIConversationTurn], jsonMode: Bool, maxTokens: Int, purpose: String) async throws -> String {
        defer { if manageQuota { NotificationCenter.default.post(name: .accountBalanceChanged, object: nil) } }
        let requestedModel = model
        let requestID = UUID().uuidString
        let expectedSession = await accountSessions.sessionGeneration()
        try Task.checkCancellation()
        let started = Date()
        let (data, response) = try await gatewayData(messages, jsonMode: jsonMode,
            maxTokens: maxTokens, purpose: purpose, requestID: requestID, sessionGeneration: expectedSession)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.invalidResponse }
        // A gateway attempt may already have reached the provider. Only an explicit user retry starts another one.
        guard (200..<300).contains(http.statusCode) else { throw AIGatewayFailure.error(status: http.statusCode, body: data) }
        let result = try decoder.decode(CompletionEnvelope.self, from: data)
        let report = Self.report(result, requestedModel: requestedModel,
            host: http.url?.host ?? endpoint.host ?? "", started: started)
        lastResponseReport = report
        try Self.verifyModel(requested: requestedModel, actual: result.model)
        guard let choice = result.choices.first else { throw DeepSeekError.invalidResponse }
        if choice.finish_reason == "length" {
            if manageQuota { try? await quotaTasks.markRepair(AIQuotaTaskScope.stage, needed: true) }
            throw DeepSeekError.truncated
        }
        let text = choice.message.content ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeepSeekError.invalidResponse }
        lastSuccessfulConnection = report
        return text
    }

    private func stream(_ messages: [AIConversationTurn], jsonMode: Bool, maxTokens: Int, purpose: String,
                        onPiece: (String) async -> Void) async throws -> String {
        defer { if manageQuota { NotificationCenter.default.post(name: .accountBalanceChanged, object: nil) } }
        let requestedModel = model
        let started = Date()
        let expectedSession = await accountSessions.sessionGeneration()
        let (bytes, response) = try await gatewayBytes(messages, jsonMode: jsonMode,
            maxTokens: maxTokens, purpose: purpose, requestID: UUID().uuidString, sessionGeneration: expectedSession)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            defer { bytes.task.cancel() }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                body.append(byte)
                if body.count == AIGatewayFailure.maximumBodyBytes { break }
            }
            throw AIGatewayFailure.error(status: http.statusCode, body: body)
        }
        let host = http.url?.host ?? endpoint.host ?? ""
        var full = ""
        var framer = DeepSeekSSEFramer()
        var done = false
        var finalReason: String?
        var actualModel: String?
        var usage = DeepSeekTokenUsage()
        defer {
            lastResponseReport = Self.report(requestedModel: requestedModel, actualModel: actualModel,
                host: host, elapsed: Date().timeIntervalSince(started),
                checkedAt: Date(), finishReason: finalReason, usage: usage)
        }

        func consume(_ chunk: DeepSeekSSEChunk) async throws {
            if chunk.isDone { done = true; return }
            if let reason = chunk.finishReason { finalReason = reason }
            if let nextUsage = chunk.usage { usage.merge(nextUsage) }
            if let model = Self.reportedModel(chunk.model) {
                actualModel = model
                try Self.verifyModel(requested: requestedModel, actual: model)
            }
            if !chunk.content.isEmpty { full += chunk.content; await onPiece(chunk.content) }
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if credential == nil, await accountSessions.sessionGeneration() != expectedSession { throw AccountAPIError.staleSession }
            if let chunk = try framer.push(line) { try await consume(chunk) }
            if done { break }
        }
        if !done { try framer.finish() }
        if finalReason == "length" {
            if manageQuota { try? await quotaTasks.markRepair(AIQuotaTaskScope.stage, needed: true) }
            throw DeepSeekError.truncated
        }
        guard done || finalReason == "stop" else { throw DeepSeekError.invalidResponse }
        guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeepSeekError.invalidResponse }
        try Task.checkCancellation()
        lastSuccessfulConnection = Self.report(requestedModel: requestedModel, actualModel: actualModel,
            host: host, elapsed: Date().timeIntervalSince(started),
            checkedAt: Date(), finishReason: finalReason, usage: usage)
        return full
    }

    private func profileContext(_ profile: OracleProfile) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: profile.birthTimeZoneID) ?? .current
        formatter.dateFormat = profile.birthTimeKnown ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd（时辰不确定）"
        var fields: [String: Any] = [
            "id": profile.id.uuidString,
            "name": profile.resolvedName,
            "participantLabel": profile.participantLabel,
            "familyName": profile.familyName,
            "givenName": profile.givenName,
            "gender": profile.sex,
            "birthDate": profile.birthDate.map { formatter.string(from: $0) } ?? "未提供",
            "birthTimeKnown": profile.birthTimeKnown,
            "birthTimeZone": profile.birthTimeZoneID,
            "birthPlace": profile.birthPlace,
            "unknownFields": profile.unknownFields.map(\.rawValue),
            "currentPlace": profile.currentPlace,
            "currentTimeZone": profile.currentTimeZoneID,
            "currentDate": ISO8601DateFormatter().string(from: Date())
        ]
        if let lat = profile.birthLatitude, let lon = profile.birthLongitude { fields["birthCoordinates"] = [lat, lon] }
        if let lat = profile.currentLatitude, let lon = profile.currentLongitude { fields["currentCoordinates"] = [lat, lon] }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func sanitizedHistory(_ history: [AIConversationTurn]) -> [AIConversationTurn] {
        history.filter { ["user", "assistant"].contains($0.role) && !$0.content.isEmpty }
            .map { AIConversationTurn(role: $0.role, content: $0.content) }
    }

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func validatedTarotClarification(_ payload: TarotClarificationPayload?, for run: OracleRun) -> TarotClarificationSuggestion? {
        guard let value = payload?.value, ReadingContextBuilder.canSuggestTarotClarification(for: run) else { return nil }
        let suggestion = TarotClarificationSuggestion(
            focus: value.focus.trimmingCharacters(in: .whitespacesAndNewlines),
            originalPosition: value.originalPosition?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return suggestion.isValid ? suggestion : nil
    }

    private static func validatedUnderstanding(_ payload: ConversationUnderstandingPayload?, question: String,
                                               references: [ConversationPlanningReference]) -> ConversationUnderstanding? {
        guard let payload else { return nil }
        let ambiguous = ConversationUnderstanding(relation: .ambiguous, resolvedQuestion: question, referenceMessageID: nil)
        guard var value = payload.value else { return ambiguous }
        let resolved = value.resolvedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        value.resolvedQuestion = resolved.isEmpty ? question : String(resolved.prefix(6000))
        if var execution = value.execution {
            guard let evidence = ReadingExecutionPolicy.groundedEvidence(execution.evidence, in: question) else { return ambiguous }
            execution.evidence = evidence
            value.execution = execution
        }
        switch value.relation {
        case .ambiguous:
            return ambiguous
        case .newQuestion:
            value.referenceMessageID = nil
        case .continuation, .changedConditions, .changedParticipants:
            guard let id = value.referenceMessageID, references.contains(where: { $0.messageID == id }) else { return ambiguous }
        }
        return value
    }

    /// Referenced runs are deduplicated and carry routing facts, not whole profile or result snapshots.
    private struct PlanningReferenceContext: Encodable {
        let messages: [Message]
        let runs: [Run]

        init(_ references: [ConversationPlanningReference]) {
            messages = references.map { reference in
                Message(messageID: reference.messageID, role: reference.role, excerpt: String(reference.excerpt.prefix(800)),
                        resolvedQuestion: reference.resolvedQuestion.map { String($0.prefix(800)) }, runID: reference.run?.id)
            }
            var seen = Set<UUID>()
            runs = references.compactMap(\.run).filter { seen.insert($0.id).inserted }.map(Run.init)
        }

        struct Message: Encodable {
            let messageID: UUID
            let role: ChatRole
            let excerpt: String
            let resolvedQuestion: String?
            let runID: UUID?
        }

        struct Run: Encodable {
            let id: UUID
            let question: String
            let subject: String
            let relationship: String?
            let castingDate: Date
            let participants: [[String: String]]
            let methods: [OracleMethod]
            let omittedMethods: [OracleMethod]
            let results: [[String: String]]
            let maySuggestTarotClarification: Bool

            init(_ run: OracleRun) {
                id = run.id
                question = String(run.input.question.prefix(800))
                subject = run.input.subject
                relationship = run.input.relationship.map { String($0.prefix(80)) }
                castingDate = run.input.castingDate
                participants = run.input.readingParticipants.prefix(12).map { person in
                    ["id": person.id.uuidString, "participantLabel": String(person.participantLabel.prefix(80))]
                }
                methods = run.plan.methods
                omittedMethods = (run.plan.omittedMethods ?? []).map(\.method)
                results = run.results.prefix(32).map { result in
                    var entry = ["method": result.method.rawValue, "status": result.status.rawValue]
                    entry["participantID"] = result.participantID?.uuidString
                    return entry
                }
                maySuggestTarotClarification = ReadingContextBuilder.canSuggestTarotClarification(for: run)
            }
        }
    }

    /// Invalid structured understanding must never fall back to an unrelated saved reading.
    private struct ConversationUnderstandingPayload: Decodable {
        let value: ConversationUnderstanding?
        private enum CodingKeys: String, CodingKey { case relation, resolvedQuestion, referenceMessageID, execution }

        init(from decoder: Decoder) {
            do {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // Absence supports old plans. A present null, invalid enum or
                // malformed execution is not an old plan and must fail closed.
                let execution = container.contains(.execution)
                    ? try container.decode(ReadingExecutionIntent.self, forKey: .execution) : nil
                let relation = try container.decode(ConversationUnderstanding.Relation.self, forKey: .relation)
                // Independent messages cannot cite an old turn. An unused
                // empty model placeholder must not invalidate a new question;
                // actual continuation references remain strictly decoded.
                let reference = [.newQuestion, .ambiguous].contains(relation) ? nil
                    : try container.decodeIfPresent(UUID.self, forKey: .referenceMessageID)
                value = ConversationUnderstanding(relation: relation,
                    resolvedQuestion: try container.decode(String.self, forKey: .resolvedQuestion),
                    referenceMessageID: reference, execution: execution)
            } catch {
                value = nil
            }
        }
    }

    /// A malformed optional offer must not discard an otherwise valid answer.
    private struct TarotClarificationPayload: Decodable {
        let value: TarotClarificationSuggestion?

        init(from decoder: Decoder) {
            value = try? TarotClarificationSuggestion(from: decoder)
        }
    }

    private struct PlanPayload: Decodable {
        var action: String?
        var intent: String
        var subject: String
        var methods: [String]?
        var requiredFields: [String]?
        var note: String
        var interactions: [InteractionPayload]?
        var profileUpdates: [ProfileUpdate]?
        var participantIDs: [String]?
        var participantNames: [String]?
        var relationship: String?
        var resumePending: Bool?
        var mandatoryMethods: [String]?
        var tarotClarification: TarotClarificationPayload?
        var understanding: ConversationUnderstandingPayload?

        private enum CodingKeys: String, CodingKey { case action, intent, subject, methods, requiredFields, note, interactions, profileUpdates, participantIDs, participantNames, relationship, resumePending, mandatoryMethods, tarotClarification, understanding }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            action = try? c.decode(String.self, forKey: .action)
            intent = try c.decode(String.self, forKey: .intent)
            subject = try c.decode(String.self, forKey: .subject)
            methods = try? c.decode([String].self, forKey: .methods)
            requiredFields = try? c.decode([String].self, forKey: .requiredFields)
            note = try c.decode(String.self, forKey: .note)
            interactions = try? c.decode([InteractionPayload].self, forKey: .interactions)
            profileUpdates = try? c.decode([ProfileUpdate].self, forKey: .profileUpdates)
            participantIDs = try? c.decode([String].self, forKey: .participantIDs)
            participantNames = try? c.decode([String].self, forKey: .participantNames)
            relationship = try? c.decode(String.self, forKey: .relationship)
            resumePending = try? c.decode(Bool.self, forKey: .resumePending)
            mandatoryMethods = try? c.decode([String].self, forKey: .mandatoryMethods)
            tarotClarification = try? c.decode(TarotClarificationPayload.self, forKey: .tarotClarification)
            understanding = try? c.decode(ConversationUnderstandingPayload.self, forKey: .understanding)
        }
    }
    private struct InteractionPayload: Decodable { var method: String; var kind: String; var prompt: String? }
    private struct SynthesisPayload: Decodable {
        var text: String
        // Older service responses may still contain this field. Preserve only
        // supported explanatory text, never selectable objects or feedback.
        private var alternatives: [LegacyConflictDetail]?
        var tarotClarification: TarotClarificationPayload?

        private enum CodingKeys: String, CodingKey { case text, alternatives, tarotClarification }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            alternatives = try? c.decode([LegacyConflictDetail].self, forKey: .alternatives)
            tarotClarification = try? c.decode(TarotClarificationPayload.self, forKey: .tarotClarification)
        }

        private struct LegacyConflictDetail: Decodable {
            var title: String
            var body: String
            var supportingMethods: [String]
        }

        func textWithLegacyConflictDetails(supported: Set<OracleMethod>) -> String {
            var seen = Set<String>()
            let details = (alternatives ?? []).compactMap { item -> String? in
                let methods = Set(item.supportingMethods.compactMap(OracleMethod.init(rawValue:)))
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !methods.isDisjoint(with: supported), !title.isEmpty, !body.isEmpty,
                      !(text.contains(title) && text.contains(body)) else { return nil }
                let detail = String(title.prefix(80)) + "：" + String(body.prefix(1_000))
                return seen.insert(detail).inserted ? detail : nil
            }
            return ([text] + details).joined(separator: "\n\n")
        }
    }
    private struct CompletionEnvelope: Decodable {
        var model: String?
        var usage: DeepSeekTokenUsage?
        var choices: [Choice]
        struct Choice: Decodable { var message: Message; var finish_reason: String? }
        struct Message: Decodable { var content: String? }
    }
}

enum AIPlanRouting {
    static func limitsMethods(_ question: String) -> Bool {
        question.range(of: #"(?:只|仅)(?:要|用|看|算|按|采用)"#, options: .regularExpression) != nil
            || EnglishConversation.matches(question, #"\b(?:only|just)\b"#)
    }

    static func requestsCombinedMethods(_ question: String) -> Bool {
        (["混合", "结合", "综合", "配合"].contains(where: question.contains)
            || EnglishConversation.matches(question, #"\b(?:combine|mix|combined|mixed)\b"#))
            && (question.range(of: #"其他方法|其它方法|别的方法|多种方法|所有方法|多法"#, options: .regularExpression) != nil
                || EnglishConversation.matches(question, #"\b(?:other|multiple|all) methods\b"#))
    }

    static func asksForMethodSelection(_ note: String) -> Bool {
        guard note.range(of: #"哪件事|哪个问题|哪一?位|哪个人|谁的|\bwhich (?:person|topic|question)\b"#,
                         options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        return note.range(of: #"哪(?:一|几)?(?:种|个)方法|选(?:择|一下)?推演方法|\b(?:which|what) (?:reading |divination )?methods?\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isConcreteReadingQuestion(_ text: String) -> Bool {
        ["财运", "运势", "事业", "工作", "感情", "婚姻", "恋爱", "姻缘", "合作", "友情", "出行", "计划", "选择", "算卦", "问卦", "算命", "起卦", "塔罗", "六爻", "八字", "紫微"].contains(where: text.contains)
            || !EnglishConversation.requestedMethods(in: text, additive: false).isEmpty
            || EnglishConversation.matches(text, #"\b(?:give me a reading|do a reading|read my cards|should (?:i|we)|what (?:should|can) (?:i|we) do|what can (?:i|we) expect|how (?:will|should) (?:i|we))\b"#)
    }

    static func shouldOpenFormForProfileRequest(action: String?, note: String, question: String, hasPendingQuestion: Bool) -> Bool {
        guard !["intake", "supplement"].contains(normalizedAction(action)), hasPendingQuestion || isConcreteReadingQuestion(question) else { return false }
        let asksWhichSubject = ["你还是", "自己还是", "本人还是", "哪件事", "哪个问题", "哪位的"].contains(where: note.contains)
            || EnglishConversation.matches(note, #"\b(?:you or|yourself or|which (?:person|topic|question|situation))\b"#)
        guard !asksWhichSubject else { return false }
        let mentionsField = ["姓名", "名字", "生辰", "生日", "出生", "时区", "性别", "经纬度", "公历", "农历", "起卦地", "起局地", "所在地", "当前地点"].contains(where: note.contains)
            || EnglishConversation.matches(note, #"\b(?:birth (?:date|time|place)|birthday|date of birth|time of birth|place of birth|time ?zone|gender|coordinates|full name|(?:current|casting) (?:location|place))\b"#)
        let requestsCastingLocation = ReadingContinuationPolicy.requestedCalculationMethods(in: question)
            .contains { [.qimen, .xiaoliuren, .meihua, .liuyao].contains($0) }
            && EnglishConversation.matches(note, #"\b(?:location|place)\b"#)
        let asksForData = ["请", "告诉", "提供", "填写", "补充", "确认", "什么", "哪个", "哪里", "哪年", "？", "?"].contains(where: note.contains)
            || EnglishConversation.matches(note, #"\b(?:please (?:enter|provide|confirm|share)|tell me|what is|what are|where were|when were)\b"#)
        return (mentionsField || requestsCastingLocation) && asksForData
    }

    static func normalizedAction(_ value: String?) -> String {
        guard let value, ["intake", "supplement", "reply", "clarify", "collect"].contains(value) else { return "intake" }
        return value
    }

    static func selectedMethods(action: String, requested: [String], available: Set<OracleMethod>) -> [OracleMethod] {
        let action = normalizedAction(action)
        guard ["intake", "supplement"].contains(action) else { return [] }
        var seen = Set<OracleMethod>()
        return requested.compactMap(OracleMethod.init(rawValue:))
            .filter { available.contains($0) && seen.insert($0).inserted }
    }
}

struct DeepSeekSSEChunk: Sendable {
    var content: String
    var finishReason: String?
    var isDone: Bool
    var model: String? = nil
    var usage: DeepSeekTokenUsage? = nil

    static func decode(_ event: String) throws -> DeepSeekSSEChunk {
        if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return DeepSeekSSEChunk(content: "", finishReason: nil, isDone: true)
        }
        guard let data = event.data(using: .utf8) else { throw DeepSeekError.invalidResponse }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if let failure = envelope.error {
            throw AIGatewayFailure.error(status: 502, code: failure.code ?? "")
        }
        return DeepSeekSSEChunk(content: (envelope.choices ?? []).compactMap { $0.delta?.content }.joined(),
                                finishReason: envelope.choices?.compactMap(\.finish_reason).last, isDone: false,
                                model: envelope.model, usage: envelope.usage)
    }

    private struct Envelope: Decodable {
        var model: String?
        var usage: DeepSeekTokenUsage?
        var choices: [Choice]?
        var error: ProviderError?
        struct Choice: Decodable { var delta: Delta?; var finish_reason: String? }
        // reasoning_content is deliberately absent from this model.
        struct Delta: Decodable { var content: String? }
        struct ProviderError: Decodable {
            var code: String?
            private enum CodingKeys: String, CodingKey { case code }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                code = try? values.decode(String.self, forKey: .code)
            }
        }
    }
}

/// Providers send one complete JSON object per `data:` line. AsyncBytes.lines can
/// omit blank separators, so a complete object must be consumed immediately.
/// A genuinely split JSON event is accumulated only until its braces balance.
struct DeepSeekSSEFramer {
    private var pending = ""

    mutating func push(_ line: String) throws -> DeepSeekSSEChunk? {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard pending.isEmpty else { throw DeepSeekError.truncated }
            return nil
        }
        let payload: String
        if line.hasPrefix("data:") {
            payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            // A provider can return a standalone JSON error after HTTP 200.
            payload = line.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // SSE comments, event names, ids and retry metadata carry no content.
            return nil
        }
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" {
            guard pending.isEmpty else { throw DeepSeekError.truncated }
            return try DeepSeekSSEChunk.decode(payload)
        }
        pending += pending.isEmpty ? payload : "\n" + payload
        guard pending.utf8.count <= 2_000_000 else { throw DeepSeekError.invalidResponse }
        guard try isCompleteJSON(pending) else { return nil }
        let event = pending
        pending = ""
        return try DeepSeekSSEChunk.decode(event)
    }

    func finish() throws {
        guard pending.isEmpty else { throw DeepSeekError.truncated }
    }

    private func isCompleteJSON(_ value: String) throws -> Bool {
        var depth = 0
        var insideString = false
        var escaped = false
        var began = false
        for byte in value.utf8 {
            if insideString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { insideString = false }
                continue
            }
            if byte == 34 { insideString = true }
            else if byte == 123 || byte == 91 { depth += 1; began = true }
            else if byte == 125 || byte == 93 {
                depth -= 1
                if depth < 0 { throw DeepSeekError.invalidResponse }
            }
        }
        return began && depth == 0 && !insideString
    }
}

/// Decodes the top-level JSON `text` string incrementally. Unicode scalars, rather
/// than Character offsets, preserve combining marks and emoji split across chunks.
struct JSONTextStreamExtractor {
    private enum State { case scanning, key, skippingString, text, finished }
    private enum PropertyPhase { case key, colon, value, afterValue }
    private var state: State = .scanning
    private var phase: PropertyPhase = .key
    private var depth = 0
    private var key = ""
    private var rawKey = ""
    private var escaped = false
    private var unicodeDigits = 0
    private var unicodeValue: UInt32 = 0
    private var highSurrogate: UInt32?

    mutating func append(_ piece: String) -> String? {
        var output = ""
        for scalar in piece.unicodeScalars {
            switch state {
            case .finished:
                return output.isEmpty ? nil : output
            case .key:
                rawKey.unicodeScalars.append(scalar)
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" {
                    key = (try? JSONDecoder().decode(String.self, from: Data(rawKey.utf8))) ?? ""
                    rawKey = ""
                    phase = .colon
                    state = .scanning
                }
            case .skippingString:
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" { state = .scanning }
            case .text:
                consumeText(scalar, into: &output)
            case .scanning:
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                switch scalar {
                case "{", "[":
                    if depth == 1 { phase = .afterValue }
                    depth += 1
                case "}", "]":
                    depth -= 1
                    if depth <= 0 { state = .finished }
                case ",":
                    if depth == 1 { phase = .key; key = "" }
                case ":":
                    if depth == 1 && phase == .colon { phase = .value }
                case "\"":
                    escaped = false
                    if depth == 1 && phase == .key {
                        rawKey = "\""
                        state = .key
                    } else {
                        state = depth == 1 && phase == .value && key == "text" ? .text : .skippingString
                        if depth == 1 { phase = .afterValue }
                    }
                default:
                    if depth == 1 && phase == .value { phase = .afterValue }
                }
            }
        }
        return output.isEmpty ? nil : output
    }

    private mutating func consumeText(_ scalar: Unicode.Scalar, into output: inout String) {
        if unicodeDigits > 0 {
            let digit: UInt32
            switch scalar.value {
            case 48...57: digit = scalar.value - 48
            case 65...70: digit = scalar.value - 55
            case 97...102: digit = scalar.value - 87
            default: state = .finished; return
            }
            unicodeValue = unicodeValue * 16 + digit
            unicodeDigits -= 1
            guard unicodeDigits == 0 else { return }
            if (0xD800...0xDBFF).contains(unicodeValue) {
                guard highSurrogate == nil else { state = .finished; return }
                highSurrogate = unicodeValue
            } else if (0xDC00...0xDFFF).contains(unicodeValue) {
                guard let high = highSurrogate else { state = .finished; return }
                emit(0x10000 + (high - 0xD800) * 0x400 + unicodeValue - 0xDC00, into: &output)
                highSurrogate = nil
            } else {
                guard highSurrogate == nil else { state = .finished; return }
                emit(unicodeValue, into: &output)
            }
            return
        }
        if escaped {
            escaped = false
            if scalar == "u" { unicodeDigits = 4; unicodeValue = 0; return }
            guard highSurrogate == nil else { state = .finished; return }
            switch scalar {
            case "\"", "\\", "/": output.unicodeScalars.append(scalar)
            case "b": emit(8, into: &output)
            case "f": emit(12, into: &output)
            case "n": emit(10, into: &output)
            case "r": emit(13, into: &output)
            case "t": emit(9, into: &output)
            default: state = .finished
            }
        } else if scalar == "\\" {
            escaped = true
        } else if scalar == "\"" {
            state = .finished
        } else {
            guard highSurrogate == nil, scalar.value >= 0x20 else { state = .finished; return }
            output.unicodeScalars.append(scalar)
        }
    }

    private func emit(_ value: UInt32, into output: inout String) {
        if let scalar = Unicode.Scalar(value) { output.unicodeScalars.append(scalar) }
    }
}
