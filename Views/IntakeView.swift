import SwiftUI

struct IntakeView: View {
    let plan: OraclePlan
    let onConfirm: (OracleProfile, [Int], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profile: OracleProfile
    @State private var birthDateKnown: Bool
    @State private var birthDate: Date
    @State private var lastValidBirthZoneID: String
    @State private var birthDateChoiceChanged = false
    @State private var birthTimeChoiceChanged = false
    @State private var birthClockEdited = false
    @State private var birthZoneEdited = false
    @State private var keepProfile = true
    @State private var error: String?
    @StateObject private var location = LocationService()
    private var isEditing: Bool { plan.intent == "编辑基础资料" }

    init(plan: OraclePlan, profile: OracleProfile, onConfirm: @escaping (OracleProfile, [Int], Bool) -> Void) {
        var editable = profile
        // Preserve explicit markers from saved profiles before adding the
        // editor's defaults for missing data on a new, empty profile.
        editable.declaredUnknownFields = profile.declaredUnknownFields ?? profile.unknownFields
        let empty = [profile.name ?? "", profile.fullName, profile.displayName, profile.birthDateText ?? "", profile.birthTimeText ?? ""]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if empty, profile.birthDate == nil, profile.birthPlace.isEmpty, profile.birthLatitude == nil, profile.birthLongitude == nil {
            editable.birthTimeZoneID = "UTC"
            editable.birthTimeKnown = false
            editable.unknownFields.formUnion([.birthDate, .birthTime, .birthTimeZone, .gender, .birthPlace, .birthCoordinates])
        }
        self.plan = plan; self.onConfirm = onConfirm
        _profile = State(initialValue: editable)
        _birthDateKnown = State(initialValue: editable.birthDate != nil && !editable.unknownFields.contains(.birthDate))
        _birthDate = State(initialValue: Self.initialClockDate(for: editable))
        _lastValidBirthZoneID = State(initialValue: TimeZone(identifier: editable.birthTimeZoneID) == nil ? "UTC" : editable.birthTimeZoneID)
    }
    static var initialBirthDate: Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 1995, month: 1, day: 1, hour: 12))!
    }

    private static func initialClockDate(for profile: OracleProfile) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: profile.birthTimeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        var parts = profile.birthDate.map { calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) }
            ?? DateComponents(year: 1995, month: 1, day: 1, hour: 12, minute: 0, second: 0)
        if let text = profile.birthTimeText {
            let clock = text.split(separator: ":").compactMap { Int($0) }
            if (clock.count == 2 || clock.count == 3), (0...23).contains(clock[0]), (0...59).contains(clock[1]),
               clock.count == 2 || (0...59).contains(clock[2]) {
                parts.hour = clock[0]; parts.minute = clock[1]
                if clock.count == 3 { parts.second = clock[2] }
            }
        }
        return calendar.date(from: parts) ?? initialBirthDate
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
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
                                SectionEyebrow(text: "姓名")
                                TextField("填写姓名", text: nameBinding).textContentType(.name).autocorrectionDisabled()
                                    .accessibilityIdentifier("profileName")
                                Divider()
                                Text("姓名推演用字 · 选填").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                HStack(spacing: 16) {
                                            TextField("姓氏", text: $profile.familyName).textContentType(.familyName).accessibilityIdentifier("profileSurname")
                                            Divider().frame(height: 24)
                                            TextField("名字", text: $profile.givenName).textContentType(.givenName).accessibilityIdentifier("profileGivenName")
                                }
                                Toggle("姓与名的划分不确定", isOn: unknownBinding(.surname, also: .givenName)).font(.system(size: 12)).tint(InkTheme.sage)
                                Text("使用姓名五格时，可在这里核对姓与名的划分及繁体字形。暂不确定也可以保存。")
                                    .font(.system(size: 10)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                            }.font(.system(size: 15, design: .serif))
                        }
                        birthSection
                        currentLocationSection
                if !isEditing { Toggle(isOn: $keepProfile) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("把这份基础资料留在本机").font(.system(size: 13, design: .serif))
                                Text("以后问事可以直接取用，不随对话压缩。").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                            }
                        }.tint(InkTheme.sage) }
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
            .onReceive(location.$place) { place in
                guard let place else { return }
                place.apply(to: &profile, purpose: .current)
            }
            .onDisappear { location.cancel() }
            .onChange(of: profile.birthTimeZoneID) { _, new in
                birthZoneEdited = true
                guard let oldZone = TimeZone(identifier: lastValidBirthZoneID), let newZone = TimeZone(identifier: new) else { return }
                var oldCalendar = Calendar(identifier: .gregorian); oldCalendar.timeZone = oldZone
                var newCalendar = Calendar(identifier: .gregorian); newCalendar.timeZone = newZone
                let clock = oldCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: birthDate)
                if let newInstant = newCalendar.date(from: clock) { birthDate = newInstant }
                lastValidBirthZoneID = new
                profile.unknownFields.remove(.birthTimeZone)
            }
            .onChange(of: profile.fullName) { _, value in
                if !value.isEmpty { profile.name = value }
            }
            .onChange(of: birthDateKnown) { _, _ in birthDateChoiceChanged = true }
            .onChange(of: profile.birthTimeKnown) { _, _ in birthTimeChoiceChanged = true }
            .onChange(of: profile.unknownFields.contains(.birthTimeZone)) { _, _ in birthZoneEdited = true }
            .onChange(of: profile.currentPlace) { _, value in
                if location.isLocating { location.cancel() }
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { profile.unknownFields.remove(.currentLocation) }
            }
            .onChange(of: profile.currentTimeZoneID) { _, _ in
                if location.isLocating { location.cancel() }
            }
            .onChange(of: profile.currentLatitude) { _, _ in updateCurrentCoordinates() }
            .onChange(of: profile.currentLongitude) { _, _ in updateCurrentCoordinates() }
        }.presentationDragIndicator(.visible)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { profile.name ?? profile.resolvedName }, set: { value in
            profile.name = value
            if !profile.fullName.isEmpty, value != profile.fullName {
                profile.familyName = ""; profile.givenName = ""
                profile.unknownFields.insert(.surname); profile.unknownFields.insert(.givenName)
            }
        })
    }

    private var birthClockBinding: Binding<Date> {
        Binding(get: { birthDate }, set: { value in
            if value != birthDate { birthClockEdited = true }
            birthDate = value
        })
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
                DatePicker("公历日期", selection: birthClockBinding, in: Self.allowedBirthDates, displayedComponents: .date)
                        .font(.system(size: 14)).environment(\.timeZone, TimeZone(identifier: profile.birthTimeZoneID) ?? TimeZone(identifier: lastValidBirthZoneID)!)
                        .disabled(!birthDateKnown).opacity(birthDateKnown ? 1 : 0.45).accessibilityIdentifier("profileBirthDate")
                if !birthDateKnown {
                    Text("日期尚未填写。确认已知后，再选择公历日期。")
                        .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                }
                Divider()
                Toggle("出生时刻已知", isOn: $profile.birthTimeKnown)
                    .font(.system(size: 14, design: .serif)).tint(InkTheme.sage).accessibilityIdentifier("birthTimeKnown")
                DatePicker("当地钟表时间", selection: birthClockBinding, displayedComponents: .hourAndMinute)
                        .font(.system(size: 14)).environment(\.timeZone, TimeZone(identifier: profile.birthTimeZoneID) ?? TimeZone(identifier: lastValidBirthZoneID)!)
                        .disabled(!profile.birthTimeKnown).opacity(profile.birthTimeKnown ? 1 : 0.45).accessibilityIdentifier("profileBirthTime")
                if profile.birthTimeKnown {
                    if !birthDateKnown {
                        Text("先单独记下这个时刻，出生日期可以以后补充。")
                            .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    }
                } else {
                    Text("时辰留作未知，不会用现在的时间代替。").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                }
                Divider()
                HStack {
                    Text("排盘性别").font(.system(size: 14, design: .serif))
                    Spacer()
                    Picker("排盘性别", selection: $profile.sex) {
                        Text("不确定").tag("未提供"); Text("男").tag("男"); Text("女").tag("女")
                    }.labelsHidden().tint(InkTheme.ink).accessibilityIdentifier("profileGender")
                }
                PlaceFields(profile: $profile)
                Toggle("出生地不确定", isOn: unknownBinding(.birthPlace, also: .birthCoordinates)).font(.system(size: 12)).tint(InkTheme.sage)
                Toggle("出生地时区不确定", isOn: unknownBinding(.birthTimeZone)).font(.system(size: 12)).tint(InkTheme.sage)
                Toggle("出生坐标不确定", isOn: unknownBinding(.birthCoordinates)).font(.system(size: 12)).tint(InkTheme.sage)
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
                    }.tint(InkTheme.cinnabar).disabled(location.isLocating).accessibilityIdentifier("useCurrentLocation")
                }
                TextField("也可手动写下当前城市", text: $profile.currentPlace).font(.system(size: 13, design: .serif)).accessibilityIdentifier("profileCurrentPlace")
                Text("当前时区").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    TextField("IANA 时区", text: $profile.currentTimeZoneID).textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(size: 12)).padding(.top, 10)
                    .accessibilityIdentifier("profileCurrentTimeZone")
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("当前纬度").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                        TextField("纬度", value: $profile.currentLatitude, format: .number.precision(.fractionLength(0...6)))
                            .accessibilityIdentifier("profileCurrentLatitude")
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("当前经度").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                        TextField("经度", value: $profile.currentLongitude, format: .number.precision(.fractionLength(0...6)))
                            .accessibilityIdentifier("profileCurrentLongitude")
                    }
                }.font(.system(size: 12)).keyboardType(.numbersAndPunctuation)
                Toggle("当前所在地不确定", isOn: unknownBinding(.currentLocation)).font(.system(size: 12)).tint(InkTheme.sage)
                if let message = location.message { Text(message).font(.system(size: 11)).foregroundStyle(InkTheme.secondary) }
                Text("此处定位只填写当前所在地。").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
            }.foregroundStyle(InkTheme.ink)
        }
    }
    private func unknownBinding(_ field: OracleField, also other: OracleField? = nil) -> Binding<Bool> {
        Binding(get: { profile.declaredUnknownFields?.contains(field) == true }, set: { value in
            var declared = profile.declaredUnknownFields ?? []
            if value {
                profile.unknownFields.insert(field); declared.insert(field)
                if let other { profile.unknownFields.insert(other); declared.insert(other) }
            } else {
                profile.unknownFields.remove(field); declared.remove(field)
                if let other { profile.unknownFields.remove(other); declared.remove(other) }
            }
            profile.declaredUnknownFields = declared
        })
    }
    private func updateCurrentCoordinates() {
        if location.isLocating { location.cancel() }
        if let latitude = profile.currentLatitude, let longitude = profile.currentLongitude,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            profile.unknownFields.remove(.currentLocation)
        }
    }
    private func confirm() {
        // Numeric casting now has its own requested interaction after intake.
        let parsed: [Int] = []
        let name = (profile.name ?? profile.resolvedName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "请填写这份资料对应的姓名。"; return }
        profile.name = name; profile.displayName = name
        if profile.familyName.isEmpty || profile.givenName.isEmpty {
            profile.unknownFields.insert(.surname); profile.unknownFields.insert(.givenName)
        } else {
            profile.unknownFields.remove(.surname); profile.unknownFields.remove(.givenName)
        }
        // A name-only edit must not round seconds or reconstruct an ambiguous
        // DST instant. Normalize the birth clock only after an explicit edit.
        if birthDateChoiceChanged || birthTimeChoiceChanged || birthClockEdited || birthZoneEdited {
          if birthDateKnown {
            guard let zone = TimeZone(identifier: profile.birthTimeZoneID) else { error = "时区名称无法识别，请从列表选择或填写有效的时区标识。"; return }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: birthDate)
            if !profile.birthTimeKnown { components.hour = 12; components.minute = 0 }
            guard let instant = calendar.date(from: components) else { error = "出生日期或时间暂时无法识别，请检查。"; return }
            profile.birthDate = instant; profile.unknownFields.remove(.birthDate)
            profile.birthDateText = String(format: "%04d-%02d-%02d", components.year ?? 1995, components.month ?? 1, components.day ?? 1)
          } else {
            profile.birthDate = nil
            if birthDateChoiceChanged { profile.birthDateText = nil }
            profile.unknownFields.insert(.birthDate)
          }
          if profile.birthTimeKnown {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: profile.birthTimeZoneID) ?? TimeZone(secondsFromGMT: 0)!
            let clock = calendar.dateComponents([.hour, .minute], from: birthDate)
            profile.birthTimeText = String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0)
            profile.unknownFields.remove(.birthTime)
          } else {
            if birthTimeChoiceChanged { profile.birthTimeText = nil }
            profile.unknownFields.insert(.birthTime)
          }
        }
        if profile.sex == "未提供" { profile.unknownFields.insert(.gender) } else { profile.unknownFields.remove(.gender) }
        guard TimeZone(identifier: profile.currentTimeZoneID) != nil else { error = "当前时区名称无法识别，请填写有效的时区标识。"; return }
        if let latitude = profile.currentLatitude, !(-90...90).contains(latitude) { error = "当前纬度应在 −90 到 90 之间。"; return }
        if let longitude = profile.currentLongitude, !(-180...180).contains(longitude) { error = "当前经度应在 −180 到 180 之间。"; return }
        if profile.currentPlace.isEmpty && profile.currentLatitude == nil { profile.unknownFields.insert(.currentLocation) }
        if profile.birthPlace.isEmpty { profile.unknownFields.insert(.birthPlace) }
        if profile.unknownFields.contains(.birthCoordinates) { profile.birthLatitude = nil; profile.birthLongitude = nil }
        if profile.birthLatitude == nil || profile.birthLongitude == nil { profile.unknownFields.insert(.birthCoordinates) }
        else if !(-90...90).contains(profile.birthLatitude!) || !(-180...180).contains(profile.birthLongitude!) { error = "纬度范围为 −90 到 90，经度范围为 −180 到 180。"; return }
        else { profile.unknownFields.remove(.birthCoordinates) }
        if parsed.isEmpty { profile.unknownFields.insert(.numbers) } else { profile.unknownFields.remove(.numbers) }
        var declared = profile.declaredUnknownFields ?? []
        if birthDateChoiceChanged {
            if birthDateKnown { declared.remove(.birthDate) } else { declared.insert(.birthDate) }
        }
        if birthTimeChoiceChanged {
            if profile.birthTimeKnown { declared.remove(.birthTime) } else { declared.insert(.birthTime) }
        }
        // Filling a field resolves its old explicit-unknown marker. Merely
        // leaving a default field blank does not create a new declaration.
        profile.declaredUnknownFields = declared.intersection(profile.unknownFields)
        profile.updatedAt = Date(); onConfirm(profile, parsed, keepProfile)
    }
    private static var allowedBirthDates: ClosedRange<Date> {
        Date(timeIntervalSince1970: -2_208_988_800)...Date(timeIntervalSince1970: 4_133_980_799)
    }
}

struct PlaceFields: View {
    @Binding var profile: OracleProfile
    @StateObject private var location = LocationService()
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                TextField("出生城市（不确定可留空）", text: $profile.birthPlace).font(.system(size: 14, design: .serif)).accessibilityIdentifier("profileBirthPlace")
                Menu {
                    ForEach(LocalPlace.catalog) { place in
                        Button(place.name) {
                            location.cancel()
                            place.apply(to: &profile, purpose: .birth)
                        }
                    }
                } label: { Label("常用城市", systemImage: "mappin.and.ellipse").font(.system(size: 11)).foregroundStyle(InkTheme.cinnabar) }
            }
            HStack(spacing: 8) {
                Button { location.request() } label: {
                    HStack(spacing: 5) {
                        if location.isLocating { ProgressView().controlSize(.small) }
                        else { Image(systemName: "location") }
                        Text(location.isLocating ? "正在定位…" : "使用当前位置")
                    }.font(.system(size: 12))
                }.tint(InkTheme.cinnabar).disabled(location.isLocating)
                    .accessibilityIdentifier("useCurrentLocationForBirthPlace")
                Spacer(minLength: 0)
            }
            Text("若出生地就是当前位置，可一键填写地点、坐标和当地时区。")
                .font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
            if let message = location.message {
                Text(message).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    .accessibilityIdentifier("birthLocationMessage")
            }
            HStack {
                Text("出生地时区").font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                Spacer()
                Menu {
                    ForEach(["Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo", "Asia/Singapore", "Asia/Urumqi", "Europe/London", "America/New_York", "America/Los_Angeles", "Australia/Sydney", "UTC"], id: \.self) { zone in
                        Button(zone) {
                            location.cancel()
                            profile.birthTimeZoneID = zone; profile.unknownFields.remove(.birthTimeZone)
                        }
                    }
                } label: { Text(profile.birthTimeZoneID).font(.system(size: 12)).foregroundStyle(InkTheme.ink) }
            }
            TextField("IANA 时区，如 Asia/Shanghai", text: $profile.birthTimeZoneID).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(size: 12)).accessibilityIdentifier("profileBirthTimeZone")
                    HStack(spacing: 16) {
                      VStack(alignment: .leading, spacing: 7) {
                        Text("出生纬度").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                        TextField("纬度", value: $profile.birthLatitude, format: .number.precision(.fractionLength(0...6)))
                            .accessibilityIdentifier("profileBirthLatitude")
                      }
                      VStack(alignment: .leading, spacing: 7) {
                        Text("出生经度").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                        TextField("经度", value: $profile.birthLongitude, format: .number.precision(.fractionLength(0...6)))
                            .accessibilityIdentifier("profileBirthLongitude")
                      }
                    }.font(.system(size: 12)).keyboardType(.numbersAndPunctuation)
                    Text("常用城市坐标来自内置表；不在列表的地点可手动填写。坐标未知时，相关宫位会留白。")
                        .font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
        }
        .onReceive(location.$place) { place in
            guard let place else { return }
            place.apply(to: &profile, purpose: .birth)
        }
        .onDisappear { location.cancel() }
        .onChange(of: profile.birthPlace) { _, place in
            if location.isLocating { location.cancel() }
            if !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { profile.unknownFields.remove(.birthPlace) }
        }
        .onChange(of: profile.birthTimeZoneID) { _, _ in
            if location.isLocating { location.cancel() }
        }
        .onChange(of: profile.birthLatitude) { _, _ in updateCoordinates() }
        .onChange(of: profile.birthLongitude) { _, _ in updateCoordinates() }
    }

    private func updateCoordinates() {
        if location.isLocating { location.cancel() }
        if let latitude = profile.birthLatitude, let longitude = profile.birthLongitude,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            profile.unknownFields.remove(.birthCoordinates)
        }
    }
}

struct ProfileEditor: View {
    let profile: OracleProfile
    let onSave: (OracleProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        IntakeView(plan: OraclePlan(intent: "编辑基础资料", subject: "事件", methods: [], requiredFields: [], note: "", question: "保存一份具名资料，往后直接选取。"), profile: profile) { updated, _, _ in
            onSave(updated); dismiss()
        }.id(profile.id)
    }
}
