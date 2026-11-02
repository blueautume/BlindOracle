import Foundation

struct IntakeAnswer {
    var updates: [ProfileUpdate] = []
    var clarification: String? = nil
    var pendingAnswer: String? = nil
    var declinedName = false
}

enum ConversationalIntake {
    static func isConfirmation(_ text: String) -> Bool {
        guard !text.contains("？"), !text.contains("?") else { return false }
        let value = text.components(separatedBy: .whitespacesAndNewlines.union(.punctuationCharacters)).joined()
        return ["确认", "确认开始", "确认开始解析", "确认无误", "资料无误", "没问题", "没有问题", "信息正确", "正确", "开始", "开始解析", "可以开始", "可以开始解析", "可以", "对", "是的", "就按这个算", "按以上资料开始", "没问题开始", "没问题开始解析", "没有问题开始解析", "资料无误开始解析", "信息没问题开始解析"].contains(value)
    }

    static func isUnknown(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["不知道", "不清楚", "不确定", "未知", "不详", "忘了", "记不清", "没资料", "没有资料", "无法提供", "不想提供", "都不知道", "这些都不知道", "其余都不知道"].contains(value)
    }

    static func answer(_ text: String, plan: OraclePlan, profiles: [OracleProfile]) -> IntakeAnswer {
        guard let fields = plan.requestedFields, !fields.isEmpty else { return IntakeAnswer() }
        if fields.contains(.name) {
            if isUnknown(text) { return IntakeAnswer(declinedName: true) }
            if !ProfileDirectory.parseExplicitUpdates(in: text, profiles: profiles).isEmpty { return IntakeAnswer() }
            let names = text.components(separatedBy: CharacterSet(charactersIn: "、，,；;\n和与"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let excluded = ["继续", "取消", "开始", "公历", "农历", "北京时间", "好的", "是的", "可以", "谢谢", "没问题", "朋友", "本人", "自己", "家人", "对象", "同事", "父亲", "母亲", "孩子", "男友", "女友"]
            let valid = names.filter { matches(#"^(?:[\p{Han}]{2,6}|[A-Za-z][A-Za-z' -]{1,47})$"#, $0) && !excluded.contains(where: $0.contains) }
            guard valid.count == names.count else { return IntakeAnswer() }
            return IntakeAnswer(updates: valid.map { ProfileUpdate(name: $0) })
        }
        guard let id = plan.requestedProfileID, let person = profiles.first(where: { $0.id == id }) else { return IntakeAnswer() }
        let named = ProfileDirectory.parseExplicitUpdates(in: text, profiles: profiles)
        if named.contains(where: { $0.name != person.resolvedName }) { return IntakeAnswer() }
        if isUnknown(text) {
            return IntakeAnswer(updates: [ProfileUpdate(id: id, name: person.resolvedName,
                                                       birthTimeKnown: fields.contains(.birthTime) ? false : nil, unknownFields: fields)])
        }
        let content = (plan.pendingAnswer.map { $0 + "，" } ?? "") + text
        if fields.contains(.birthDate), content.contains("农历") || content.contains("阴历") {
            return IntakeAnswer(clarification: "这条是农历日期。请再告诉我对应的公历年月日，避免把日期记错。")
        }
        var updates: [ProfileUpdate] = []
        for field in fields {
            var patch = ProfileUpdate(id: id, name: person.resolvedName)
            if field == .birthDate || field == .birthTime {
                if content.contains("北京时间") || content.contains("东八区") { patch.birthTimeZoneID = "Asia/Shanghai" }
                if field == .birthDate { patch.birthTime = clock(in: content) }
            }
            switch field {
            case .birthTime:
                if let clock = clock(in: content) {
                    patch.birthTime = clock
                } else if matches(#"[\d零〇一二两三四五六七八九十]+[点时]"#, content) {
                    return IntakeAnswer(clarification: "你说的这个时刻，是上午、下午还是晚上？我确认一下再记。", pendingAnswer: text)
                }
            case .birthCoordinates:
                if let pair = captures(#"^\s*([+-]?\d{1,2}(?:\.\d+)?)\s*[,，、 /]\s*([+-]?\d{1,3}(?:\.\d+)?)\s*$"#, content) {
                    patch.birthLatitude = Double(pair[0]); patch.birthLongitude = Double(pair[1])
                }
            default:
                let label: String
                switch field {
                case .birthDate: label = "出生日期"
                case .birthTimeZone: label = "出生时区"
                case .birthPlace: label = "出生地"
                case .gender: label = "性别"
                case .surname: label = "姓氏"
                case .givenName: label = "名字"
                default: label = field.title
                }
                updates += ProfileDirectory.parseExplicitUpdates(in: "姓名：\(person.resolvedName)，\(label)：\(content)", profiles: profiles)
            }
            if patch.birthTime != nil || patch.birthTimeZoneID != nil || patch.birthLatitude != nil { updates.append(patch) }
        }
        return IntakeAnswer(updates: updates)
    }

    static func summary(plan: OraclePlan, participants: [OracleProfile]) -> String {
        var lines = ["我把这次的信息整理好了，请核对：", "", "所问：\(plan.question)"]
        if let methods = plan.mandatoryMethods, !methods.isEmpty { lines.append("本次指定方法：\(methods.map(\.progressName).joined(separator: "、"))。") }
        if participants.isEmpty { lines.append("对象：这件事本身，不附个人生辰资料。") }
        for person in participants {
            lines.append("")
            lines.append("姓名：\(person.resolvedName)")
            if !person.familyName.isEmpty || !person.givenName.isEmpty { lines.append("姓氏：\(person.familyName.isEmpty ? "未确定" : person.familyName)；名字：\(person.givenName.isEmpty ? "未确定" : person.givenName)") }
            let date: String
            if person.unknownFields.contains(.birthDate) { date = "未确定" }
            else if let text = person.birthDateText { date = text }
            else if let instant = person.birthDate {
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(identifier: person.birthTimeZoneID) ?? .gmt
                date = formatter.string(from: instant)
            } else { date = "未提供" }
            lines.append("公历生日：\(date)")
            let time = person.birthTimeKnown && !person.unknownFields.contains(.birthTime)
                ? person.birthTimeText ?? person.birthDate.map { value in
                    let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; formatter.timeZone = TimeZone(identifier: person.birthTimeZoneID) ?? .gmt
                    return formatter.string(from: value)
                } ?? "未提供" : "未确定"
            lines.append("出生时间：\(time)")
            lines.append("出生时区：\(person.unknownFields.contains(.birthTimeZone) ? "未确定" : person.birthTimeZoneID)")
            lines.append("性别：\(person.sex)；出生地：\(person.birthPlace.isEmpty ? "未提供" : person.birthPlace)")
            if let lat = person.birthLatitude, let lon = person.birthLongitude, !person.unknownFields.contains(.birthCoordinates) { lines.append("出生地坐标：纬度\(lat)，经度\(lon)") }
        }
        if !(plan.preparationNotes ?? []).isEmpty { lines += [""] + (plan.preparationNotes ?? []) }
        lines += ["", "信息无误后，回复“确认，开始”，或点下方确认。需要更正的地方直接告诉我，我会重新整理。"]
        return lines.joined(separator: "\n")
    }

    private static func clock(in text: String) -> String? {
        let text = normalizingClockNumerals(text)
        if let pieces = captures(#"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?!\d)"#, text) {
            return String(format: "%02d:%02d", Int(pieces[0])!, Int(pieces[1])!) + (pieces.count > 2 && !pieces[2].isEmpty ? ":" + pieces[2] : "")
        }
        guard let pieces = captures(#"(\d{1,2})[点时](?:(\d{1,2})分?)?(半)?"#, text), var hour = Int(pieces[0]), (0...23).contains(hour) else { return nil }
        let morning = ["凌晨", "早上", "上午", "清晨"].contains(where: text.contains)
        let evening = ["下午", "晚上", "傍晚", "夜里"].contains(where: text.contains)
        guard morning || evening || text.contains("中午") || hour > 12 || hour == 0 else { return nil }
        if evening, hour < 12 { hour += 12 }
        if text.contains("中午"), hour < 11 { hour += 12 }
        if hour == 12, ["凌晨", "晚上", "夜里"].contains(where: text.contains) { hour = 0 }
        let minute = pieces.count > 2 && !pieces[2].isEmpty ? 30 : Int(pieces[1]) ?? 0
        guard (0...59).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func normalizingClockNumerals(_ text: String) -> String {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        guard let regex = try? NSRegularExpression(pattern: #"[零〇一二两三四五六七八九十]+(?=[点时分])"#) else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let raw = result.substring(with: match.range)
            let value: Int?
            if let ten = raw.firstIndex(of: "十") {
                let leading = raw[..<ten].first.flatMap { digits[$0] } ?? 1
                let trailing = raw[raw.index(after: ten)...].first.flatMap { digits[$0] } ?? 0
                value = leading * 10 + trailing
            } else { value = raw.first.flatMap { digits[$0] } }
            if let value { result.replaceCharacters(in: match.range, with: String(value)) }
        }
        return result as String
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let source = text as NSString
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
    }
}
