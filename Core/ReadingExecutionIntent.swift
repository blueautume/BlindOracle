import Foundation

struct ReadingExecutionIntent: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case answer, calculate, recast, collect, clarify }
    enum Coverage: String, Codable, Sendable { case existing, additional, changed, unknown }
    var operation: Operation
    var coverage: Coverage
    /// A verbatim span of the current message, never a model-written note.
    var evidence: String
}

/// Topic relation selects the context. This policy separately selects the work
/// to perform, before a reply action can discard methods or reuse a saved cast.
enum ReadingExecutionPolicy {
    static func validatedAction(understanding: ConversationUnderstanding?, rawQuestion: String,
                                proposedAction: String, hasRelatedRun: Bool) -> String? {
        guard understanding?.relation != .ambiguous else { return "clarify" }
        guard let execution = understanding?.execution else {
            // Compatibility with older plans: a direct, unnamed calculation
            // command must not disappear into the continuation shortcut.
            guard !["clarify", "collect"].contains(proposedAction),
                  let relation = understanding?.relation, relation != .newQuestion,
                  isExplicitCalculationCommand(rawQuestion),
                  ReadingContinuationPolicy.requestedCalculationMethods(in: rawQuestion).isEmpty else { return nil }
            return "intake"
        }
        let evidence = execution.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty, evidence.count <= 1000, rawQuestion.contains(evidence) else { return "clarify" }
        if execution.operation == .calculate || execution.operation == .recast {
            guard !isNonExecutingRequest(rawQuestion) else { return "clarify" }
        }
        switch execution.operation {
        case .clarify: return "clarify"
        case .collect: return "collect"
        case .answer:
            // A positive instruction about a cited reading outranks a mistaken
            // answer label. A standalone ordinary question keeps its answer
            // route; merely mentioning a method or a date is not a command.
            if understanding?.relation != .newQuestion,
               !isNonExecutingRequest(rawQuestion) {
                if isExplicitCalculationCommand(rawQuestion) { return "intake" }
                if !ReadingContinuationPolicy.requestedCalculationMethods(in: rawQuestion).isEmpty {
                    return execution.coverage == .changed || !hasRelatedRun ? "intake" : "supplement"
                }
            }
            return "reply"
        case .recast:
            return execution.coverage == .unknown ? "clarify" : "intake"
        case .calculate:
            switch execution.coverage {
            case .unknown: return "clarify"
            case .changed: return "intake"
            case .additional: return hasRelatedRun ? "supplement" : "intake"
            case .existing:
                if isExplicitCalculationCommand(rawQuestion) { return "intake" }
                return hasRelatedRun ? "reply" : "intake"
            }
        }
    }

    /// A narrow compatibility guard for imperative commands, not a classifier
    /// for target dates, occupations or other domain-specific situations.
    static func isExplicitCalculationCommand(_ text: String) -> Bool {
        let source = unquoted(text)
        let english = #"^\s*(?:(?:then|now|please|also|again|could you|can you|would you|i want you to|i would like you to)\s+)*(?:calculate|recalculate|recast|redraw|compute|cast(?:\s+(?:a|the))?\s+(?:reading|chart|hexagram)|do\s+(?:a|another|a new|a fresh)\s+reading|give me\s+(?:a|another|a new|a fresh)\s+reading)\b"#
        return clauses(source).contains {
            chineseCommandClause($0) == .imperative
                || $0.range(of: english, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static func isNonExecutingRequest(_ text: String) -> Bool {
        if isExplicitCalculationCommand(text)
            || !ReadingContinuationPolicy.requestedCalculationMethods(in: unquoted(text)).isEmpty { return false }
        if clauses(unquoted(text)).contains(where: { chineseCommandClause($0) == .context }) { return true }
        let verbs = #"(?:重算|再算|重新|计算|测算|推演|占卜|起卦|排盘|算)"#
        let deny = #"(?:不要|不用|无需|不必|别|不想|不是让你|并非让你).{0,8}"# + verbs
        let consult = #"^\s*(?:那|请|能否|我想知道|想知道|我想问|我问的是|请问)?(?:为什么|为何|怎么|怎样|如何|什么叫|解释|讲讲|说明|需不需要|是否需要|有没有必要).*"# + verbs
        let hypothetical = #"^\s*(?:如果|假如|假设|比如|例如|他说|她说|别人说|原话是)"#
        let english = #"^\s*(?:please\s+)?(?:why\b|how\b|what (?:does|is)\b|explain\b|do not\b|don['’]t\b|no need to\b|without\b|if\b|suppose\b|he said\b|she said\b)"#
        return clauses(unquoted(text)).contains {
            $0.range(of: deny, options: .regularExpression) != nil
                || $0.range(of: consult, options: .regularExpression) != nil
                || $0.range(of: hypothetical, options: .regularExpression) != nil
                || $0.range(of: english, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private enum CommandClause { case imperative, context, other }

    private static func chineseCommandClause(_ clause: String) -> CommandClause {
        // The optional prepositional object is not an interrogative opener:
        // "为什么…算" is not "为 [object] 算".
        let pattern = #"^\s*(?:(?:那就|那么|那|请你|请|麻烦你|麻烦|现在|接着|还是|同时|另外|并且|而是|就|也|再|重新|帮我|替我|给我|能否|可以|能不能|可不可以)\s*)*(?:(?:为|针对|按照|按)(?!(?:什么|何|哪|怎么|怎样|如何))[^，,。；;！？!?\n]{1,40}?)?(?:算(?:一下|一次|一遍|一算|算|一卦)?(?!了|是|作|数|不算|起来)|计算(?!方法|原理|规则|过程)|测算|推演(?:一下)?|占卜(?:一下)?|起(?:一|个|一轮)?卦|抽(?:牌|(?:一|三|3)(?:整)?(?:阵|组|张|次)牌?)|排盘|测(?:一测|一下|测))(?=$|[\p{Han}\d\s])"#
        guard let verb = clause.range(of: pattern, options: .regularExpression) else { return .other }
        let tail = String(clause[verb.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A verb can introduce a temporal or nominal phrase rather than a
        // command. Inspect its immediate grammar, not later question words:
        // "抽牌前我该…" is context; "算算我该怎么做" is imperative.
        let context = #"^(?:的|之(?:前|后|时)|以(?:前|后)|的时候|时候|(?:前|后|时)(?=$|(?:我|你|您|他|她|它|咱|大家|该|应|要|需|能|可|会|怎么|怎样|如何|什么|为何)))"#
        return tail.range(of: context, options: .regularExpression) == nil ? .imperative : .context
    }

    private static func clauses(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n"))
    }

    private static func unquoted(_ text: String) -> String {
        text.replacingOccurrences(of: #"“[^”]*”|「[^」]*」|『[^』]*』|\"[^\"]*\""#,
                                 with: "", options: .regularExpression)
    }
}
