import Foundation

/// Keeps unchanged method/person calculations while allowing a reading to gain new methods.
enum ReadingContinuationPolicy {
    private static let methodNames: [(OracleMethod, String)] = [
        (.bazi, "八字|四柱"), (.ziwei, "紫微斗数|紫微|紫薇"), (.liuyao, "六爻"),
        (.meihua, "梅花易数|梅花"), (.qimen, "奇门遁甲|奇门"), (.xiaoliuren, "小六壬"),
        (.chenggu, "称骨"), (.xingming, "姓名五格|五格|姓名"),
        (.astrology, "西方占星|占星|星盘"), (.tarot, "塔罗牌|塔罗|塔羅|tarot")
    ]
    private static let recastPatterns = [
        #"(?:重算|重起一卦|重抽(?:(?:一次|一组|三张|一下)牌?|牌|(?=(?:吧|吗|呢|好吗|可以吗|谢谢)?$)))"#,
        #"(?:重新|重来一次|从头)(?:再)?(?:起卦|算卦|算命|推演|占卜|抽(?:(?:一次|一组|三张|一下)牌?|牌|(?=(?:吧|吗|呢|好吗|可以吗|谢谢)?$))|掷卦|(?:投掷|投|掷)(?:一次|六次)?|六掷(?:成卦)?|算(?:一遍|一次|一下|一卦|算)?)"#,
        #"(?:再|另外|另)(?:帮我|替我|给我)?(?:算(?:一卦|一次|一下|算)|起(?:一|个|一轮)?卦|占卜(?:一次|一下)?|抽(?:(?:一次|一组|三张)牌?|牌)|(?:投掷|投|掷)(?:一次|六次))"#,
        #"再来(?:一卦|一次占卜|一轮抽牌)"#
    ]
    private static let newQuestionPattern = #"(?:换个新?|换一个新?|另一个|另外一个|另问(?:一件|一桩|个|一个)?|换一件|问(?:个|一个|一件)新)(?:问题|事|事情)"#
    private static let personSwitch = #"(?:换(?:个|一个|一位|位|成另一个|成另一位|成别的|成其他)人|(?:换成|改看|改问|改算)(?:(?:我自己|本人|我|他|她|别人|其他人|另一个人|另一位)(?=$|[的呢吧了])|我(?:的)?(?:同事|同学|朋友|对象|家人|爸爸|妈妈)))"#
    private static let calculationVerb = #"(?:计算|测算|算(?:一下|一次|一遍|一算|算)?|看看|看一下|看一看|排盘(?:分析)?|推演(?:一下)?|试试看|试试|试一下|试一试|尝试|分析(?:一下)?|解读(?:一下)?|参考(?:一下)?|测(?:一测|一下|测)|占卜|起(?:一|个|一轮)?卦|抽(?:(?:一次|一组|三张)牌?|牌))"#
    private static let calculationModifiers = #"(?:再|也|来|帮我|替我|给我|仔细|好好|认真)*"#

    enum ScopeChange: Equatable { case none, explicit, inferred }

    struct ParticipantIntent: Equatable {
        let names: [String]
        let excludedNames: [String]
        let includesSelf: Bool
        let isGroup: Bool
        let refersToOther: Bool
    }

    static func participantIntent(in question: String, profiles: [OracleProfile]) -> ParticipantIntent {
        let references = ProfileDirectory.participantReferences(in: question, profiles: profiles)
        let englishGroup = EnglishConversation.matches(question, #"\b(?:both of us|the two of us|between us|our (?:relationship|compatibility|partnership)|my (?:friend|partner|spouse) and (?:i|me)|(?:me|myself) and)\b"#)
        let selfWithAnother = englishGroup || hasAffirmativeMatch(in: question, patterns: [
            #"(?:我(?:自己)?|本人)(?:和|跟|与|同)(?=[\p{Han}A-Za-z])"#,
            #"(?:和|跟|与|同)(?:我(?:自己)?|本人)(?=$|的|合|适合|一起|相处|关系|沟通|合作)"#
        ])
        let selfTarget = EnglishConversation.matches(question, #"\b(?:for me instead|about me instead|what about me|(?:only|just) me|my (?:career|job|relationship|finances|chart|birth|health))\b"#) || hasAffirmativeMatch(in: question, patterns: [
            #"(?:换成|改看|改问|改算|单独看|只看)(?:我自己|本人|我)(?=$|[的呢吧了])"#,
            #"^(?:那|还有|至于)?(?:我|我自己|本人)(?:呢|怎么样|怎么说)$"#,
            #"我(?:自己)?(?:的|最近的?|今年的?|明年的?|接下来的?)?(?:运势|事业|工作|感情|财运|婚姻|学业|面试)"#
        ])
        let groupWording = hasAffirmativeMatch(in: question, patterns: [#"(?:我们俩|我们两|我们|咱俩|我俩|他俩|她俩|两个人|两位|两人|双方|合婚|合盘)"#])
        let comparesPeople = hasAffirmativeMatch(in: question, patterns: [
            #"(?:关系|友情|姻缘|合不合|相处|沟通|合作|合伙|合婚|合盘|配不配|分别|各自|两个人都)"#,
            #"(?:我们俩|我们两个人|我俩|双方)(?:到底|是不是)?合适(?:吗|呢)?$"#
        ])
        let group = references.included.count > 1 || selfWithAnother && (!references.included.isEmpty || comparesPeople)
            || groupWording && comparesPeople || englishGroup
        let otherTarget = EnglishConversation.matches(question, #"\b(?:for|about) (?:my (?:friend|partner|spouse|sister|brother|mother|father|child)|someone else|another person|him|her|them)\b"#) || hasAffirmativeMatch(in: question, patterns: [
            #"(?:替|给|看|问|算|换成|改看|改问|改算)(?:我(?:的)?)?(?:朋友|同事|同学|家人|对象|伴侣|父亲|母亲|爸爸|妈妈|孩子|儿子|女儿|他|她|别人|另一位|另一(?:个)?人)(?=$|的|呢|吧|了|工作|事业|感情|运势|看看|怎么样)"#,
            #"(?:^|替|给|看(?:看|一下)?|问(?:一下)?|算(?:一下)?)我(?:的)?(?:朋友|同事|同学|家人|对象|伴侣|父亲|母亲|爸爸|妈妈|孩子|儿子|女儿)(?!圈|关系|缘|运|们)(?=[\p{Han}]{2,6}(?:$|的|工作|事业|感情|运势|最近|下周|呢|怎么样))"#,
            #"^(?:那|还有|至于)?(?:他|她|我(?:的)?(?:朋友|同事|同学|对象|爸爸|妈妈))(?:呢|怎么样|怎么说)$"#,
            personSwitch
        ])
        return ParticipantIntent(names: references.included, excludedNames: references.excluded,
                                 includesSelf: selfTarget || group && (selfWithAnother || question.contains("我们")),
                                 isGroup: group, refersToOther: !selfTarget && (otherTarget || group && selfWithAnother))
    }

    /// Only clear instructions qualify here. A pending draw can use this
    /// independently of the more conservative conversational inference.
    static func explicitlyChangesScope(_ question: String, profiles: [OracleProfile] = []) -> Bool {
        let topicSwitch = #"(?:换(?:个|一个)?(?:新)?话题|另起(?:个|一个)?话题|(?:聊|说|问)(?:点|些)?别的(?:问题|话题|事)?|改问(?:另一个|另一件|别的|其他)(?:问题|事|话题))"#
        if EnglishConversation.changesScope(question) || hasAffirmativeMatch(in: question, patterns: [newQuestionPattern, topicSwitch, personSwitch]) { return true }
        guard !profiles.isEmpty else { return false }
        let targets = ProfileDirectory.participantReferences(in: question, profiles: profiles).included
        return targets.contains { name in
            let exactName = NSRegularExpression.escapedPattern(for: name.filter { !$0.isWhitespace })
            return EnglishConversation.matches(question, #"^\s*(?:please\s+)?(?:switch to|ask about)\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#) || hasAffirmativeMatch(in: question, patterns: [#"(?:换成|改成|改看|改问|改算|转而看)"# + exactName + #"(?=$|[的呢吧了]|工作|事业|感情|运势|合不合|怎么样)"#])
        }
    }

    static func scopeChange(question: String, run: OracleRun?, profiles: [OracleProfile], selfProfileID: UUID? = nil) -> ScopeChange {
        var seen = Set<UUID>()
        let savedPeople = run?.input.readingParticipants.filter { !$0.resolvedName.isEmpty } ?? []
        let directory = (profiles + savedPeople).filter { seen.insert($0.id).inserted }
        if explicitlyChangesScope(question, profiles: directory) { return .explicit }
        guard let run, !isSavedTarotExplanation(question),
              question.range(of: #"[？?]|(?:呢|吗|么)$|看看|想问|怎么|如何|怎样|能否|要不要|会不会|能不能|该不该|合不合|适不适合"#, options: .regularExpression) != nil else { return .none }

        let people = participantIntent(in: question, profiles: directory)
        let existingIDs = Set(savedPeople.map(\.id))
        var requestedIDs = Set(ProfileDirectory.resolve(names: people.names, in: directory).ids)
        if people.includesSelf, let selfProfileID { requestedIDs.insert(selfProfileID) }
        let wasGroup = run.input.subject == "多人" || existingIDs.count > 1
        if !requestedIDs.subtracting(existingIDs).isEmpty || people.isGroup && !wasGroup { return .inferred }
        if wasGroup, !people.isGroup, requestedIDs.count == 1,
           !people.excludedNames.isEmpty || hasAffirmativeMatch(in: question, patterns: [#"(?:只|仅|单独)(?:看|问|算)"#]) { return .inferred }
        if !people.isGroup, (people.includesSelf && run.input.subject == "他人")
            || (people.refersToOther && !people.includesSelf && run.input.subject == "本人") { return .inferred }

        let oldTopics = topicCategories(in: run.input.question)
        let newTopics = topicCategories(in: question)
        return !oldTopics.isEmpty && !newTopics.isEmpty && oldTopics.isDisjoint(with: newTopics) ? .inferred : .none
    }

    private static func topicCategories(in text: String) -> Set<Int> {
        let patterns = [
            "工作|职场|事业|入职|离职|面试|求职|跳槽|升职|辞职|转行|转岗|上班|裁员",
            "感情|对象|恋爱|婚姻|复合|分手|离婚|伴侣|男朋友|女朋友|相亲|前任|吵架|暧昧",
            "出行|出差|旅游|旅行|飞机|航班|高铁|行程|路上|车票",
            "钱财|财运|收入|存款|理财|投资|炒股|借钱|还钱|欠款|买卖|开店",
            "学业|考试|考研|考公|升学|学习|分数|志愿|成绩",
            "健康|身体|睡眠|失眠|生病|体检|医院|就医",
            "搬家|买房|租房|装修|房子"
        ]
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n")).filter {
            $0.filter { !$0.isWhitespace }.range(of: #"^(?:我)?(?:先不|暂不|不再|不想|不要|不用|不|别)(?:聊|看|问|算|说|讨论|谈)"#, options: .regularExpression) == nil
        }
        return Set(patterns.indices.filter { index in clauses.contains { $0.range(of: patterns[index], options: .regularExpression) != nil } })
    }

    static func shouldReuse(question: String, run: OracleRun?, pendingPlan: OraclePlan?) -> Bool {
        guard pendingPlan == nil, let run,
              run.results.contains(where: { $0.status == .complete || $0.status == .partial }),
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !explicitlyRequestsNewReading(question) && requestedAdditionalMethods(in: question).isEmpty
            && scopeChange(question: question, run: run, profiles: []) == .none
    }

    /// A method's numeric output depends on its own inputs, not unrelated profile edits.
    /// The caller controls same-question scope and verifies the plugin version before reuse.
    static func reusableResults(from run: OracleRun, for input: OracleInput, methods: [OracleMethod]) -> [OracleResult] {
        let originalPeople = run.input.readingParticipants
        let selected = Set(methods)
        var reusable: [OracleResult] = []
        for method in OracleMethod.allCases where selected.contains(method) {
            if method.usesPersonalProfile {
                for person in input.readingParticipants {
                    guard let original = originalPeople.first(where: { $0.id == person.id }),
                          sameInputs(method: method, original: run.input, candidate: input, oldPerson: original, newPerson: person),
                          var result = run.results.last(where: {
                              $0.method == method && isUsable($0) &&
                              ($0.participantID == original.id || ($0.participantID == nil && originalPeople.count == 1))
                          }) else { continue }
                    // Old single-person records did not store participant identity on results.
                    result.participantID = person.id
                    result.participantName = person.participantLabel
                    reusable.append(result)
                }
            } else if sameInputs(method: method, original: run.input, candidate: input,
                                 oldPerson: run.input.profile, newPerson: input.profile),
                      let result = run.results.last(where: { $0.method == method && isUsable($0) }) {
                reusable.append(result)
            }
        }
        return reusable
    }

    /// Named calculations can be used on a fresh or existing question. An explicit
    /// addition also asks to keep the current question.
    static func requestedAdditionalMethods(in question: String, requiresAdditiveWording: Bool = false) -> [OracleMethod] {
        guard !explicitlyChangesScope(question), !EnglishConversation.requestsRecast(question),
              !requestsReplacementTarotSpread(question) else { return [] }
        let namedMethod = "(?:" + methodNames.map { $0.1 }.joined(separator: "|") + ")"
        // A generic "再帮我算一下" can be the second half of a supplement.
        // Only a concrete fresh draw, restart or changed question overrides it.
        let freshScopePatterns = [recastPatterns[0], recastPatterns[1], recastPatterns[3],
            newQuestionPattern,
            #"(?:再|另外|另)(?:帮我|替我|给我)?(?:起(?:一|个|一轮)?卦|抽(?:(?:一次|一组|三张)牌?|牌)|(?:投掷|投|掷)(?:一次|六次))"#,
            #"(?:改用|换用|改成|换成|再用)"# + namedMethod + #".{0,6}(?:起(?:一|个|一轮)?卦|抽(?:(?:一次|一组|三张)牌?|牌)|占卜)"#
        ]
        guard !hasAffirmativeMatch(in: question, patterns: freshScopePatterns) else { return [] }
        return requestedCalculationMethods(in: question, requiresAdditiveWording: requiresAdditiveWording)
    }

    /// Extract explicit method commands independently of whether they belong to
    /// a new question or supplement. A mention or explanation is not a command.
    static func requestedCalculationMethods(in question: String, requiresAdditiveWording: Bool = false) -> [OracleMethod] {
        let english = EnglishConversation.requestedMethods(in: question, additive: requiresAdditiveWording, allowFreshScope: true)
        let clauses = question.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n"))
        let additions = #"(?:加上|加个|加一个|加入|再加|增加|补算|补个|补一个|补上|补一份)"#
        let namedMethod = "(?:" + methodNames.map { $0.1 }.joined(separator: "|") + ")"
        let join = #"(?:、|以及|和|与|及|加|配合)"#
        let calculationEnd = #"(?:一起|一并|分别|都)?"# + calculationModifiers + calculationVerb
        var requested = Set<OracleMethod>()
        for clause in clauses {
            let compact = clause.filter { !$0.isWhitespace }
            guard !isMethodConsultationClause(compact) else { continue }
            let declined = declinedMethods(in: compact)
            requested.subtract(declined)
            if !requiresAdditiveWording { requested.formUnion(bareMethodChange(in: compact).filter { !declined.contains($0) }) }
            let fullRange = NSRange(compact.startIndex..<compact.endIndex, in: compact)
            for (method, names) in methodNames {
                guard !declined.contains(method) else { continue }
                // "姓名资料" is an ordinary profile field, not a calculation request.
                let name = "(?:" + (method == .xingming ? "姓名五格|五格|姓名学|姓名数理" : names) + ")"
                var patterns = [
                    additions + ".{0,20}" + name,
                    #"(?:再用|也用|再按|也按|再根据)"# + name + calculationModifiers + calculationVerb,
                    name + #"(?:也|再)"# + calculationModifiers + calculationVerb
                ]
                if !requiresAdditiveWording {
                    patterns += [
                        #"(?:用|按|按照)"# + name + calculationModifiers + calculationVerb,
                        #"(?:再|也)?(?:帮我|替我|给我)?(?:计算|测算|算(?:一下|一次|一遍|算)?|试试|试一下|试一试|尝试)(?:用|按|按照)?"# + name,
                        #"(?:用|按|按照)"# + "(?:" + namedMethod + join + ")*" + name
                            + "(?:" + join + namedMethod + ")*" + calculationEnd,
                        #"(?:只|仅)(?:要|用|选|使用)"# + "(?:" + namedMethod + join + ")*" + name,
                        #"(?:用|按|按照)"# + "(?:" + namedMethod + join + ")*" + name
                            + "(?:" + join + namedMethod + #")*(?:吧|就好|就行|即可)?$"#
                    ]
                }
                for pattern in patterns {
                    guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                    for match in expression.matches(in: compact, range: fullRange) {
                        guard let range = Range(match.range, in: compact) else { continue }
                        let prefix = String(compact[..<range.lowerBound].suffix(20))
                        let suffix = String(compact[range.upperBound...].prefix(16))
                        let matched = String(compact[range])
                        // A command may name several methods, with a later method negated.
                        guard let mention = matched.range(of: name, options: [.regularExpression, .caseInsensitive]) else { continue }
                        let mentionPrefix = String(matched[..<mention.lowerBound].suffix(20))
                        let negation = #"(?:不|别|莫|不要|不用|无需|不必|不想|不需要|不是要|并非要|没让你|没有让你|拒绝).{0,5}$"#
                        let explanation = #"(?:为什么|为何|怎么|如何|怎样|什么时候|什么情况|何时|是否必须|是不是必须|难道|一定要|解释|说明|介绍|什么是|想知道|想了解).{0,8}$"#
                        let explainsSuffix = #"^(?:[”\"」』])?(?:是什么|是什么意思|的意思|的必要|的区别|的原理|的步骤|有必要吗|没必要|没有必要|怎么算|怎么排)"#
                        let joinsAnotherRequest = prefix.range(of: #"(?:并且?|同时|顺便|然后)(?:也|再|请)?$"#, options: .regularExpression) != nil
                        guard prefix.range(of: negation, options: .regularExpression) == nil,
                              mentionPrefix.range(of: negation, options: .regularExpression) == nil,
                              joinsAnotherRequest || prefix.range(of: explanation, options: .regularExpression) == nil,
                              suffix.range(of: explainsSuffix, options: .regularExpression) == nil else { continue }
                        requested.insert(method)
                    }
                }
            }
        }
        return OracleMethod.allCases.filter { requested.contains($0) || english.contains($0) }
    }

    private static func declinedMethods(in clause: String) -> Set<OracleMethod> {
        let named = "(?:" + methodNames.map { $0.1 }.joined(separator: "|") + ")"
        let join = #"(?:、|以及|和|与|及|加)"#
        let refusal = #"(?:不要|不用|别用|不选|排除|不需要)(?:再|也|用|按|考虑|计算|算)?"#
        return Set(methodNames.compactMap { method, aliases in
            let pattern = refusal + "(?:" + named + join + ")*(?:" + aliases + ")"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            let matches = regex.matches(in: clause, range: NSRange(clause.startIndex..<clause.endIndex, in: clause))
            return matches.contains { match in
                guard let range = Range(match.range, in: clause) else { return false }
                return String(clause[..<range.lowerBound]).range(of: #"(?:不是|并非|并不是|没有说|没说)$"#, options: .regularExpression) == nil
            } ? method : nil
        })
    }

    /// Preparation and capability questions are answers about a method, rather
    /// than authorization to calculate. A separate affirmative command survives.
    static func isMethodConsultation(_ question: String) -> Bool {
        let clauses = question.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n"))
        return clauses.contains(where: isMethodConsultationClause)
            && requestedCalculationMethods(in: question).isEmpty
    }

    private static func isMethodConsultationClause(_ clause: String) -> Bool {
        let compact = clause.filter { !$0.isWhitespace }
        if compact.range(of: #"^(?:我)?(?:只(?:是)?|先)(?:问问|问一下|了解一下|咨询一下)(?:而已)?$"#, options: .regularExpression) != nil { return true }
        let method = "(?:" + methodNames.map { $0.1 }.joined(separator: "|") + ")"
        let fields = #"(?:资料|信息|字段|生辰|生日|出生日期|出生时间|出生时辰|时辰|性别|排盘性别|姓名|出生地|时区)"#
        let preparation = method + calculationModifiers + "(?:" + calculationVerb + ")?"
            + #"(?:的话|之前|前)?(?:还|先)?(?:需要|要|需不需要|要不要)(?:先)?(?:准备|提供|填写|补充|知道)?(?:什么|哪些|啥|多少|我的)?"#
            + "(?:" + fields + #"|(?=[吗么呢？?]|$))"#
        let fieldQuestion = #"(?:为什么|为何|需不需要|要不要|必须|是否必须).{0,8}"# + fields
            + "|" + fields + #".{0,6}(?:是必填|必须填|有必要|有什么用|为什么|必须吗|必填吗)"#
        let definition = method + #"(?:是什么|是什么意思|是干什么的|有什么用|能做什么|能算什么|的原理|的步骤|怎么算|怎么用)"#
        let comparison = method + #"(?:和|与|跟|、)"# + method + #"(?:有何区别|有什么区别|的区别|差别是什么)"#
        return compact.range(of: preparation + "|" + fieldQuestion + "|" + definition + "|" + comparison,
                             options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A short method selection without a subject can continue the current
    /// question even when there is no remote planner to disambiguate it.
    static func isMethodOnlyRequest(_ question: String) -> Bool {
        if !EnglishConversation.bareMethodChange(question).isEmpty { return true }
        let compact = question.filter { !$0.isWhitespace }
        guard !requestedCalculationMethods(in: question).isEmpty else { return false }
        let namedMethod = "(?:" + methodNames.map { $0.1 }.joined(separator: "|") + ")"
        let list = namedMethod + #"(?:(?:、|以及|和|与|及|加|配合)"# + namedMethod + ")*"
        let prefix = #"^(?:那|就|还是|这次|这回|你|请|请你|麻烦|麻烦你|帮我|替我|给我|我想|我要|可以|能否|只|仅|必须)*(?:再|也)?(?:用|按|按照|只要|仅要|只选|仅选)"#
        let exclusion = #"(?:[，,]?(?:但|并|而)?(?:不要|不用|别用|不选)"# + list + ")?"
        let suffix = #"(?:一起|一并|分别|都)?(?:"# + calculationModifiers + calculationVerb
            + #")?(?:吧|吗|呢|好吗|可以吗|谢谢|就好|就行|即可)?"# + exclusion + #"[。！!？?]*$"#
        return compact.range(of: prefix + list + suffix, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A method switch without a new subject keeps the current question's scope.
    static func bareMethodChange(in question: String) -> [OracleMethod] {
        if EnglishConversation.matches(question, #"\bswitch to\b|\binstead\b"#) {
            let english = EnglishConversation.bareMethodChange(question)
            if !english.isEmpty { return english }
        }
        let compact = question.filter { !$0.isWhitespace }
        let name = "(?:" + methodNames.map { $0.1 }.joined(separator: "|") + ")"
        let prefix = #"^(?:那|就|还是|这次|这回|我想|我要|请(?:你)?|麻烦(?:你)?|帮我|替我|给我|能否|可以)*(?:把(?:方法|方式))?(?:改用|换用|换成|改成|改为|改按)(?:(?:只|仅)(?:用)?)?"#
        let suffix = #"(?:看看|看一下|算一下|算算|排盘|推演)?(?:吧|吗|呢|好吗|可以吗)?[。！!？?]*$"#
        let pattern = prefix + "(" + name + "(?:(?:、|以及|和|与|及|加)" + name + ")*)" + suffix
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: compact, range: NSRange(compact.startIndex..<compact.endIndex, in: compact)),
              let range = Range(match.range(at: 1), in: compact) else { return [] }
        let names = compact[range].replacingOccurrences(of: "以及", with: "、")
            .components(separatedBy: CharacterSet(charactersIn: "、和与及加"))
        return methodNames.compactMap { method, aliases in
            names.contains { $0.range(of: "^(?:" + aliases + ")$", options: [.regularExpression, .caseInsensitive]) != nil } ? method : nil
        }
    }

    /// Keep a narrow local path for explanations of named cards in the saved
    /// spread. Mixed questions and requests for further calculation still plan.
    static func isSavedTarotExplanation(_ question: String) -> Bool {
        if EnglishConversation.savedTarotExplanation(question) { return true }
        guard !explicitlyRequestsNewReading(question), requestedAdditionalMethods(in: question).isEmpty else { return false }
        let newCard = #"(?:补抽|加抽|追加|再抽|继续抽|补)(?:[一1１]张(?:塔罗牌?|澄清牌|牌)?|塔罗牌?|澄清牌|牌)"#
        guard !hasAffirmativeMatch(in: question, patterns: [newCard]) else { return false }
        let reference = #"(?:第[一二三四五1-5]张牌|(?:这|那)张牌|现状牌|影响牌|建议牌|澄清牌|补牌|原牌阵|原牌面|原结果)"#
        let explanation = #"(?:解释|解读|理解|含义|意思|说明|为什么|为何|关系|正位|逆位|联系|指什么)"#
        let mixedIntent = #"(?:不|别|不要|无需|不必|不想)(?:再|只|仅)?(?:解释|解读|说明)|(?:并且?|顺便|另外|同时|还想|接着)(?:问|看看|算|帮我看|补抽|加抽|补算|补一张|补牌)"#
        let optedOut = #"^(?:请)?(?:我(?:并)?不是要|不要|不用|无需|不必|别|不想|先不|暂不|不)(?:现在|再|重新){0,2}(?:补牌|补一张|补抽(?:一张)?牌?|抽(?:一张|一次|三张)?牌?|重抽(?:一张|牌)?|重算|算|八字|紫微|六爻|梅花|奇门|小六壬|称骨|占星|姓名五格)(?:了|吧)?$"#
        var explainsCard = false
        for clause in question.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n")) {
            let compact = clause.filter { !$0.isWhitespace }
            if compact.isEmpty || compact == "谢谢" || compact.range(of: optedOut, options: .regularExpression) != nil { continue }
            guard compact.range(of: reference, options: .regularExpression) != nil,
                  compact.range(of: explanation, options: .regularExpression) != nil,
                  compact.range(of: mixedIntent, options: .regularExpression) == nil else { return false }
            explainsCard = true
        }
        return explainsCard
    }

    private static func isUsable(_ result: OracleResult) -> Bool {
        result.status == .complete || result.status == .partial
    }

    private static func sameInputs(method: OracleMethod, original: OracleInput, candidate: OracleInput,
                                   oldPerson: OracleProfile, newPerson: OracleProfile) -> Bool {
        switch method {
        case .xingming:
            return oldPerson.familyName.trimmingCharacters(in: .whitespacesAndNewlines) == newPerson.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
                && oldPerson.givenName.trimmingCharacters(in: .whitespacesAndNewlines) == newPerson.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
                && sameUnknowns([.surname, .givenName], oldPerson, newPerson)
        case .bazi, .chenggu, .ziwei, .astrology:
            guard sameBirth(oldPerson, newPerson) else { return false }
            let hasTime = oldPerson.birthTimeKnown && !oldPerson.unknownFields.contains(.birthTime)
            if method == .ziwei || (method == .bazi && hasTime) {
                guard oldPerson.sex == newPerson.sex, sameUnknowns([.gender], oldPerson, newPerson) else { return false }
            }
            if method == .ziwei {
                return original.castingDate == candidate.castingDate && oldPerson.currentTimeZoneID == newPerson.currentTimeZoneID
            }
            if method == .astrology, hasTime {
                guard original.castingDate == candidate.castingDate,
                      sameUnknowns([.birthCoordinates], oldPerson, newPerson) else { return false }
                if !oldPerson.unknownFields.contains(.birthCoordinates) {
                    return oldPerson.birthLatitude == newPerson.birthLatitude && oldPerson.birthLongitude == newPerson.birthLongitude
                }
            }
            return true
        case .tarot:
            return original.tarotDraws == candidate.tarotDraws
                && (original.tarotClarificationRounds ?? []) == (candidate.tarotClarificationRounds ?? [])
        case .qimen, .xiaoliuren:
            return original.castingDate == candidate.castingDate && oldPerson.currentTimeZoneID == newPerson.currentTimeZoneID
        case .meihua:
            guard original.castingDate == candidate.castingDate, oldPerson.currentTimeZoneID == newPerson.currentTimeZoneID else { return false }
            let oldUsesNumbers = !oldPerson.unknownFields.contains(.numbers) && original.numbers.count >= 2
            let newUsesNumbers = !newPerson.unknownFields.contains(.numbers) && candidate.numbers.count >= 2
            return oldUsesNumbers == newUsesNumbers && (!oldUsesNumbers || original.numbers == candidate.numbers)
        case .liuyao:
            guard original.castingDate == candidate.castingDate, oldPerson.currentTimeZoneID == newPerson.currentTimeZoneID,
                  original.manualLines == candidate.manualLines else { return false }
            if original.manualLines.isEmpty {
                return original.seed == candidate.seed
                    && (original.castingStyle?.lowercased() ?? "coins") == (candidate.castingStyle?.lowercased() ?? "coins")
            }
            let oldInteracted = original.interactionResponses?.contains { $0.requestID == OracleMethod.liuyao.rawValue } == true
            let newInteracted = candidate.interactionResponses?.contains { $0.requestID == OracleMethod.liuyao.rawValue } == true
            return oldInteracted == newInteracted && (!oldInteracted || (original.castingStyle == "yarrow") == (candidate.castingStyle == "yarrow"))
        }
    }

    private static func sameUnknowns(_ fields: Set<OracleField>, _ original: OracleProfile, _ candidate: OracleProfile) -> Bool {
        original.unknownFields.intersection(fields) == candidate.unknownFields.intersection(fields)
    }

    private static func sameBirth(_ original: OracleProfile, _ candidate: OracleProfile) -> Bool {
        guard sameUnknowns([.birthDate, .birthTimeZone], original, candidate),
              original.birthTimeZoneID == candidate.birthTimeZoneID else { return false }
        let oldHasTime = original.birthTimeKnown && !original.unknownFields.contains(.birthTime)
        let newHasTime = candidate.birthTimeKnown && !candidate.unknownFields.contains(.birthTime)
        guard oldHasTime == newHasTime else { return false }
        if oldHasTime { return original.birthDate == candidate.birthDate }
        guard let oldDate = original.birthDate, let newDate = candidate.birthDate,
              oldDate.timeIntervalSince1970.isFinite, newDate.timeIntervalSince1970.isFinite,
              let zone = TimeZone(identifier: original.birthTimeZoneID) else { return original.birthDate == candidate.birthDate }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day], from: oldDate)
            == calendar.dateComponents([.year, .month, .day], from: newDate)
    }

    static func explicitlyRequestsNewReading(_ question: String) -> Bool {
        if explicitlyChangesScope(question) || EnglishConversation.requestsRecast(question)
            || requestsReplacementTarotSpread(question) { return true }
        // Naming a method or asking how a chart was calculated is not a request to calculate again.
        let namedMethod = "(?:" + methodNames.map { $0.1 }.joined(separator: "|") + ")"
        let patterns = recastPatterns + [
            newQuestionPattern,
            #"(?:帮我|替我|给我|我想|我要|我需要)(?:再)?(?:算(?:一下|一算|算|卦|命)|起(?:一|个|一轮)?卦|占卜|抽牌|推演)"#,
            #"(?:改用|换用|改成|换成)"# + namedMethod + #".{0,6}(?:起(?:一|个|一轮)?卦|算|抽牌|看看|占卜|推演)"#,
            "再用" + namedMethod + #".{0,6}(?:起(?:一|个|一轮)?卦|抽(?:(?:一次|一组|三张)牌?|牌)|占卜)"#
        ]
        return hasAffirmativeMatch(in: question, patterns: patterns)
    }

    private static let oldTarotRejection = #"(?:别用|不要用|不用|不再用|不要|弃用)(?:这组|那组|这副|那副|之前的|原来的|刚才的)?(?:旧牌阵|旧牌|原牌阵|已经抽的牌|已抽的牌|原来的牌)"#
    private static let newTarotSpread = #"(?:换(?:成)?(?:一组|一副|三张)(?:新的?(?:塔罗牌?|牌)?|牌)|(?:再|重新)(?:用|按)(?:塔罗牌?|塔羅|tarot)(?:再)?(?:看看|试试|算算|算一下|计算)?|重新抽(?:一组|三张|一次)?牌?|重抽(?:一组|三张|一次)?牌?)"#

    private static func replacementTarotRemainder(_ question: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: oldTarotRejection),
              let match = expression.firstMatch(in: question, range: NSRange(question.startIndex..<question.endIndex, in: question)),
              let range = Range(match.range, in: question),
              String(question[..<range.lowerBound]).range(of: #"(?:不是|并非|并不是|没说|没有说)$"#, options: .regularExpression) == nil else { return nil }
        return question.replacingCharacters(in: range, with: "")
    }

    private static func requestsReplacementTarotSpread(_ question: String) -> Bool {
        guard let remainder = replacementTarotRemainder(question) else { return false }
        return hasAffirmativeMatch(in: remainder, patterns: [newTarotSpread])
    }

    private static func hasAffirmativeMatch(in question: String, patterns: [String]) -> Bool {
        let clauses = question.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n"))
        for clause in clauses {
            let compact = clause.filter { !$0.isWhitespace }
            let fullRange = NSRange(compact.startIndex..<compact.endIndex, in: compact)
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                for match in expression.matches(in: compact, range: fullRange) {
                    guard let range = Range(match.range, in: compact) else { continue }
                    let prefix = String(compact[..<range.lowerBound].suffix(20))
                    let suffix = String(compact[range.upperBound...].prefix(12))
                    let negated = prefix.range(of: #"(?:不|别|莫|不要|不用|无需|不必|不想|不需要|不是要|并非要|没让你|没有让你|拒绝).{0,5}$"#, options: .regularExpression) != nil
                    let explainsRequest = prefix.range(of: #"(?:为什么|为何|怎么会|什么时候|什么情况|何时|是否必须|是不是必须|难道|一定要|解释一下).{0,8}$"#, options: .regularExpression) != nil
                        || suffix.range(of: #"^(?:[”\"」』])?(?:是什么意思|的意思|的必要|的区别|的原理|的步骤|有必要吗|没必要|没有必要)"#, options: .regularExpression) != nil
                    if !negated && !explainsRequest { return true }
                }
            }
        }
        return false
    }

    /// A command with no new subject keeps the prior question and participants.
    /// Match the entire message rather than guessing which free text is a new subject.
    static func isBareRecastRequest(_ question: String) -> Bool {
        if EnglishConversation.isBareRecast(question) { return true }
        if requestsReplacementTarotSpread(question), let remainder = replacementTarotRemainder(question) {
            let rest = remainder.replacingOccurrences(of: newTarotSpread, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"(?:请|请你|麻烦|你|我想|我要|吧|呢|好吗|可以吗|谢谢)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return rest.isEmpty
        }
        guard explicitlyRequestsNewReading(question) else { return false }
        // A correction can explicitly reject explaining the old result without
        // changing the subject of the fresh draw.
        let commandQuestion = question.replacingOccurrences(
            of: #"[，,。；;]\s*(?:而?不是|并非|而非|不要|不用)(?:在)?(?:解释|解读|沿用)(?:旧(?:的)?|原(?:来(?:的)?)?)(?:牌面|牌阵|牌|结果|解读)[。！!？?]*$"#,
            with: "", options: .regularExpression)
        let compact = commandQuestion.filter { character in
            !character.isWhitespace && !character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        }
        let method = #"(?:六爻|塔罗|塔羅|tarot|梅花|八字|紫微|紫薇|占星|小六壬|奇门|姓名五格|称骨)"#
        let qualification = #"(?:(?:只|仅|必须)?(?:用|按|按照)|改用|换用|再用)"# + method
        let politePrefix = #"(?:请|请你|麻烦|麻烦你|帮我|替我|给我|我想|我要|我是想|我是要|我需要|能否|可以)"#
        let politeSuffix = #"(?:吧|吗|呢|好吗|可以吗|谢谢)"#
        let command = "(?:" + recastPatterns.joined(separator: "|") + ")"
        let pattern = "^(?:" + politePrefix + "|" + qualification + ")*" + command
            + "(?:" + politeSuffix + "|" + qualification + ")*$"
        return compact.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Narrow English commands for the paths that run before the model or while
/// offline. Free-form requests still go through the normal planner.
enum EnglishConversation {
    private static let aliases: [(OracleMethod, String)] = [
        (.bazi, #"ba[ -]?zi|four pillars(?: of destiny)?"#),
        (.ziwei, #"zi[ -]?wei(?: dou[ -]?shu)?|purple star astrology"#),
        (.liuyao, #"liu[ -]?yao|six[ -]line(?: divination)?|i[ -]ching"#),
        (.meihua, #"mei[ -]?hua(?: yi[ -]?shu)?|plum blossom(?: divination)?"#),
        (.qimen, #"qi[ -]?men(?: dun[ -]?jia)?"#),
        (.xiaoliuren, #"xiao[ -]?liu[ -]?ren"#),
        (.chenggu, #"cheng[ -]?gu|bone[ -]weight(?: reading)?"#),
        (.xingming, #"xing[ -]?ming|five[ -]grid(?: name analysis)?|chinese name numerology"#),
        (.astrology, #"western astrology|(?<!purple star )astrology|natal chart"#),
        (.tarot, #"tarot"#)
    ]

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func methods(in text: String, positiveOnly: Bool = true) -> [OracleMethod] {
        let source = text as NSString
        return aliases.compactMap { method, alias in
            guard let regex = try? NSRegularExpression(pattern: "\\b(?:" + alias + ")\\b", options: .caseInsensitive) else { return nil }
            let occurrences = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            return occurrences.contains { occurrence in
                !positiveOnly || !matches(source.substring(to: occurrence.range.location), #"\b(?:not|no|without|skip|avoid|except|don['’]t|do not|never|instead of|rather than)\b[^,.;!?]{0,32}$"#)
            } ? method : nil
        }
    }

    private static let politePrefix = #"^\s*(?:(?:please|(?:can|could|would) you|you (?:must|have to|need to)|i(?:['’]d like| want| need) (?:you )?to)\s+)*"#
    private static let politeSuffix = #"\s*(?:please|thanks)?\s*[.!?]*\s*$"#
    private static let recast = #"(?:(?:recast|redraw|recalculate|redo)(?:\s+(?:it|the (?:reading|spread|cards|chart|hexagram)))?|(?:cast|draw|calculate|do)(?:\s+(?:it|the (?:reading|spread|cards|chart|hexagram)))?\s+again|(?:start|do|give me)\s+(?:a\s+)?(?:new|fresh)\s+(?:reading|spread|draw|cast)|start\s+over|draw\s+(?:three|3)\s+(?:new\s+)?cards(?:\s+again)?)"#
    private static let newTopic = #"(?:let['’]s\s+)?(?:switch\s+(?:the\s+)?(?:topics?|subjects?)|change\s+(?:the\s+)?(?:topics?|subjects?)|(?:ask|talk about|move on to)\s+(?:a\s+)?(?:new|different|another)\s+(?:question|topic|subject)|new question|(?:talk|ask)\s+about\s+something else)"#

    static func isBareTopicSwitch(_ text: String) -> Bool { matches(text, politePrefix + newTopic + politeSuffix) }

    static func changesScope(_ text: String) -> Bool {
        matches(text, politePrefix + newTopic + #"(?:\s*[:.!?,]|\s*$)"#)
            || matches(text, politePrefix + #"(?:switch to|ask about)\s+(?:someone else|another person|my(?:self| (?:friend|partner|sister|brother|mother|father)))\b"#)
    }

    static func requestsRecast(_ text: String) -> Bool {
        matches(text, politePrefix + recast + #"(?:\s*[,.:!?]|\s+|$)"#)
            && !matches(text, #"\b(?:do not|don['’]t|not|never|without)\s+(?:recast|redraw|recalculate|redo|start|draw|cast)\b"#)
    }

    static func isBareRecast(_ text: String) -> Bool { matches(text, politePrefix + recast + politeSuffix) }

    static func requestedMethods(in text: String, additive: Bool, allowFreshScope: Bool = false) -> [OracleMethod] {
        guard allowFreshScope || (!requestsRecast(text) && !changesScope(text)) else { return [] }
        let separators = allowFreshScope ? ";.!?:\n" : ";.!?\n"
        return text.components(separatedBy: CharacterSet(charactersIn: separators)).flatMap { clause -> [OracleMethod] in
            let use = additive
                ? #"(?:add|also use|also include|also calculate|also do|include|supplement (?:it )?with|combine (?:it )?with)\s+"#
                : #"(?:add|use|try|do|calculate|include|also use|also include|switch to|read (?:it )?with)\s+"#
            let namedMethod = "(?:" + aliases.map(\.1).joined(separator: "|") + ")"
            guard matches(clause, politePrefix + #"(?:(?:only|just)\s+)?"# + use + #"(?:(?:only|just)\s+)?"# + namedMethod + #"\b"#),
                  !matches(clause, #"\b(?:instead of|rather than|no need to|don['’]t|do not)\s+(?:add|use|include|calculate)\b"#) else { return [] }
            return methods(in: clause)
        }
    }

    static func bareMethodChange(_ text: String) -> [OracleMethod] {
        let method = "(?:" + aliases.map(\.1).joined(separator: "|") + ")"
        guard matches(text, politePrefix + #"(?:switch to|use)\s+(?:(?:only|just)\s+)?"# + method + #"(?:\s+(?:instead|only))?"# + politeSuffix) else { return [] }
        return methods(in: text)
    }

    static func savedTarotExplanation(_ text: String) -> Bool {
        guard clarifierFocus(text) == nil, !requestsRecast(text), !changesScope(text),
              requestedMethods(in: text, additive: true).isEmpty else { return false }
        return matches(text, #"\b(?:explain|interpret|what does|why does|meaning of|what did|what is|why is)\b"#)
            && matches(text, #"\b(?:(?:advice|influence(?:s)?|current situation|clarifying|first|second|third|that|this) card|saved (?:spread|reading)|original (?:spread|cards?)|reversed|upright)\b"#)
            && !matches(text, #"\b(?:and|also|then)\s+(?:read|calculate|recast|redraw|add|draw|ask about)\b"#)
    }

    static func clarifierFocus(_ text: String) -> String? {
        let command = politePrefix + #"(?:draw|pull|add)\s+(?:(?:me\s+)?(?:a|one|1)\s+)?(?:clarifier|clarifying card|(?:extra|more|additional)\s+card|card\s+to\s+clarify)\b\s*(?:please\s*)?(?:[:.,!?]\s*)?(?:(?:for|on|about|to clarify)\s+)?"#
        guard let range = text.range(of: command, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).prefix(160))
    }

    static func declinesClarifier(_ text: String) -> Bool {
        matches(text, #"\b(?:without|don['’]t|do not|no need to|please don['’]t|skip)\s+(?:draw(?:ing)?|pull(?:ing)?|add(?:ing)?|re-?draw(?:ing)?|a clarifier|another card)\b"#)
    }

    static func replyLanguage(in question: String) -> AppLanguage? {
        let englishPoliteness = #"(?:(?:please|(?:can|could|would|will) you(?: please)?|i(?:['’]d like| want| need)(?: you)? to|also)\s+)*"#
        let englishCommand = #"(?:^|\b(?:but|then|and)\s+)"# + englishPoliteness + #"(?:answer|reply|respond|explain|write|say|summarize|translate)(?:\s+[^,，。；;.!?！？\n]{1,100}?)?\s+(?:in|into)\s+"#
        let englishUse = "^" + englishPoliteness + #"use\s+"#
        let englishUseAction = #"(?:\s+(?:to\s+)?(?:answer|reply|respond|explain|write|say|summarize)\b|\s*$)"#
        let chineseCommand = #"^(?:请|麻烦(?:你)?|你|能否|可以|能不能|可不可以|这次|这回|接下来|然后|还是|我想(?:让你)?|我要|希望你)*(?:用|改用|换用|使用|改成|换成)?"#
        let chineseAction = #"(?:(?:再|重新|简单|简短|详细|清楚|直接)*(?:回答|回复|回应|解释|解读|说明|说|讲|写|表达)|(?:吧|吗|好吗|就好|就行|即可)?$)"#
        let commands: [(AppLanguage, String)] = [
            (.english, englishCommand + #"(English)\b"#),
            (.simplifiedChinese, englishCommand + #"((?:simplified\s+)?Chinese)\b"#),
            (.english, englishUse + #"(English)\b"# + englishUseAction),
            (.simplifiedChinese, englishUse + #"((?:simplified\s+)?Chinese)\b"# + englishUseAction),
            (.english, chineseCommand + #"(英文|英语)"# + chineseAction),
            (.simplifiedChinese, chineseCommand + #"((?:简体)?中文|汉语)"# + chineseAction),
            (.english, #"^\s*(?:in\s+)?(English)\s+please\s*$"#),
            (.simplifiedChinese, #"^\s*(?:in\s+)?((?:simplified\s+)?Chinese)\s+please\s*$"#)
        ]
        let quoteExpression = try? NSRegularExpression(pattern: #"\"[^\"]*\"|'[^']*'|“[^”]*”|‘[^’]*’|「[^」]*」"#)
        var selected: AppLanguage?
        for clause in question.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?.\n")) {
            let text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let quotations = quoteExpression?.matches(in: text, range: range).map(\.range) ?? []
            var latest: (Int, AppLanguage)?
            for (language, pattern) in commands {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                for match in expression.matches(in: text, range: range) {
                    let target = match.range(at: 1)
                    let beforeTarget = (text as NSString).substring(to: target.location)
                    guard !quotations.contains(where: { NSIntersectionRange($0, target).length > 0 }),
                          !matches(beforeTarget, #"\bnot\s+in\s*$|\b(?:not|never|don['’]t|do not|didn['’]t|did not|shouldn['’]t|should not)\s+(?:answer|reply|respond|explain|write|say)\b"#),
                          latest == nil || target.location > latest!.0 else { continue }
                    latest = (target.location, language)
                }
            }
            if let latest { selected = latest.1 }
        }
        return selected
    }

    static func introducesOtherPerson(_ text: String) -> Bool {
        matches(text, #"\b(?:(?:my|his|her|their) (?:friend|partner|spouse|sister|brother|mother|father|child|son|daughter|colleague|coworker|relative)|another person|someone else)\b"#)
    }

    static func refersToOtherProfile(_ text: String) -> Bool {
        matches(text, #"(?:^|[,;.!?\n])\s*(?:(?:he|she|they)\s+(?:was|were)\s+born|(?:his|her|their)\s+(?:birth(?:day| date| time|place)?|date of birth|time of birth|sex|gender|time zone))\b"#)
    }

    static func isLunarDate(_ text: String) -> Bool {
        text.contains("农历") || text.contains("阴历") || matches(text, #"\b(?:lunar (?:date|calendar|birthday)|chinese lunar)\b"#)
    }
}
