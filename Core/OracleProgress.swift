import Foundation

enum OracleActivityStatus: String, Codable, Sendable {
    case running, completed, waiting, failed, cancelled
}

/// Observable application work, never a model's private reasoning transcript.
struct OracleActivity: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var detail: String?
    var date: Date
    var finishedAt: Date?
    var status: OracleActivityStatus
    var method: OracleMethod?
    var duration: TimeInterval? { finishedAt.map { max(0, $0.timeIntervalSince(date)) } }

    init(text: String, detail: String? = nil, date: Date = Date(), finishedAt: Date? = nil,
         status: OracleActivityStatus = .running, method: OracleMethod? = nil) {
        self.text = text; self.detail = detail; self.date = date
        self.finishedAt = finishedAt; self.status = status; self.method = method
    }
}

struct OracleProgressTimeline: Sendable {
    var activities: [OracleActivity] = []

    @discardableResult mutating func begin(text: String, detail: String? = nil, method: OracleMethod? = nil,
                                         status: OracleActivityStatus = .running, at date: Date = Date()) -> UUID {
        if let previous = activities.last, previous.text == text, previous.detail == detail,
           previous.method == method, previous.status == status { return previous.id }
        finish(at: date)
        let terminal = status != .running && status != .waiting
        let activity = OracleActivity(text: text, detail: detail, date: date,
                                      finishedAt: terminal ? date : nil, status: status, method: method)
        activities.append(activity)
        return activity.id
    }

    mutating func finish(status: OracleActivityStatus = .completed, at date: Date = Date()) {
        guard let index = activities.indices.last,
              activities[index].status == .running || activities[index].status == .waiting else { return }
        activities[index].status = status
        activities[index].finishedAt = max(date, activities[index].date)
    }

    mutating func reset() { activities = [] }
}

enum AIReadingProgress: Equatable, Sendable { case preparing, requesting, writing, validating }

extension OracleMethod {
    var progressName: String {
        switch self {
        case .bazi: "八字"
        case .ziwei: "紫微斗数"
        case .liuyao: "六爻"
        case .meihua: "梅花易数"
        case .qimen: "奇门遁甲"
        case .xiaoliuren: "小六壬"
        case .chenggu: "称骨"
        case .xingming: "姓名五格"
        case .astrology: "西方占星"
        case .tarot: "塔罗牌"
        }
    }
}
