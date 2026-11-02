import Foundation

/// A saved chart remains the conversation's source until the user asks for a new reading.
enum ReadingContinuationPolicy {
    private static let recastPatterns = [
        #"(?:重算|重起一卦|重抽(?:(?:一次|一组|三张)牌?|牌))"#,
        #"(?:重新|重来一次|从头)(?:再)?(?:起卦|算卦|算命|推演|占卜|抽(?:(?:一次|一组|三张)牌?|牌)|掷卦|(?:投掷|投|掷)(?:一次|六次)?|六掷(?:成卦)?|算(?:一遍|一次|一下|一卦|算)?)"#,
        #"(?:再|另外|另)(?:帮我|替我|给我)?(?:算(?:一卦|一次|一下|算)|起(?:一|个|一轮)?卦|占卜(?:一次|一下)?|抽(?:(?:一次|一组|三张)牌?|牌)|(?:投掷|投|掷)(?:一次|六次))"#,
        #"再来(?:一卦|一次占卜|一轮抽牌)"#
    ]

    static func shouldReuse(question: String, run: OracleRun?, pendingPlan: OraclePlan?) -> Bool {
        guard pendingPlan == nil, let run,
              run.results.contains(where: { $0.status == .complete || $0.status == .partial }),
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !explicitlyRequestsNewReading(question)
    }

    static func explicitlyRequestsNewReading(_ question: String) -> Bool {
        let clauses = question.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n"))
        // Naming a method or asking how a chart was calculated is not a request to calculate again.
        let patterns = recastPatterns + [
            #"(?:换个|换一个|另一个|另外一个|另问(?:一件|一桩)?|换一件)(?:问题|事|事情)"#,
            #"(?:帮我|替我|给我|我想|我要|我需要)(?:再)?(?:算(?:一下|一算|算|卦|命)|起(?:一|个|一轮)?卦|占卜|抽牌|推演)"#,
            #"(?:改用|换用|改成|换成|再用)(?:六爻|塔罗|梅花|八字|紫微|占星|小六壬|奇门|姓名|称骨).{0,6}(?:起(?:一|个|一轮)?卦|算|抽牌|看看|占卜|推演)"#
        ]
        for clause in clauses {
            let compact = clause.filter { !$0.isWhitespace }
            let fullRange = NSRange(compact.startIndex..<compact.endIndex, in: compact)
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
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
        guard explicitlyRequestsNewReading(question) else { return false }
        let compact = question.filter { character in
            !character.isWhitespace && !character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        }
        let method = #"(?:六爻|塔罗|塔羅|tarot|梅花|八字|紫微|紫薇|占星|小六壬|奇门|姓名五格|称骨)"#
        let qualification = #"(?:(?:只|仅|必须)?(?:用|按|按照)|改用|换用|再用)"# + method
        let politePrefix = #"(?:请|请你|麻烦|麻烦你|帮我|替我|给我|我想|我要|我需要|能否|可以)"#
        let politeSuffix = #"(?:吧|吗|呢|好吗|可以吗|谢谢)"#
        let command = "(?:" + recastPatterns.joined(separator: "|") + ")"
        let pattern = "^(?:" + politePrefix + "|" + qualification + ")*" + command
            + "(?:" + politeSuffix + "|" + qualification + ")*$"
        return compact.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
