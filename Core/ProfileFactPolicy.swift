import Foundation

/// Permission to persist real profile facts is separate from permission to
/// calculate. A hypothetical reading may proceed without rewriting a person.
enum ProfileFactPolicy {
    static func allowsPersistence(in rawText: String) -> Bool {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        // Quoted scalar values are ordinary data: 我叫“陈平”, "08:30", etc.
        // A complete profile statement inside a quote or code block is material
        // to discuss, not a statement the app may adopt as a person's record.
        if let expression = try? NSRegularExpression(pattern: quotationPattern) {
            let source = rawText as NSString
            for match in expression.matches(in: rawText, range: NSRange(location: 0, length: source.length)) {
                let quotation = source.substring(with: match.range)
                let delimiterCount = quotation.hasPrefix("```") ? 3 : 1
                let content = String(quotation.dropFirst(delimiterCount).dropLast(delimiterCount))
                if contains(profileStatementPattern, in: content)
                    || contains(profileTuplePattern, in: content) { return false }
            }
        }
        let unquoted = rawText.replacingOccurrences(of: quotationPattern, with: " ", options: .regularExpression)

        // Deliberately conservative for mixed messages: do not extract a real
        // patch from one clause while another makes its truth hypothetical.
        if contains(hypotheticalPattern, in: unquoted)
            || contains(reportedSpeechPattern, in: unquoted)
            || contains(temporaryProfilePattern, in: unquoted) { return false }

        for clause in clauses(in: unquoted) {
            if contains(negatedWritePattern, in: clause) || contains(consultationPattern, in: clause) { return false }
            if contains(profileFieldPattern, in: clause) {
                if contains(doubtPattern, in: clause)
                    || contains(#"[？?]\s*$"#, in: clause)
                    || contains(#"(?:是什么|是什么意思|有什么用|怎么填写|怎么填|如何填写|怎么选择|怎么选|有什么区别|解释|说明|介绍|讲讲)"#, in: clause) {
                    return false
                }
            }
        }
        // Denying an old scalar and then stating its correction, retracting an
        // unknown birth time, and explicit save requests remain valid facts.
        return true
    }

    private static let quotationPattern = #"```[\s\S]*?```|`[^`]*`|“[^”]*”|「[^」]*」|『[^』]*』|‘[^’]*’|"[^"]*"|(?<![\p{L}\d])'[^'\n]*'(?![\p{L}\d])"#

    private static let profileFieldPattern = #"出生|生日|生于|性别|姓名|姓氏|名字|时区|经纬度|纬度|经度|\b(?:name|surname|given name|first name|last name|gender|sex|birth(?:day|place)?|born|date of birth|time of birth|time\s?zone|latitude|longitude|coordinates)\b"#

    private static let profileStatementPattern = #"我叫|我是|名叫|姓名\s*[:：=]|出生|生日|生于|性别|姓氏|时区|经纬度|纬度|经度|\b(?:(?:my\s+)?name\s*(?:is\b|[:=])|i\s+am\b|i['’]m\b|born\b|birth(?:day|place)?\b|date of birth\b|time of birth\b|gender\b|sex\b|surname\b|time\s?zone\b|latitude\b|longitude\b|coordinates\b)"#

    // A quoted demographic tuple can be a whole example without field labels.
    // A single date, time, name or place is still a scalar, not a quoted record.
    private static let profileTuplePattern = #"(?:[,，;；\n].*\d{4}[年./-]\d{1,2}[月./-]\d{1,2}|\d{4}[年./-]\d{1,2}[月./-]\d{1,2}.*[,，;；\n]|[,，;；\n]\s*(?:男|女|male|female)\s*[,，;；\n])"#

    private static let hypotheticalPattern = #"如果|假如|假设|假定|假想|设想|倘若|要是|比方|比如|例如|举例|举个例|示例|范例|样例|模拟|演示|测试数据|测试档案|虚构|虚拟|编造|非真实|不是真实|\b(?:if|suppose|supposing|assuming|assume|hypothetical(?:ly)?|imagine|imaginary|what if|for example|for instance|e\.g\.|sample|demo(?:nstration)?|simulat(?:e|ed|ing|ion)|fictional|made[- ]up|pretend|not real)\b"#

    private static let reportedSpeechPattern = #"(?:他|她|他们|她们|别人|有人|对方)(?:曾|刚才|之前)?(?:说|写)|据说|听说|转述|原话|引用|这句话|这段话|这段资料|[\p{Han}]{1,12}(?:说|写|说过|说道|写道|声称|表示)\s*[:：]|[\p{Han}]{1,12}(?:说|说过|声称|表示)(?=自己|他的|她的|其|出生|生日|性别|姓名)|\b(?:(?:he|she|they|someone|somebody|another person|my (?:friend|partner|parent|mother|father|colleague))\s+(?:said|says|wrote|writes|told)|[\p{L}][\p{L}'’\-]*(?:\s+[\p{L}][\p{L}'’\-]*){0,3}\s+(?:said|says|stated|wrote|writes|told)|i was told|according to|quot(?:e|ed|ation)|the sentence|these words|their words)\b"#

    private static let consultationPattern = #"^\s*(?:(?:请|请问|我想知道|想知道|我想问|能否|可以|帮我)\s*)*(?:为什么|为何|如何|怎么|怎样|什么是|什么叫|解释|说明|介绍|讲讲|理解一下|需不需要|是否需要|有没有必要)|^\s*(?:please\s+|(?:can|could|would) you\s+)*(?:why\b|how\b|what (?:is|are|does)\b|explain\b|describe\b|tell me (?:why|how|what)\b)|^\s*(?:is|are|was|were|when|where|which|can i|should i|do i)\b.*\b(?:born|birth(?:day|place)?|name|gender|sex|time\s?zone|coordinates)\b"#

    private static let doubtPattern = #"是不是|是否(?:是|为|在|出生)|可能是|好像是|大概是|对不对|真的吗|[吗么]\s*[？?]?\s*$|\b(?:maybe|possibly|probably|is that right|i think|not sure (?:if|whether))\b"#

    // Bare 不 is accepted only immediately before a write action, never as a
    // wildcard prefix: “不是旧日期，实际是新日期” is still a real correction.
    // The final character of 性别 is not an imperative “别”.
    private static let negatedWritePattern = #"不(?:再|予以|予|进行|做)?\s*(?:保存|记录|留存|写入|修改|更新|入档|存档|建档|留档|落盘)|(?:不要|不用|(?<!性)别|不必|无需|不需要|不想|不是让你|并非让你|没有让你|不希望|不准|禁止).{0,16}(?:保存|记录|留存|写入|修改|改成|改为|更正|更新|设为|设置|绑定|添加|新增|入档|存档|建档|留档|落盘|改(?:档案|资料|记录))|\b(?:do not|don['’]t|never|no need to|not asking you to|not asking to).{0,24}\b(?:save|store|persist|record|change|update|set|replace|write|add|create|bind)\b|\b(?:no|without)\s+(?:changes?|updates?|writes?)\s+to\s+(?:(?:my|the|this|saved|real)\s+)*(?:profile|record|details|data)\b|\b(?:leave|keep).{0,24}\b(?:profile|record|details|data)\b.{0,16}\bunchanged\b"#

    private static let temporaryProfilePattern = #"暂按|暂时按|暂以|暂定|暂用|暂且|临时(?:按|使用|采用|资料|档案|数据|人员|人物|信息|姓名|名字|出生|生日|性别|时区|坐标|地点)|(?:本次|这次|此次|本轮|这轮|这回).{0,8}(?:临时|暂时)|(?:仅|只)(?:供|用|用于|在|作|作为)?(?:本次|这次|此次|本轮|这一轮|这轮|这回)|不入档|不记档|不记入|不写档|不留档|不落盘|\b(?:temporary|temporarily|provisional|provisionally|for now|just this once|this time only|one[- ]off)\b|\b(?:only\s+(?:for|in)\s+(?:this|the current)\s+(?:reading|calculation|session|cast|request|run)|for\s+(?:this|the current)\s+(?:reading|calculation|session|cast|request|run)\s+only)\b"#

    private static func clauses(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"[^，,；;。.!?\n\r！？]+[！？?]?"#) else { return [text] }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }
    }

    private static func contains(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
