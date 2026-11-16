import Foundation
import XCTest
@testable import BlindOracle

/// Opt in with BLINDORACLE_LIVE_PLANNING=1. The relay must forward the exact
/// request body to a real provider and return its unmodified response envelope.
/// Capture-only mode records requests, then cancels them without a fake plan.
@MainActor final class LivePlanningRoutingTests: XCTestCase {
    func testLivePlanningRoutingMatrix() async throws {
        let environment = ProcessInfo.processInfo.environment
        let captureOnly = environment["BLINDORACLE_PLANNING_CAPTURE_ONLY"] == "1"
        guard captureOnly || environment["BLINDORACLE_LIVE_PLANNING"] == "1" else {
            throw XCTSkip("Real planning evaluation and request capture are explicitly opt-in")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let matrix = try decoder.decode(PlanningEvaluationMatrix.self, from: Data(Self.matrixJSON.utf8))
        let filter = Set((environment["BLINDORACLE_PLANNING_CASE_IDS"] ?? "").split(separator: ",").map(String.init))
        let scenarios = matrix.cases.filter { filter.isEmpty || filter.contains($0.id) }
        XCTAssertFalse(scenarios.isEmpty, "The requested evaluation filter must select at least one case")
        let relay = try XCTUnwrap(URL(string: environment["BLINDORACLE_PLANNING_RELAY"] ?? "http://127.0.0.1:18765"))
        PlanningRelayRecorder.shared.configure(relay: relay, captureOnly: captureOnly, maximumRequests: matrix.providerRequestCap)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlanningRelayURLProtocol.self]
        let client = DeepSeekClient(accessToken: "synthetic-planning-benchmark", sessionConfiguration: configuration)
        var rows: [[String: Any]] = []
        for scenario in scenarios {
            PlanningRelayRecorder.shared.beginCase(scenario.id)
            let contextName = environment["BLINDORACLE_PLANNING_CONTEXT_OVERRIDE"] ?? scenario.context
            let context = try fixture(contextName)
            let language = AppLanguage(rawValue: scenario.language) ?? .simplifiedChinese
            let started = ContinuousClock.now
            var row: [String: Any] = ["id": scenario.id, "question": scenario.question,
                "category": scenario.category, "language": scenario.language,
                "expected": scenario.expected.dictionary, "capture_only": captureOnly,
                "context": contextName, "original_context": scenario.context]
            do {
                let plan = try await client.plan(question: scenario.question, profile: context.profile,
                    plugins: PluginRegistry().descriptors, history: context.history, profiles: context.profiles,
                    existingRun: context.run, references: context.references, language: language)
                row["actual"] = ["action": plan.action ?? "nil", "subject": plan.subject,
                    "methods": plan.methods.map(\.rawValue), "mandatory_methods": (plan.mandatoryMethods ?? []).map(\.rawValue),
                    "profile_updates_count": plan.profileUpdates?.count ?? 0,
                    "relation": plan.understanding?.relation.rawValue ?? "nil"]
                if !captureOnly {
                    let failures = scenario.expected.failures(plan)
                    row["passed"] = failures.isEmpty
                    row["failures"] = failures
                    for failure in failures { XCTFail("\(scenario.id): \(failure)") }
                }
            } catch {
                row["error"] = String(describing: error)
                if captureOnly {
                    let recorded = PlanningRelayRecorder.shared.exchanges(for: scenario.id)
                    row["captured"] = !recorded.isEmpty
                    XCTAssertFalse(recorded.isEmpty, "\(scenario.id): request capture did not reach the real plan transport")
                } else {
                    row["passed"] = false
                    XCTFail("\(scenario.id): \(error.localizedDescription)")
                }
            }
            let duration = started.duration(to: ContinuousClock.now).components
            row["elapsed_seconds"] = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            row["exchanges"] = PlanningRelayRecorder.shared.exchanges(for: scenario.id)
            rows.append(row)
            print("[PLANNING_MATRIX] \(scenario.id) capture=\(captureOnly) elapsed=\(row["elapsed_seconds"] ?? 0) passed=\(row["passed"] ?? "capture-only")")
        }
        let label = environment["BLINDORACLE_PLANNING_RUN_LABEL"] ?? (captureOnly ? "capture" : matrix.version)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlanningRoutingEvaluation", isDirectory: true)
            .appendingPathComponent(label + "-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = ["version": matrix.version, "capture_only": captureOnly,
            "provider_request_cap": matrix.providerRequestCap, "cases": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("results.json"))
        let descriptors = try JSONEncoder().encode(PluginRegistry().descriptors)
        try descriptors.write(to: directory.appendingPathComponent("plugin-descriptors.json"))
        for row in rows {
            let id = row["id"] as? String ?? "case"
            try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(id + ".json"))
        }
        for (name, content) in [("planning-routing-results.json", data), ("planning-plugin-descriptors.json", descriptors)] {
            let attachment = XCTAttachment(data: content, uniformTypeIdentifier: "public.json")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        print("[PLANNING_MATRIX_EXPORT] \(directory.path)")
    }

    private func fixture(_ name: String) throws -> PlanningEvaluationContext {
        var chen = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "陈平", sex: "男", birthDate: "1992-06-15",
            birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai", birthPlace: "上海市黄浦区", birthLatitude: 31.2304,
            birthLongitude: 121.4737)], to: []).profiles.first)
        chen.id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        chen.familyName = "陈"; chen.givenName = "平"
        chen.currentPlace = "上海市黄浦区"; chen.currentLatitude = 31.2304; chen.currentLongitude = 121.4737
        chen.currentTimeZoneID = "Asia/Shanghai"
        var li = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(name: "李岚", sex: "女", birthDate: "1994-09-10",
            birthTime: "14:20", birthTimeZoneID: "Asia/Shanghai", birthPlace: "上海市黄浦区", birthLatitude: 31.2304,
            birthLongitude: 121.4737)], to: []).profiles.first)
        li.id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        li.familyName = "李"; li.givenName = "岚"
        switch name {
        case "empty": return .init(profile: OracleProfile(), profiles: [])
        case "names-only":
            return .init(profile: OracleProfile(), profiles: ProfileDirectory.applying([ProfileUpdate(name: "陈平"), ProfileUpdate(name: "李岚")], to: []).profiles)
        case "pair-full": return .init(profile: OracleProfile(), profiles: [chen, li])
        case "self-time-unknown":
            chen.birthTimeKnown = false; chen.unknownFields.insert(.birthTime); chen.declaredUnknownFields = [.birthTime]
            return .init(profile: chen, profiles: [chen, li])
        case "prior-tarot":
            let question = "周末创意市集合作是否值得推进？"
            let input = OracleInput(question: question, profile: chen,
                castingDate: Date(timeIntervalSince1970: 1_730_000_000), seed: 42, subject: "事件",
                tarotDraws: [TarotDraw(cardID: "wands-03", isReversed: false, position: "现状"),
                    TarotDraw(cardID: "pentacles-06", isReversed: true, position: "影响"),
                    TarotDraw(cardID: "major-11", isReversed: false, position: "建议")], participants: [])
            let plan = OraclePlan(intent: "市集合作", subject: "事件", methods: [.tarot], requiredFields: [], note: "", question: question)
            var run = OracleRun(input: input, plan: plan, results: [OracleResult(method: .tarot,
                headline: "已保存的市集合作牌阵", rows: [.init("建议", "先谈清预算和分工")])])
            run.synthesis = ReadingSynthesis(text: "这次合作先明确预算和职责，再决定是否推进。")
            run.completedAt = input.castingDate
            let messages = [ChatMessage(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, role: .user, content: question),
                ChatMessage(id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, role: .assistant,
                    content: run.synthesis!.text, kind: .reading, runID: run.id)]
            return .init(profile: chen, profiles: [chen, li], history: ContextCompressor.history(messages: messages,
                summary: .init(), language: .simplifiedChinese), run: run,
                references: ConversationPlanningReference.candidates(in: messages, runs: [run]))
        default: return .init(profile: chen, profiles: [chen, li])
        }
    }

    private static let matrixJSON = #"""
{
"version":"routing-v2", "provider_request_cap":60, "cases":[
{"id":"explicit-bazi-zh","category":"explicit","language":"zh-Hans","question":"只用八字分析我明年的职业发展，不要使用其他方法。","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["bazi"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["bazi"]}},
{"id":"explicit-ziwei-en","category":"explicit","language":"en","question":"Use only Zi Wei Dou Shu to calculate my career outlook for next year.","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["ziwei"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["ziwei"]}},
{"id":"explicit-liuyao-zh","category":"explicit","language":"zh-Hans","question":"只用六爻看这次合作能不能谈成，我愿意自己摇卦。","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["liuyao"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["liuyao"],"subjects":["事件","本人"],"subject_reason":"One cooperation event, personally cast by the user; Liu Yao runs once and uses no participant birth facts."}},
{"id":"explicit-meihua-en","category":"explicit","language":"en","question":"Use only Mei Hua Yi Shu to calculate whether tomorrow’s contract negotiation will go smoothly.","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["meihua"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["meihua"],"subjects":["事件","本人"],"subject_reason":"One contract negotiation event; Mei Hua runs once and uses no participant birth facts."}},
{"id":"explicit-qimen-zh","category":"explicit","language":"zh-Hans","question":"只用奇门遁甲看明天下午拜访客户的安排，重点看出行与沟通。","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["qimen"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["qimen"],"subjects":["事件","本人"],"subject_reason":"One client visit event; Qi Men runs once and uses no participant birth facts."}},
{"id":"explicit-xiaoliuren-en","category":"explicit","language":"en","question":"Use only Xiao Liu Ren to calculate whether this evening’s short trip will go smoothly.","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["xiaoliuren"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["xiaoliuren"],"subjects":["事件","本人"],"subject_reason":"One short trip event; Xiao Liu Ren runs once and uses no participant birth facts."}},
{"id":"explicit-chenggu-zh","category":"explicit","language":"zh-Hans","question":"只用称骨看我出生资料对应的骨重和传统歌诀，不要混用其他方法。","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["chenggu"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["chenggu"]}},
{"id":"explicit-xingming-en","category":"explicit","language":"en","question":"Use only Chinese Name Numerology to calculate the five-grid stroke pattern of my name 陈平.","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["xingming"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["xingming"]}},
{"id":"explicit-astrology-zh","category":"explicit","language":"zh-Hans","question":"只用西方占星分析我本命盘里的性格特点与职业倾向。","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["astrology"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["astrology"]}},
{"id":"explicit-tarot-en","category":"explicit","language":"en","question":"Use only Tarot to read the prospects of this weekend’s project discussion; let me draw the cards.","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["tarot"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["tarot"],"subjects":["事件","本人"],"subject_reason":"One project discussion event, personally drawn by the user; Tarot runs once and uses no participant birth facts."}},
{"id":"implicit-bazi-zh","category":"capability","language":"zh-Hans","question":"请根据出生年、月、日、时对应的天干地支，分析我的日主强弱、喜忌和未来十年运势。","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["bazi"],"methods_match":"contains","profile_updates":"none"}},
{"id":"implicit-ziwei-en","category":"capability","language":"en","question":"Please place my natal life and body palaces, examine the major stars across the twelve palaces, and calculate my career tendencies.","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["ziwei"],"methods_match":"contains","profile_updates":"none"}},
{"id":"implicit-liuyao-zh","category":"capability","language":"zh-Hans","question":"我想自己分六次投硬币，记录每次正反面的结果，按这组阴阳变化推算合作是否能成。","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["liuyao"],"methods_match":"contains","profile_updates":"none","subjects":["事件","本人"],"subject_reason":"One cooperation event, personally cast by the user; Liu Yao runs once and uses no participant birth facts."}},
{"id":"implicit-meihua-en","category":"capability","language":"en","question":"I spontaneously chose the numbers 12, 23 and 6. Please use those numbers to cast a hexagram about tomorrow’s contract negotiation.","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["meihua"],"methods_match":"contains","profile_updates":"none","subjects":["事件","本人"],"subject_reason":"One contract negotiation event, with user-selected casting numbers; Mei Hua uses no participant birth facts."}},
{"id":"implicit-qimen-zh","category":"capability","language":"zh-Hans","question":"请按当前时间和地点起局，结合九宫、九星和八门，推算这次出行适合先往哪个方向拜访客户。","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["qimen"],"methods_match":"contains","profile_updates":"none","subjects":["事件","本人"],"subject_reason":"One client trip event; Qi Men runs once and uses no participant birth facts."}},
{"id":"implicit-xiaoliuren-en","category":"capability","language":"en","question":"Please use the six outcomes Da An, Liu Lian, Su Xi, Chi Kou, Xiao Ji and Kong Wang for a quick time-based reading of tonight’s trip.","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["xiaoliuren"],"methods_match":"contains","profile_updates":"none","subjects":["事件","本人"],"subject_reason":"One trip event; Xiao Liu Ren runs once and uses no participant birth facts."}},
{"id":"implicit-chenggu-zh","category":"capability","language":"zh-Hans","question":"请把我出生年、月、日、时对应的传统骨重相加，给出总重量和对应歌诀。","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["chenggu"],"methods_match":"contains","profile_updates":"none"}},
{"id":"implicit-xingming-en","category":"capability","language":"en","question":"Please calculate the Heaven, Personality, Earth, Outer and Total grids from the stroke counts of my Chinese name 陈平.","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["xingming"],"methods_match":"contains","profile_updates":"none"}},
{"id":"implicit-astrology-zh","category":"capability","language":"zh-Hans","question":"请按出生时刻的太阳、月亮、上升、行星宫位和相位，分析我的个性和职业倾向。","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["astrology"],"methods_match":"contains","profile_updates":"none"}},
{"id":"implicit-tarot-en","category":"capability","language":"en","question":"Let me personally draw three cards, including upright or reversed positions, to examine the situation, obstacle and advice for this project.","context":"self-full","expected":{"action":"intake","subject":"事件","methods":["tarot"],"methods_match":"contains","profile_updates":"none","subjects":["事件","本人"],"subject_reason":"One project event, personally drawn by the user; Tarot runs once and uses no participant birth facts."}},
{"id":"missing-birth-bazi","category":"missing-data","language":"zh-Hans","question":"我没有提供出生年月日时，只用八字看事业，缺什么资料就让我填，不要换方法。","context":"empty","expected":{"action":"intake","subject":"本人","methods":["bazi"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["bazi"]}},
{"id":"missing-place-qimen","category":"missing-data","language":"en","question":"Use only Qi Men Dun Jia to calculate this trip. I have not provided the location yet; ask me for it rather than switching methods.","context":"empty","expected":{"action":"intake","subject":"事件","methods":["qimen"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["qimen"],"subjects":["事件","本人"],"subject_reason":"One trip event; missing casting location stays user-entered and neither subject label supplies participant birth facts."}},
{"id":"multi-method-bazi-tarot","category":"multiple-methods","language":"zh-Hans","question":"请同时用八字和塔罗分析我的职业发展，两个方法都要，其他方法不要加。","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["bazi","tarot"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["bazi","tarot"]}},
{"id":"multi-person-astrology","category":"multiple-people","language":"en","question":"Use only Western Astrology to calculate a synastry comparison of 陈平 and 李岚 for their working relationship.","context":"pair-full","expected":{"action":"intake","subject":"多人","methods":["astrology"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["astrology"]}},
{"id":"quoted-negated-command","category":"negative-quoted","language":"zh-Hans","question":"不要替我计算。朋友说“用八字重新算一下”是什么意思？只解释这句话。","context":"empty","expected":{"action":"reply","subject":"事件","methods":[],"methods_match":"exact","profile_updates":"none","mandatory_methods":[],"subjects":["事件","他人"],"subject_reason":"Ordinary explanation of a friend's quoted words; no calculation, participant selection or profile facts are requested."}},
{"id":"ambiguous-short-question","category":"ambiguous","language":"zh-Hans","question":"那个怎么样？","context":"empty","expected":{"action":"clarify","subject":"事件","methods":[],"methods_match":"exact","profile_updates":"none","mandatory_methods":[]}},
{"id":"explain-existing-tarot","category":"follow-up-explain","language":"en","question":"Please explain why the existing reading recommends agreeing on the budget first. Do not calculate again.","context":"prior-tarot","expected":{"action":"reply","subject":"事件","methods":[],"methods_match":"exact","profile_updates":"none","mandatory_methods":[]}},
{"id":"add-liuyao-to-existing","category":"follow-up-add","language":"zh-Hans","question":"同一个市集合作安排，再用六爻补充推算一次，保留原来的塔罗结果。","context":"prior-tarot","expected":{"action":"supplement","subject":"事件","methods":["liuyao"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["liuyao"],"subjects":["事件","本人"],"subject_reason":"One previously anchored market project; adding Liu Yao preserves the old reading and uses no participant birth facts."}},
{"id":"recast-existing-tarot","category":"follow-up-recast","language":"en","question":"For the same market project, please draw a completely new Tarot spread and recalculate. Do not reuse the old cards.","context":"prior-tarot","expected":{"action":"intake","subject":"事件","methods":["tarot"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["tarot"],"subjects":["事件","本人"],"subject_reason":"One previously anchored market project; a new Tarot spread runs once and uses no participant birth facts."}},
{"id":"hypothetical-birth-not-fact","category":"hypothetical","language":"zh-Hans","question":"假设一位未保存的林舟出生于1990年1月2日08:30，出生地上海。请只用八字计算这个假设，不要保存或改写任何人的资料。","context":"names-only","expected":{"action":"intake","subject":"他人","methods":["bazi"],"methods_match":"exact","profile_updates":"none","mandatory_methods":["bazi"]}},
{"id":"named-ziwei-unknown-time","category":"named-without-only","language":"zh-Hans","question":"请用紫微斗数看我的职业发展，但我不记得出生时辰。","context":"self-time-unknown","expected":{"action":"intake","subject":"本人","methods":["ziwei"],"methods_match":"exact","mandatory_methods":["ziwei"],"profile_updates":"none"}},
{"id":"named-multiple-without-only","category":"named-without-only","language":"zh-Hans","question":"请用八字和塔罗一起分析我的职业发展。","context":"self-full","expected":{"action":"intake","subject":"本人","methods":["bazi","tarot"],"methods_match":"exact","mandatory_methods":["bazi","tarot"],"profile_updates":"none"}}
]}
"""#
}

private struct PlanningEvaluationContext {
    var profile: OracleProfile
    var profiles: [OracleProfile]
    var history: [AIConversationTurn] = []
    var run: OracleRun? = nil
    var references: [ConversationPlanningReference] = []
}

private struct PlanningEvaluationMatrix: Decodable {
    let version: String
    let providerRequestCap: Int
    let cases: [PlanningEvaluationScenario]
}

private struct PlanningEvaluationScenario: Decodable {
    let id: String
    let category: String
    let language: String
    let question: String
    let context: String
    let expected: PlanningEvaluationExpectation
}

private struct PlanningEvaluationExpectation: Decodable {
    let action: String
    let subject: String
    let subjects: [String]?
    let subjectReason: String?
    let methods: [String]
    let methodsMatch: String
    let mandatoryMethods: [String]?
    let profileUpdates: String
    var dictionary: [String: Any] {
        var value: [String: Any] = ["action": action, "subject": subject, "methods": methods, "methods_match": methodsMatch,
            "profile_updates": profileUpdates]
        if let mandatoryMethods { value["mandatory_methods"] = mandatoryMethods }
        if let subjects { value["subjects"] = subjects }
        if let subjectReason { value["subject_reason"] = subjectReason }
        return value
    }
    func failures(_ plan: OraclePlan) -> [String] {
        var failures: [String] = []
        if plan.action != action { failures.append("action expected \(action), got \(plan.action ?? "nil")") }
        // Event/self labels are equivalent only for methods that run once
        // without personal facts. Actual personal readings keep strict subjects.
        let permittedSubjects = plan.methods.contains(where: \.usesPersonalProfile) ? [subject] : subjects ?? [subject]
        if !permittedSubjects.contains(plan.subject) {
            failures.append("subject expected one of \(permittedSubjects), got \(plan.subject)")
        }
        let actual = Set(plan.methods.map(\.rawValue)), required = Set(methods)
        if methodsMatch == "exact" ? actual != required : !required.isSubset(of: actual) {
            failures.append("methods expected \(methodsMatch) \(methods), got \(actual.sorted())")
        }
        if let mandatoryMethods, Set((plan.mandatoryMethods ?? []).map(\.rawValue)) != Set(mandatoryMethods) {
            failures.append("mandatory methods expected \(mandatoryMethods), got \((plan.mandatoryMethods ?? []).map(\.rawValue))")
        }
        if profileUpdates == "none", plan.profileUpdates?.isEmpty == false { failures.append("model must not automatically fill profile facts") }
        return failures
    }
}

private final class PlanningRelayRecorder: @unchecked Sendable {
    static let shared = PlanningRelayRecorder()
    private let lock = NSLock()
    private var relay = URL(string: "http://127.0.0.1:18765")!
    private var captureOnly = false
    private var maximumRequests = 40
    private var requests = 0
    private var caseID = "unassigned"
    private var recorded: [String: [[String: Any]]] = [:]
    func configure(relay: URL, captureOnly: Bool, maximumRequests: Int) {
        lock.withLock {
            self.relay = relay; self.captureOnly = captureOnly; self.maximumRequests = maximumRequests
            requests = 0; recorded = [:]
        }
    }
    func beginCase(_ id: String) { lock.withLock { caseID = id } }
    func begin(body: Data) throws -> (id: String, relay: URL, captureOnly: Bool) {
        try lock.withLock {
            guard captureOnly || requests < maximumRequests else { throw PlanningRelayError.requestBudgetReached }
            if !captureOnly { requests += 1 }
            let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            recorded[caseID, default: []].append(["request": payload])
            return (caseID, relay, captureOnly)
        }
    }
    func finish(id: String, data: Data?, response: URLResponse?, elapsed: TimeInterval, error: Error?) {
        lock.withLock {
            guard let last = recorded[id]?.indices.last else { return }
            recorded[id]?[last]["relay_elapsed_seconds"] = elapsed
            recorded[id]?[last]["http_status"] = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error { recorded[id]?[last]["transport_error"] = error.localizedDescription }
            if let data, let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let usage = envelope["usage"] as? [String: Any] { recorded[id]?[last]["usage"] = usage }
                if let choices = envelope["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
                   let content = message["content"] as? String { recorded[id]?[last]["response_plan"] = content }
            }
        }
    }
    func exchanges(for id: String) -> [[String: Any]] { lock.withLock { recorded[id] ?? [] } }
}

private enum PlanningRelayError: Error { case captureCompleted, requestBudgetReached, missingURL }

private final class PlanningRelayURLProtocol: URLProtocol {
    private let lock = NSLock()
    private var relayTask: URLSessionDataTask?
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = Self.body(request)
            let settings = try PlanningRelayRecorder.shared.begin(body: body)
            if settings.captureOnly {
                client?.urlProtocol(self, didFailWithError: PlanningRelayError.captureCompleted)
                return
            }
            guard let originalURL = request.url else { throw PlanningRelayError.missingURL }
            var forwarded = URLRequest(url: settings.relay)
            forwarded.httpMethod = "POST"; forwarded.httpBody = body
            forwarded.setValue("application/json", forHTTPHeaderField: "Content-Type")
            forwarded.setValue(settings.id, forHTTPHeaderField: "X-Planning-Case-ID")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = []
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 900
            let session = URLSession(configuration: configuration)
            let started = Date()
            let task = session.dataTask(with: forwarded) { [weak self] data, response, error in
                defer { session.finishTasksAndInvalidate() }
                PlanningRelayRecorder.shared.finish(id: settings.id, data: data, response: response,
                    elapsed: Date().timeIntervalSince(started), error: error)
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
                let http = response as? HTTPURLResponse
                let mapped = HTTPURLResponse(url: originalURL, statusCode: http?.statusCode ?? 502,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: mapped, cacheStoragePolicy: .notAllowed)
                if let data { self.client?.urlProtocol(self, didLoad: data) }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            lock.withLock { self.relayTask = task }
            task.resume()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        let task = lock.withLock { stopped = true; return self.relayTask }
        task?.cancel()
    }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(bytes, count: count)
        }
        return data
    }
}
