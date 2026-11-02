import SwiftUI

struct IntakeView: View {
    let plan: OraclePlan
    let initialProfile: OracleProfile
    let onConfirm: (OracleProfile, [Int], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: OracleStore
    @State private var profile: OracleProfile
    @State private var birthDateKnown: Bool
    @State private var birthDate: Date
    @State private var keepProfile = true
    @State private var showBirthDetails = false
    @State private var error: String?
    @StateObject private var location = LocationService()
    private var needsBirth: Bool { plan.requiredFields.contains { [.birthDate, .birthTime, .birthPlace, .birthTimeZone, .birthCoordinates].contains($0) } }
    private var needsName: Bool { plan.requiredFields.contains(.surname) || plan.requiredFields.contains(.givenName) }
    private var isEditing: Bool { plan.intent == "编辑基础资料" }

    init(plan: OraclePlan, profile: OracleProfile, onConfirm: @escaping (OracleProfile, [Int], Bool) -> Void) {
        self.plan = plan; initialProfile = profile; self.onConfirm = onConfirm
        _profile = State(initialValue: profile)
        _birthDateKnown = State(initialValue: profile.birthDate != nil && !profile.unknownFields.contains(.birthDate))
        _birthDate = State(initialValue: profile.birthDate ?? Self.initialBirthDate)
        _showBirthDetails = State(initialValue: plan.intent == "编辑基础资料")
    }
    static var initialBirthDate: Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 1995, month: 1, day: 1, hour: 12))!
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if plan.subject == "他人", store.profiles.count > 1 {
                            Menu("从留存资料中选取") {
                                ForEach(store.profiles.dropFirst()) { saved in
                                    Button(saved.displayName.isEmpty ? saved.fullName : saved.displayName) {
                                        profile = saved
                                        birthDateKnown = saved.birthDate != nil && !saved.unknownFields.contains(.birthDate)
                                        birthDate = saved.birthDate ?? Self.initialBirthDate
                                    }
                                }
                            }.font(.system(size: 13)).tint(InkTheme.cinnabar)
                        }
                        if !isEditing { PaperCard {
                            VStack(alignment: .leading, spacing: 16) {
                                SectionEyebrow(text: "此次所问")
                                Text(plan.question).font(.system(size: 18, design: .serif)).lineSpacing(7).foregroundStyle(InkTheme.ink)
                                HStack {
                                    InkPill(text: plan.subject == "他人" ? "为他人问" : plan.subject == "事件" ? "为一件事问" : "为自己问")
                                    Spacer()
                                    Text(Date.now, format: .dateTime.month().day().hour().minute()).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                }
                            }
                        } }
                        PaperCard {
                            VStack(alignment: .leading, spacing: 16) {
                                SectionEyebrow(text: "留个称呼")
                                TextField("怎么称呼你（可不填）", text: $profile.displayName).textContentType(.nickname)
                                if needsName || showBirthDetails {
                                    Divider()
                                    HStack(spacing: 16) {
                                        TextField("姓氏", text: $profile.familyName).textContentType(.familyName)
                                        Divider().frame(height: 24)
                                        TextField("名字", text: $profile.givenName).textContentType(.givenName)
                                    }
                                    Toggle("姓名不确定", isOn: unknownBinding(.surname, also: .givenName)).font(.system(size: 12)).tint(InkTheme.sage)
                                    Text("姓名推演以确认的繁体字形为准；简体转换候选会在数据页留作待核对。").font(.system(size: 10)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                                }
                            }.font(.system(size: 15, design: .serif))
                        }
                        if needsBirth || showBirthDetails { birthSection }
                        currentLocationSection
                        if !needsBirth {
                            Button { withAnimation { showBirthDetails.toggle() } } label: {
                                Label(showBirthDetails ? "收起其他资料" : "补充其他基础资料", systemImage: showBirthDetails ? "minus.circle" : "plus.circle")
                                    .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                            }
                        }
                        Toggle(isOn: $keepProfile) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("把这份基础资料留在本机").font(.system(size: 13, design: .serif))
                                Text("以后问事可以直接取用，不随对话压缩。").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                            }
                        }.tint(InkTheme.sage)
                        if let error { Text(error).font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar) }
                        Button(action: confirm) { HStack { Text(isEditing ? "保存基础资料" : "落笔，交给先知"); Image(systemName: "arrow.right") } }.buttonStyle(InkPrimaryButton()).accessibilityIdentifier("confirmIntake")
                        Text(isEditing ? "基础档案独立保存在本机。" : "问题、所需资料与推演摘要会用于 AI 解读；基础档案保存在本机。")
                            .font(.system(size: 10)).foregroundStyle(InkTheme.secondary).lineSpacing(4).frame(maxWidth: .infinity, alignment: .center)
                    }.frame(maxWidth: 620).padding(24).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(isEditing ? "基础资料" : "问事笺").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("稍后填写") { dismiss() }.font(.system(size: 13)).foregroundStyle(InkTheme.secondary) } }
            .toolbarBackground(InkTheme.paper, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .onReceive(location.$coordinate) { coordinate in
                guard let coordinate else { return }
                profile.currentLatitude = coordinate.latitude; profile.currentLongitude = coordinate.longitude
                profile.currentTimeZoneID = TimeZone.current.identifier
                let nearby = LocalPlace.catalog.min { distance($0, coordinate.latitude, coordinate.longitude) < distance($1, coordinate.latitude, coordinate.longitude) }
                if let nearby, distance(nearby, coordinate.latitude, coordinate.longitude) < 0.25 { profile.currentPlace = nearby.name }
                else { profile.currentPlace = String(format: "%.3f°, %.3f°", coordinate.latitude, coordinate.longitude) }
                profile.unknownFields.remove(.currentLocation)
            }
            .onChange(of: profile.birthTimeZoneID) { old, new in
                guard let oldZone = TimeZone(identifier: old), let newZone = TimeZone(identifier: new) else { return }
                var oldCalendar = Calendar(identifier: .gregorian); oldCalendar.timeZone = oldZone
                var newCalendar = Calendar(identifier: .gregorian); newCalendar.timeZone = newZone
                let clock = oldCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: birthDate)
                if let newInstant = newCalendar.date(from: clock) { birthDate = newInstant }
            }
        }.presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            OracleMark(size: 52)
            VStack(alignment: .leading, spacing: 7) {
                Text("写下已知，留白未知。").font(.system(size: 22, design: .serif)).foregroundStyle(InkTheme.ink)
                Text("不必勉强记起每一件事。").font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
            }
        }.padding(.bottom, 2)
    }

    private var birthSection: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 17) {
                SectionEyebrow(text: "生辰与来处")
                Toggle("出生日期已知", isOn: $birthDateKnown).font(.system(size: 15, design: .serif)).tint(InkTheme.sage).accessibilityIdentifier("birthDateKnown")
                if birthDateKnown {
                    DatePicker("公历日期", selection: $birthDate, in: Self.allowedBirthDates, displayedComponents: .date)
                        .font(.system(size: 14)).environment(\.timeZone, TimeZone(identifier: profile.birthTimeZoneID) ?? .current)
                    Divider()
                    Toggle("出生时刻已知", isOn: $profile.birthTimeKnown).font(.system(size: 14, design: .serif)).tint(InkTheme.sage)
                    if profile.birthTimeKnown {
                        DatePicker("当地钟表时间", selection: $birthDate, displayedComponents: .hourAndMinute)
                            .font(.system(size: 14)).environment(\.timeZone, TimeZone(identifier: profile.birthTimeZoneID) ?? .current)
                    } else {
                        Text("时辰留作未知，不会用现在的时间代替。").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    }
                } else {
                    Text("先保留这份不确定，能推演的部分仍会继续。").font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                }
                Divider()
                HStack {
                    Text("排盘性别").font(.system(size: 14, design: .serif))
                    Spacer()
                    Picker("排盘性别", selection: $profile.sex) {
                        Text("不确定").tag("未提供"); Text("男").tag("男"); Text("女").tag("女")
                    }.labelsHidden().tint(InkTheme.ink)
                }
                PlaceFields(profile: $profile)
                Toggle("出生地不确定", isOn: unknownBinding(.birthPlace, also: .birthCoordinates)).font(.system(size: 12)).tint(InkTheme.sage)
                Toggle("出生地时区不确定", isOn: unknownBinding(.birthTimeZone)).font(.system(size: 12)).tint(InkTheme.sage)
            }.foregroundStyle(InkTheme.ink)
        }
    }

    private var currentLocationSection: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(text: "此刻所在")
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.currentPlace.isEmpty ? "尚未填写所在地" : profile.currentPlace).font(.system(size: 15, design: .serif))
                        Text(profile.currentTimeZoneID).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    }
                    Spacer()
                    Button { location.request() } label: {
                        if location.isLocating { ProgressView().controlSize(.small) }
                        else { Label("自动填写", systemImage: "location").font(.system(size: 12)) }
                    }.tint(InkTheme.cinnabar).disabled(location.isLocating)
                }
                TextField("也可手动写下当前城市", text: $profile.currentPlace).font(.system(size: 13, design: .serif))
                DisclosureGroup("当前时区") {
                    TextField("IANA 时区", text: $profile.currentTimeZoneID).textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(size: 12)).padding(.top, 10)
                }.font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                if let message = location.message { Text(message).font(.system(size: 11)).foregroundStyle(InkTheme.secondary) }
                Text("定位只填写当前所在地，出生地请另行确认。").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
            }.foregroundStyle(InkTheme.ink)
        }
    }
    private func unknownBinding(_ field: OracleField, also other: OracleField? = nil) -> Binding<Bool> {
        Binding(get: { profile.unknownFields.contains(field) }, set: { value in
            if value { profile.unknownFields.insert(field); if let other { profile.unknownFields.insert(other) } }
            else { profile.unknownFields.remove(field); if let other { profile.unknownFields.remove(other) } }
        })
    }
    private func distance(_ place: LocalPlace, _ latitude: Double, _ longitude: Double) -> Double {
        pow(place.latitude - latitude, 2) + pow(place.longitude - longitude, 2)
    }
    private func confirm() {
        // Numeric casting now has its own requested interaction after intake.
        let parsed: [Int] = []
        if needsName && !profile.unknownFields.contains(.surname) && (profile.familyName.trimmingCharacters(in: .whitespaces).isEmpty || profile.givenName.trimmingCharacters(in: .whitespaces).isEmpty) {
            error = "请补上姓氏和名字，或者勾选“姓名不确定”。"; return
        }
        if birthDateKnown {
            guard let zone = TimeZone(identifier: profile.birthTimeZoneID) else { error = "时区名称无法识别，请从列表选择或填写有效的时区标识。"; return }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: birthDate)
            if !profile.birthTimeKnown { components.hour = 12; components.minute = 0 }
            guard let instant = calendar.date(from: components) else { error = "出生日期或时间暂时无法识别，请检查。"; return }
            profile.birthDate = instant; profile.unknownFields.remove(.birthDate)
            if profile.birthTimeKnown { profile.unknownFields.remove(.birthTime) } else { profile.unknownFields.insert(.birthTime) }
        } else {
            profile.birthDate = nil; profile.birthTimeKnown = false
            profile.unknownFields.insert(.birthDate); profile.unknownFields.insert(.birthTime)
        }
        if profile.sex == "未提供" { profile.unknownFields.insert(.gender) } else { profile.unknownFields.remove(.gender) }
        guard TimeZone(identifier: profile.currentTimeZoneID) != nil else { error = "当前时区名称无法识别，请填写有效的时区标识。"; return }
        if profile.currentPlace.isEmpty && profile.currentLatitude == nil { profile.unknownFields.insert(.currentLocation) }
        if profile.birthPlace.isEmpty { profile.unknownFields.insert(.birthPlace) }
        if profile.unknownFields.contains(.birthCoordinates) { profile.birthLatitude = nil; profile.birthLongitude = nil }
        if profile.birthLatitude == nil || profile.birthLongitude == nil { profile.unknownFields.insert(.birthCoordinates) }
        else if !(-90...90).contains(profile.birthLatitude!) || !(-180...180).contains(profile.birthLongitude!) { error = "纬度范围为 −90 到 90，经度范围为 −180 到 180。"; return }
        else { profile.unknownFields.remove(.birthCoordinates) }
        if parsed.isEmpty { profile.unknownFields.insert(.numbers) } else { profile.unknownFields.remove(.numbers) }
        if profile.displayName.isEmpty { profile.displayName = profile.fullName.isEmpty ? (plan.subject == "他人" ? "他人资料" : "我") : profile.fullName }
        profile.updatedAt = Date(); onConfirm(profile, parsed, keepProfile)
    }
    private static var allowedBirthDates: ClosedRange<Date> {
        Date(timeIntervalSince1970: -2_208_988_800)...Date(timeIntervalSince1970: 4_133_980_799)
    }
}

struct PlaceFields: View {
    @Binding var profile: OracleProfile
    @State private var showCoordinates = false
    @State private var previousZone = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                TextField("出生城市（不确定可留空）", text: $profile.birthPlace).font(.system(size: 14, design: .serif))
                Menu {
                    ForEach(LocalPlace.catalog) { place in
                        Button(place.name) {
                            profile.birthPlace = place.name; profile.birthLatitude = place.latitude; profile.birthLongitude = place.longitude; profile.birthTimeZoneID = place.timeZone
                            profile.unknownFields.remove(.birthPlace); profile.unknownFields.remove(.birthCoordinates); profile.unknownFields.remove(.birthTimeZone)
                        }
                    }
                } label: { Label("常用城市", systemImage: "mappin.and.ellipse").font(.system(size: 11)).foregroundStyle(InkTheme.cinnabar) }
            }
            HStack {
                Text("出生地时区").font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                Spacer()
                Menu {
                    ForEach(["Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo", "Asia/Singapore", "Asia/Urumqi", "Europe/London", "America/New_York", "America/Los_Angeles", "Australia/Sydney", "UTC"], id: \.self) { zone in
                        Button(zone) { profile.birthTimeZoneID = zone }
                    }
                } label: { Text(profile.birthTimeZoneID).font(.system(size: 12)).foregroundStyle(InkTheme.ink) }
            }
            DisclosureGroup("其他时区与经纬度", isExpanded: $showCoordinates) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("IANA 时区，如 Asia/Shanghai", text: $profile.birthTimeZoneID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        TextField("纬度", value: $profile.birthLatitude, format: .number.precision(.fractionLength(0...6)))
                        TextField("经度", value: $profile.birthLongitude, format: .number.precision(.fractionLength(0...6)))
                    }.keyboardType(.numbersAndPunctuation)
                    Text("常用城市坐标来自内置表；不在列表的地点可手动填写。坐标未知时，相关宫位会留白。")
                        .font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                }.font(.system(size: 12)).padding(.top, 12)
            }.font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
        }
    }
}

struct ProfileEditor: View {
    let profile: OracleProfile
    let onSave: (OracleProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        IntakeView(plan: OraclePlan(intent: "编辑基础资料", subject: "本人", methods: [], requiredFields: [.birthDate, .birthTime], note: "", question: "保存一份基础资料，往后少填几次。"), profile: profile) { updated, _, _ in
            onSave(updated); dismiss()
        }
    }
}
