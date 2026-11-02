import Foundation

struct PluginRegistry: Sendable {
    let plugins: [any OraclePlugin]
    init(plugins: [any OraclePlugin] = NativePlugins.all + SkyPlugins.all) { self.plugins = plugins }
    var descriptors: [OraclePluginDescriptor] {
        plugins.map { plugin in
            var descriptor = plugin.descriptor
            descriptor.interactionKinds = OracleInteractionPolicy.kind(for: descriptor.method).map { [$0] }
            return descriptor
        }
    }
    func plugin(_ method: OracleMethod) -> (any OraclePlugin)? { plugins.first { $0.descriptor.method == method } }
    func calculate(_ input: OracleInput, methods: [OracleMethod], onProgress: @escaping @Sendable (OracleResult) async -> Void) async -> [OracleResult] {
        // Each plugin gets a value snapshot; serial scheduling also protects vendored global tables.
        var results: [OracleResult] = []
        for method in OracleMethod.allCases where methods.contains(method) {
            if Task.isCancelled { break }
            guard let plugin = plugin(method) else { continue }
            let start = Date()
            var result: OracleResult
            do { result = try await plugin.calculate(input) }
            catch { result = OracleResult(method: method, status: .failed, headline: "本项未能完成", rows: [], limitations: [error.localizedDescription]) }
            result.durationMilliseconds = Date().timeIntervalSince(start) * 1000
            results.append(result); await onProgress(result)
        }
        return results
    }
    func localPlan(question: String, profile: OracleProfile) -> OraclePlan {
        let personal = ["我", "自己", "本人", "运势", "性格", "事业", "感情", "婚", "工作", "名字", "命"].contains { question.contains($0) }
        let other = ["朋友", "家人", "孩子", "他", "她", "对象", "父亲", "母亲"].contains { question.contains($0) }
        let naming = ["姓名", "名字", "改名", "取名"].contains { question.contains($0) }
        let tarotRequested = question.localizedCaseInsensitiveContains("tarot") || question.contains("塔罗") || question.contains("塔羅")
        var methods: [OracleMethod] = tarotRequested ? [.tarot] : [.liuyao, .meihua, .qimen, .xiaoliuren]
        if !tarotRequested, personal || other { methods += [.bazi, .ziwei, .chenggu, .astrology] }
        if !tarotRequested, naming || (!profile.familyName.isEmpty && !profile.givenName.isEmpty && personal) { methods.append(.xingming) }
        let fields = Array(Set(methods.flatMap { plugin($0)?.descriptor.requiredFields ?? [] })).sorted { $0.rawValue < $1.rawValue }
        var plan = OraclePlan(intent: naming ? "姓名与个人问题" : personal || other ? "个人问题" : "具体问事", subject: other ? "他人" : "本人", methods: methods, requiredFields: fields,
                          note: "已按这次问题备好问事笺。能确定的写下，不确定的也可以注明。", question: question)
        if !tarotRequested, methods.contains(.meihua), ["报数", "数字", "留数"].contains(where: question.contains) {
            plan.interactions = [.init(method: .meihua, kind: .numbers)]
        }
        return plan
    }
}
