import SwiftUI
import UIKit

struct ProfileFormError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ProfileFormDraft: Identifiable {
    var profile: OracleProfile
    var id: UUID { profile.id }
    var birthDateKnown: Bool
    var birthDate: Date
    var lastValidBirthZoneID: String
    var birthDateChoiceChanged = false
    var birthTimeChoiceChanged = false
    var birthClockEdited = false
    var birthZoneEdited = false

    init(profile: OracleProfile) {
        var editable = profile
        // Preserve explicit markers from saved profiles before adding the
        // editor's defaults for missing data on a new, empty profile.
        editable.declaredUnknownFields = profile.declaredUnknownFields ?? profile.unknownFields
        if profile.birthDate == nil { editable.unknownFields.insert(.birthDate) }
        // Legacy profiles may default to birthTimeKnown even when no clock was recorded.
        if !profile.birthTimeKnown || editable.unknownFields.contains(.birthTime)
            || (profile.birthDate == nil && (profile.birthTimeText ?? "").isEmpty) {
            editable.birthTimeKnown = false
            editable.unknownFields.insert(.birthTime)
        }
        if profile.resolvedName.isEmpty, profile.birthDate == nil, !editable.birthTimeKnown,
           profile.birthPlace.isEmpty, profile.birthLatitude == nil, profile.birthLongitude == nil {
            editable.birthTimeZoneID = OracleProfile.defaultChinaTimeZoneID
            editable.unknownFields.insert(.birthTimeZone)
        }
        if profile.sex == "未提供" { editable.unknownFields.insert(.gender) }
        if profile.birthPlace.isEmpty { editable.unknownFields.insert(.birthPlace) }
        if profile.birthLatitude == nil || profile.birthLongitude == nil { editable.unknownFields.insert(.birthCoordinates) }
        if TimeZone(identifier: profile.currentTimeZoneID) == nil {
            editable.currentTimeZoneID = OracleProfile.defaultChinaTimeZoneID
        }
        self.profile = editable
        birthDateKnown = editable.birthDate != nil && !editable.unknownFields.contains(.birthDate)
        birthDate = Self.initialClockDate(for: editable)
        lastValidBirthZoneID = TimeZone(identifier: editable.birthTimeZoneID) == nil ? "UTC" : editable.birthTimeZoneID
    }

    var birthZone: TimeZone {
        TimeZone(identifier: profile.birthTimeZoneID) ?? TimeZone(identifier: lastValidBirthZoneID) ?? .gmt
    }

    var legacyUnsplitName: String? {
        guard profile.familyName.isEmpty, profile.givenName.isEmpty, !profile.resolvedName.isEmpty else { return nil }
        return profile.resolvedName
    }

    mutating func setNamePart(_ field: OracleField, to value: String) {
        if field == .surname { profile.familyName = value }
        else { profile.givenName = value }
        clearLegacyName()
        let present = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        setAvailability(field, present: present, cleared: !present)
        if !profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setAvailability(.name, present: true)
        }
    }

    mutating func clearLegacyName() {
        profile.name = nil
        profile.displayName = ""
        setAvailability(.name, present: false, cleared: true)
    }

    mutating func setGender(_ value: String) {
        profile.sex = value
        setAvailability(.gender, present: value != "未提供", cleared: value == "未提供")
    }

    mutating func setBirthDate(_ value: Date?) {
        birthDateChoiceChanged = true
        birthDateKnown = value != nil
        guard let value else { return }
        let calendar = birthCalendar
        let clock = calendar.dateComponents([.hour, .minute, .second], from: birthDate)
        var parts = calendar.dateComponents([.year, .month, .day], from: value)
        parts.hour = clock.hour
        parts.minute = clock.minute
        parts.second = clock.second
        birthDate = calendar.date(from: parts) ?? value
        confirmDefaultBirthZoneIfNeeded()
    }

    mutating func setBirthTime(_ value: Date?) {
        birthTimeChoiceChanged = true
        profile.birthTimeKnown = value != nil
        guard let value else { return }
        let calendar = birthCalendar
        let time = calendar.dateComponents([.hour, .minute], from: value)
        var parts = calendar.dateComponents([.year, .month, .day], from: birthDate)
        parts.hour = time.hour
        parts.minute = time.minute
        parts.second = 0
        birthDate = calendar.date(from: parts) ?? value
        confirmDefaultBirthZoneIfNeeded()
    }

    mutating func setBirthDistrict(_ district: ChinaDistrict) {
        changeBirthZone(to: district.timeZone)
        profile.birthDistrictCode = district.id
        profile.birthPlace = district.fullName
        setAvailability(.birthPlace, present: true)
        setBirthCoordinates(latitude: district.latitude, longitude: district.longitude)
    }

    mutating func setCurrentDistrict(_ district: ChinaDistrict) {
        profile.currentDistrictCode = district.id
        profile.currentPlace = district.fullName
        profile.currentLatitude = district.latitude
        profile.currentLongitude = district.longitude
        profile.currentTimeZoneID = district.timeZone
        setAvailability(.currentLocation, present: true)
    }

    mutating func setBirthGPS(_ place: LocalPlace) {
        var located = profile
        guard place.apply(to: &located, purpose: .birth) else { return }
        changeBirthZone(to: located.birthTimeZoneID)
        located.birthDistrictCode = nil
        profile = located
    }

    mutating func setBirthCoordinates(latitude: Double?, longitude: Double?) {
        profile.birthLatitude = latitude
        profile.birthLongitude = longitude
        let complete = latitude != nil && longitude != nil
        setAvailability(.birthCoordinates, present: complete, cleared: !complete)
    }

    mutating func clearBirthDistrict() {
        changeBirthZone(to: OracleProfile.defaultChinaTimeZoneID)
        profile.birthDistrictCode = nil
        profile.birthPlace = ""
        profile.birthLatitude = nil
        profile.birthLongitude = nil
        setAvailability(.birthPlace, present: false, cleared: true)
        setAvailability(.birthCoordinates, present: false, cleared: true)
    }

    mutating func clearCurrentLocation() {
        profile.currentDistrictCode = nil
        profile.currentPlace = ""
        profile.currentLatitude = nil
        profile.currentLongitude = nil
        profile.currentTimeZoneID = OracleProfile.defaultChinaTimeZoneID
        setAvailability(.currentLocation, present: false, cleared: true)
    }

    private var birthCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = birthZone
        return calendar
    }

    private mutating func confirmDefaultBirthZoneIfNeeded() {
        if profile.unknownFields.contains(.birthTimeZone) || TimeZone(identifier: profile.birthTimeZoneID) == nil {
            changeBirthZone(to: OracleProfile.defaultChinaTimeZoneID)
        }
    }

    private mutating func changeBirthZone(to identifier: String) {
        guard let zone = TimeZone(identifier: identifier) else { return }
        if identifier != profile.birthTimeZoneID {
            let parts = birthCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: birthDate)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            if let converted = calendar.date(from: parts) { birthDate = converted }
        }
        profile.birthTimeZoneID = identifier
        lastValidBirthZoneID = identifier
        birthZoneEdited = true
        setAvailability(.birthTimeZone, present: true)
    }

    private mutating func setAvailability(_ field: OracleField, present: Bool, cleared: Bool = false) {
        var declared = profile.declaredUnknownFields ?? []
        if present {
            profile.unknownFields.remove(field)
            declared.remove(field)
        } else {
            profile.unknownFields.insert(field)
            if cleared { declared.insert(field) }
        }
        profile.declaredUnknownFields = declared
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

    var draftProfile: OracleProfile {
        var value = profile
        normalizeClock(in: &value)
        var declared = value.declaredUnknownFields ?? []
        if birthDateChoiceChanged {
            if birthDateKnown { declared.remove(.birthDate) } else { declared.insert(.birthDate) }
        }
        if birthTimeChoiceChanged {
            if value.birthTimeKnown { declared.remove(.birthTime) } else { declared.insert(.birthTime) }
        }
        value.declaredUnknownFields = declared.intersection(value.unknownFields)
        return value
    }

    private func normalizeClock(in profile: inout OracleProfile) {
        // A name-only edit must not round seconds or reconstruct an ambiguous
        // DST instant. Normalize the birth clock only after an explicit edit.
        if birthDateChoiceChanged || birthTimeChoiceChanged || birthClockEdited || birthZoneEdited {
          if birthDateKnown {
            let zone = TimeZone(identifier: profile.birthTimeZoneID)
                ?? TimeZone(identifier: lastValidBirthZoneID) ?? TimeZone(secondsFromGMT: 0)!
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: birthDate)
            if !profile.birthTimeKnown { components.hour = 12; components.minute = 0; components.second = 0 }
            let instant = calendar.date(from: components) ?? birthDate
            profile.birthDate = instant; profile.unknownFields.remove(.birthDate)
            profile.birthDateText = String(format: "%04d-%02d-%02d", components.year ?? 1995, components.month ?? 1, components.day ?? 1)
          } else {
            profile.birthDate = nil
            if birthDateChoiceChanged { profile.birthDateText = nil }
            profile.unknownFields.insert(.birthDate)
          }
          if profile.birthTimeKnown {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: profile.birthTimeZoneID)
                ?? TimeZone(identifier: lastValidBirthZoneID) ?? TimeZone(secondsFromGMT: 0)!
            let clock = calendar.dateComponents([.hour, .minute, .second], from: birthDate)
            let minuteText = String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0)
            profile.birthTimeText = (clock.second ?? 0) == 0 ? minuteText : minuteText + String(format: ":%02d", clock.second ?? 0)
            profile.unknownFields.remove(.birthTime)
          } else {
            if birthTimeChoiceChanged { profile.birthTimeText = nil }
            profile.unknownFields.insert(.birthTime)
          }
        }
    }

    func validatedProfile() throws -> OracleProfile {
        var profile = self.profile
        profile.familyName = profile.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.givenName = profile.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = profile.alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        profile.alias = alias.isEmpty ? nil : alias
        let name = profile.resolvedName
        profile.name = name.isEmpty ? nil : name
        profile.displayName = name
        for (field, value) in [(OracleField.surname, profile.familyName), (.givenName, profile.givenName)] {
            if value.isEmpty { profile.unknownFields.insert(field) }
            else { profile.unknownFields.remove(field) }
        }
        if (birthDateChoiceChanged || birthTimeChoiceChanged || birthClockEdited || birthZoneEdited),
           birthDateKnown, TimeZone(identifier: profile.birthTimeZoneID) == nil {
            throw ProfileFormError(message: L10n.text("出生资料暂无法保存，请重新选择出生地。", "Couldn’t save the birth details. Choose the birthplace again."))
        }
        normalizeClock(in: &profile)
        if profile.sex == "未提供" { profile.unknownFields.insert(.gender) } else { profile.unknownFields.remove(.gender) }
        let currentLocationError = ProfileFormError(message: L10n.text("当前所在地资料有误，请重新定位或清空。", "The current location is invalid. Locate it again or clear it."))
        guard TimeZone(identifier: profile.currentTimeZoneID) != nil else { throw currentLocationError }
        if let latitude = profile.currentLatitude, !(-90...90).contains(latitude) { throw currentLocationError }
        if let longitude = profile.currentLongitude, !(-180...180).contains(longitude) { throw currentLocationError }
        if profile.currentPlace.isEmpty && profile.currentLatitude == nil { profile.unknownFields.insert(.currentLocation) }
        if profile.birthPlace.isEmpty { profile.unknownFields.insert(.birthPlace) }
        if profile.declaredUnknownFields?.contains(.birthCoordinates) != true {
            if let latitude = profile.birthLatitude, !(-90...90).contains(latitude) {
                throw ProfileFormError(message: L10n.text("出生地坐标有误，请重新选择或清空出生地。", "The birthplace coordinates are invalid. Select a place again or clear it."))
            }
            if let longitude = profile.birthLongitude, !(-180...180).contains(longitude) {
                throw ProfileFormError(message: L10n.text("出生地坐标有误，请重新选择或清空出生地。", "The birthplace coordinates are invalid. Select a place again or clear it."))
            }
        }
        if profile.unknownFields.contains(.birthCoordinates) { profile.birthLatitude = nil; profile.birthLongitude = nil }
        if profile.birthLatitude == nil || profile.birthLongitude == nil { profile.unknownFields.insert(.birthCoordinates) }
        else if !(-90...90).contains(profile.birthLatitude!) || !(-180...180).contains(profile.birthLongitude!) {
            throw ProfileFormError(message: L10n.text("出生地坐标有误，请重新选择或清空出生地。", "The birthplace coordinates are invalid. Select a place again or clear it."))
        }
        else { profile.unknownFields.remove(.birthCoordinates) }
        profile.unknownFields.insert(.numbers)
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
        profile.updatedAt = Date()
        return profile
    }
    static let allowedBirthYears = 1900...2100

    static func allowedBirthDates(in timeZone: TimeZone) -> ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let firstDay = calendar.date(from: DateComponents(year: allowedBirthYears.lowerBound, month: 1, day: 1))!
        let nextYear = calendar.date(from: DateComponents(year: allowedBirthYears.upperBound + 1, month: 1, day: 1))!
        return firstDay...nextYear.addingTimeInterval(-1)
    }
}

struct IntakeView: View {
    let plan: OraclePlan
    let onConfirm: (OracleProfile, [Int], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProfileFormDraft
    @State private var keepProfile = true
    @State private var error: String?
    private var isEditing: Bool { plan.intent == "编辑基础资料" }

    init(plan: OraclePlan, profile: OracleProfile, onConfirm: @escaping (OracleProfile, [Int], Bool) -> Void) {
        self.plan = plan; self.onConfirm = onConfirm
        _draft = State(initialValue: ProfileFormDraft(profile: profile))
    }
    static var initialBirthDate: Date { ProfileFormDraft.initialBirthDate }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .center, spacing: 16) {
                            OracleMark(size: 52)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(L10n.text("写下已知，留白未知。", "Write down what you know.")).font(.system(size: 22, design: .serif)).foregroundStyle(InkTheme.ink)
                                Text(L10n.text("不必勉强记起每一件事。", "You can leave the rest blank.")).font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
                            }
                        }
                        if !isEditing {
                            PaperCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    SectionEyebrow(text: L10n.text("此次所问", "Your question"))
                                    Text(plan.question).font(.system(size: 18, design: .serif)).lineSpacing(7).foregroundStyle(InkTheme.ink)
                                }
                            }
                        }
                        ProfileFieldsView(draft: $draft)
                        if !isEditing {
                            Toggle(L10n.text("把这份基础资料留在本机", "Save this profile on this device"), isOn: $keepProfile)
                                .font(.system(size: 13, design: .serif)).tint(InkTheme.sage)
                        }
                        if let error { Text(error).font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar) }
                        Button(action: confirm) {
                            HStack { Text(isEditing ? L10n.text("保存基础资料", "Save profile") : L10n.text("确认资料，开始推演", "Confirm and begin")); Image(systemName: "arrow.right") }
                        }.buttonStyle(InkPrimaryButton()).accessibilityIdentifier("confirmIntake")
                        Text(isEditing ? L10n.text("基础档案独立保存在本机。", "Your profile is stored on this device.") : L10n.text("问题、所需资料与推演摘要会用于 AI 解读；基础档案保存在本机。", "AI interpretation uses the question, required details, and a reading summary. Your profile stays on this device."))
                            .font(.system(size: 10)).foregroundStyle(InkTheme.secondary).lineSpacing(4).frame(maxWidth: .infinity, alignment: .center)
                    }.frame(maxWidth: 620).padding(24).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("profileEditorScroll")
            }
            .navigationTitle(isEditing ? L10n.text("基础资料", "Profile") : L10n.text("问事笺", "Reading details")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("稍后填写", "Finish later")) { dismiss() }.font(.system(size: 13)).foregroundStyle(InkTheme.secondary) } }
            .toolbarBackground(InkTheme.paper, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        }.presentationDragIndicator(.visible)
    }

    private func confirm() {
        do {
            let profile = try draft.validatedProfile()
            error = nil; onConfirm(profile, [], keepProfile)
        } catch { self.error = error.localizedDescription }
    }
}

private enum BirthDateCalendar: String {
    case gregorian = "公历"
    case lunar = "农历"

    var selectionPrompt: String {
        switch self {
        case .gregorian: L10n.text("选公历日期", "Choose a Gregorian date")
        case .lunar: L10n.text("选农历日期", "Choose a lunar date")
        }
    }
}

struct ProfileFieldsView: View {
    @Binding var draft: ProfileFormDraft
    @EnvironmentObject private var store: OracleStore
    @StateObject private var currentLocation = LocationService()
    @StateObject private var birthLocation = LocationService()
    @State private var picker: ProfilePicker?
    @State private var birthDateCalendar: BirthDateCalendar = .gregorian
    @State private var birthResolution = LocationResolution()
    @State private var currentResolution = LocationResolution()

    private struct LocationResolution {
        var waitingForGPS = false
        var lookup: Task<Void, Never>?
        var lookupID: UUID?
        var message: String?
    }

    private enum ProfilePicker: String, Identifiable {
        case date, time, birthDistrict, currentDistrict
        var id: String { rawValue }
    }

    private var surname: Binding<String> {
        Binding(get: { draft.profile.familyName }, set: { draft.setNamePart(.surname, to: $0) })
    }

    private var givenName: Binding<String> {
        Binding(get: { draft.profile.givenName }, set: { draft.setNamePart(.givenName, to: $0) })
    }

    private var alias: Binding<String> {
        Binding(get: { draft.profile.alias ?? "" }, set: { draft.profile.alias = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaperCard {
                VStack(alignment: .leading, spacing: 0) {
                    SectionEyebrow(text: L10n.text("姓名与代称", "Name and nickname")).padding(.bottom, 8)
                    textRow(L10n.text("姓", "Family name"), text: surname, contentType: .familyName, id: "profileSurname")
                    Divider()
                    textRow(L10n.text("名", "Given name"), text: givenName, contentType: .givenName, id: "profileGivenName")
                    if let legacyName = draft.legacyUnsplitName {
                        Divider()
                        HStack {
                            LabeledContent(L10n.text("旧档案姓名", "Previous profile name"), value: legacyName)
                                .accessibilityIdentifier("legacyProfileName")
                            clearButton(L10n.text("旧档案姓名", "Previous profile name"), id: "clearLegacyProfileName") { draft.clearLegacyName() }
                        }.frame(minHeight: 44)
                    }
                    Divider()
                    textRow(L10n.text("代称", "Nickname"), text: alias, contentType: .nickname, id: "profileAlias",
                            placeholder: draft.profile.anonymousCode)
                }
            }
            PaperCard {
                VStack(alignment: .leading, spacing: 0) {
                    SectionEyebrow(text: L10n.text("出生与所在地", "Birth and location")).padding(.bottom, 8)
                    genderRow
                    Divider()
                    birthDateRow
                    Divider()
                    pickerRow(L10n.text("出生时刻", "Birth time"), value: draft.profile.birthTimeKnown ? clockText(isDate: false) : nil,
                              placeholder: L10n.text("选钟表时间", "Choose a time"), id: "profileBirthTime", clearID: "clearProfileBirthTime",
                              action: { picker = .time }, clear: { draft.setBirthTime(nil) })
                    Divider()
                    locationRow(L10n.text("出生地", "Birthplace"), value: displayPlace(code: draft.profile.birthDistrictCode, name: draft.profile.birthPlace) ?? (draft.profile.birthLatitude != nil || draft.profile.birthLongitude != nil ? L10n.text("已记录地点", "Location saved") : nil),
                                id: "profileBirthPlace", gpsID: "useCurrentLocationForBirthPlace", clearID: "clearProfileBirthPlace",
                                purpose: .birth, selection: .birthDistrict)
                    Divider()
                    locationRow(L10n.text("当前所在地", "Current location"), value: displayPlace(code: draft.profile.currentDistrictCode, name: draft.profile.currentPlace) ?? (draft.profile.currentLatitude != nil || draft.profile.currentLongitude != nil ? L10n.text("已定位", "Located") : nil),
                                id: "profileCurrentPlace", gpsID: "useCurrentLocation", clearID: "clearProfileCurrentPlace",
                                purpose: .current, selection: .currentDistrict)
                }
            }
        }
        .font(.system(size: 14, design: .serif))
        .foregroundStyle(InkTheme.ink)
        .sheet(item: $picker) { picker in
            switch picker {
            case .birthDistrict:
                ChinaDistrictPicker(title: L10n.text("选择出生地", "Choose a birthplace")) { selectDistrict($0, purpose: .birth) }
            case .currentDistrict:
                ChinaDistrictPicker(title: L10n.text("选择当前所在地", "Choose current location")) { selectDistrict($0, purpose: .current) }
            case .date, .time:
                BirthClockPicker(isDate: picker == .date, calendar: birthDateCalendar,
                                 value: draft.birthDate, timeZone: draft.birthZone) { value in
                    if picker == .date { draft.setBirthDate(value) }
                    else { draft.setBirthTime(value) }
                }
            }
        }
        .onReceive(currentLocation.$place) { receiveGPS($0, purpose: .current) }
        .onReceive(birthLocation.$place) { receiveGPS($0, purpose: .birth) }
        .onReceive(currentLocation.$message) { receiveGPSError($0, purpose: .current) }
        .onReceive(birthLocation.$message) { receiveGPSError($0, purpose: .birth) }
        .onDisappear {
            cancelLocation(.birth)
            cancelLocation(.current)
        }
    }

    private func textRow(_ title: String, text: Binding<String>, contentType: UITextContentType, id: String,
                         placeholder: String = L10n.text("可留空", "Optional")) -> some View {
        HStack(spacing: 10) {
            Text(title).accessibilityHidden(true)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textContentType(contentType)
                .autocorrectionDisabled()
                .accessibilityLabel(title)
                .accessibilityIdentifier(id)
            if !text.wrappedValue.isEmpty {
                clearButton(title, id: "clear-" + id) { text.wrappedValue = "" }
            }
        }.frame(minHeight: 44)
    }

    private var genderRow: some View {
        let gender = switch draft.profile.sex {
        case "男": L10n.text("男", "Male")
        case "女": L10n.text("女", "Female")
        default: L10n.text("未填写", "Not entered")
        }
        return HStack(spacing: 10) {
            Text(L10n.text("排盘性别", "Sex for chart calculation"))
            Spacer()
            Menu {
                Button(L10n.text("男", "Male")) { draft.setGender("男") }
                Button(L10n.text("女", "Female")) { draft.setGender("女") }
            } label: {
                Label(draft.profile.sex == "未提供" ? L10n.text("可留空", "Optional") : gender, systemImage: "chevron.up.chevron.down")
                    .labelStyle(.titleOnly)
                    .foregroundStyle(InkTheme.secondary)
            }
            .accessibilityLabel(L10n.text("排盘性别", "Sex for chart calculation"))
            .accessibilityValue(gender)
            .accessibilityIdentifier("profileGender")
            if draft.profile.sex != "未提供" {
                clearButton(L10n.text("排盘性别", "Sex for chart calculation"), id: "clearProfileGender") { draft.setGender("未提供") }
            }
        }.frame(minHeight: 44)
    }

    private var birthDateRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                birthDateControls
                Spacer(minLength: 0)
                birthDateValue
            }
            VStack(alignment: .leading, spacing: 0) {
                birthDateControls
                HStack {
                    Spacer(minLength: 0)
                    birthDateValue
                }
            }
        }
    }

    private var birthDateControls: some View {
        HStack(spacing: 8) {
            Button(L10n.text("出生日期", "Birth date")) { picker = .date }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .fixedSize()
                .accessibilityHidden(true)
            Picker(L10n.text("出生日期历法", "Birth date calendar"), selection: $birthDateCalendar) {
                Text(L10n.text("公历", "Gregorian")).tag(BirthDateCalendar.gregorian)
                Text(L10n.text("农历", "Lunar")).tag(BirthDateCalendar.lunar)
            }
            .pickerStyle(.segmented)
            .frame(width: AppLanguage.current.isEnglish ? 150 : 92)
            .accessibilityIdentifier("profileBirthCalendar")
        }
    }

    private var birthDateValue: some View {
        let value: String? = if !draft.birthDateKnown { nil }
        else if birthDateCalendar == .lunar {
            BirthLunarDate(date: draft.birthDate, timeZone: draft.birthZone)?.label ?? L10n.text("超出农历换算范围", "Outside the supported lunar calendar range")
        } else { clockText(isDate: true) }
        return HStack(spacing: 0) {
            Button { picker = .date } label: {
                pickerValue(value, placeholder: birthDateCalendar.selectionPrompt)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("出生日期", "Birth date"))
            .accessibilityValue(value ?? L10n.text("未填写", "Not entered"))
            .accessibilityIdentifier("profileBirthDate")
            if value != nil { clearButton(L10n.text("出生日期", "Birth date"), id: "clearProfileBirthDate") { draft.setBirthDate(nil) } }
        }
    }

    private func pickerRow(_ title: String, value: String?, placeholder: String, id: String, clearID: String,
                           action: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Text(title).foregroundStyle(InkTheme.ink)
                    Spacer(minLength: 6)
                    pickerValue(value, placeholder: placeholder)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(value ?? L10n.text("未填写", "Not entered"))
            .accessibilityIdentifier(id)
            if value != nil { clearButton(title, id: clearID, action: clear) }
        }
    }

    private func locationRow(_ title: String, value: String?, id: String, gpsID: String, clearID: String,
                             purpose: LocationPurpose, selection: ProfilePicker) -> some View {
        let state = resolution(for: purpose).wrappedValue
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
                Button { requestGPS(purpose) } label: {
                    Group {
                        if state.waitingForGPS { ProgressView().controlSize(.small) }
                        else { Image(systemName: "location").foregroundStyle(InkTheme.cinnabar) }
                    }
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.waitingForGPS)
                .accessibilityLabel(L10n.text("用当前位置填写", "Use current location for ") + title)
                .accessibilityIdentifier(gpsID)
                Button { picker = selection } label: {
                    pickerValue(value, placeholder: L10n.text("省/市/区", "Province, city, or district"))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(value ?? L10n.text("未填写", "Not entered"))
                .accessibilityIdentifier(id)
                if value != nil { clearButton(title, id: clearID) { clearLocation(purpose) } }
            }
            if state.lookupID != nil {
                Label(L10n.text("正在补充地区坐标", "Looking up coordinates"), systemImage: "mappin")
                    .font(.system(size: 11)).foregroundStyle(InkTheme.secondary).padding(.bottom, 8)
            } else if let message = state.message {
                Text(message).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    .padding(.bottom, 8).accessibilityIdentifier(id + "Message")
            }
        }
    }

    private func pickerValue(_ value: String?, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(value ?? placeholder)
                .foregroundStyle(InkTheme.secondary)
                .multilineTextAlignment(.trailing)
            if value == nil {
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(InkTheme.cinnabar)
            }
        }
    }

    private func clearButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(InkTheme.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("清空", "Clear ") + title)
        .accessibilityIdentifier(id)
    }

    private func clockText(isDate: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.timeZone = draft.birthZone
        if AppLanguage.current.isEnglish {
            if isDate { formatter.dateStyle = .medium }
            else { formatter.timeStyle = .short }
        } else {
            formatter.dateFormat = isDate ? "yyyy-MM-dd" : "HH:mm"
        }
        return formatter.string(from: draft.birthDate)
    }

    private func displayPlace(code: String?, name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return ChinaDistrictCatalog.shared.displayName(for: code, canonical: name)
    }

    private func selectDistrict(_ district: ChinaDistrict, purpose: LocationPurpose) {
        cancelLocation(purpose)
        switch purpose {
        case .birth: draft.setBirthDistrict(district)
        case .current: draft.setCurrentDistrict(district)
        }
        guard district.localPlace == nil else { return }
        let lookupID = UUID()
        let client = store.hasCredential && !store.localOnly ? store.client : nil
        let state = resolution(for: purpose)
        state.wrappedValue.lookupID = lookupID
        state.wrappedValue.lookup = Task { @MainActor in
            do {
                let place = try await LocationService.resolveChinaDistrict(district, using: client)
                guard !Task.isCancelled, state.wrappedValue.lookupID == lookupID else { return }
                switch purpose {
                case .birth: draft.setBirthCoordinates(latitude: place.latitude, longitude: place.longitude)
                case .current:
                    draft.profile.currentLatitude = place.latitude
                    draft.profile.currentLongitude = place.longitude
                }
            } catch {
                guard !Task.isCancelled, state.wrappedValue.lookupID == lookupID else { return }
                state.wrappedValue.message = L10n.text("地区已选定，坐标暂未取得。", "Place selected. Coordinates are currently unavailable.")
            }
            state.wrappedValue.lookupID = nil
            state.wrappedValue.lookup = nil
        }
    }

    private func requestGPS(_ purpose: LocationPurpose) {
        cancelLocation(purpose)
        resolution(for: purpose).wrappedValue.waitingForGPS = true
        locationService(for: purpose).request()
    }

    private func receiveGPS(_ place: LocalPlace?, purpose: LocationPurpose) {
        let state = resolution(for: purpose)
        guard state.wrappedValue.waitingForGPS, let place else { return }
        state.wrappedValue.waitingForGPS = false
        switch purpose {
        case .birth: draft.setBirthGPS(place)
        case .current: place.apply(to: &draft.profile, purpose: .current)
        }
    }

    private func receiveGPSError(_ message: String?, purpose: LocationPurpose) {
        let state = resolution(for: purpose)
        guard state.wrappedValue.waitingForGPS, let message else { return }
        state.wrappedValue.waitingForGPS = false
        state.wrappedValue.message = message
    }

    private func clearLocation(_ purpose: LocationPurpose) {
        cancelLocation(purpose)
        switch purpose {
        case .birth: draft.clearBirthDistrict()
        case .current: draft.clearCurrentLocation()
        }
    }

    private func cancelLocation(_ purpose: LocationPurpose) {
        let state = resolution(for: purpose)
        state.wrappedValue.lookup?.cancel()
        state.wrappedValue = LocationResolution()
        locationService(for: purpose).cancel()
    }

    private func resolution(for purpose: LocationPurpose) -> Binding<LocationResolution> {
        switch purpose {
        case .birth: $birthResolution
        case .current: $currentResolution
        }
    }

    private func locationService(for purpose: LocationPurpose) -> LocationService {
        switch purpose {
        case .birth: birthLocation
        case .current: currentLocation
        }
    }
}

private struct BirthClockPicker: View {
    let isDate: Bool
    let timeZone: TimeZone
    let onSelect: (Date) -> Void
    private let allowed: ClosedRange<Date>
    @Environment(\.dismiss) private var dismiss
    @State private var value: Date
    @State private var lunarDate: BirthLunarDate?

    init(isDate: Bool, calendar: BirthDateCalendar, value: Date, timeZone: TimeZone, onSelect: @escaping (Date) -> Void) {
        self.isDate = isDate
        self.timeZone = timeZone
        self.onSelect = onSelect
        allowed = ProfileFormDraft.allowedBirthDates(in: timeZone)
        let initialValue = isDate ? min(max(value, allowed.lowerBound), allowed.upperBound) : value
        _value = State(initialValue: initialValue)
        _lunarDate = State(initialValue: isDate && calendar == .lunar ? BirthLunarDate(date: initialValue, timeZone: timeZone) : nil)
    }

    var body: some View {
        let selected = lunarDate == nil ? value : lunarDate?.solarDate(in: timeZone)
        NavigationStack {
            VStack {
                if let selection = Binding($lunarDate) {
                    BirthLunarWheel(selection: selection)
                } else if isDate {
                    DatePicker(L10n.text("公历日期", "Gregorian date"), selection: $value, in: allowed, displayedComponents: .date)
                } else {
                    DatePicker(L10n.text("钟表时间", "Local time"), selection: $value, displayedComponents: .hourAndMinute)
                }
                if selected == nil {
                    Text(L10n.text("所选日期在出生地时区中不存在。", "That date does not exist in the birthplace’s time zone."))
                        .font(.footnote)
                        .foregroundStyle(InkTheme.cinnabar)
                }
            }
            .labelsHidden()
            .datePickerStyle(.wheel)
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.timeZone, timeZone)
            .accessibilityIdentifier("birthClockPicker")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(InkTheme.paper)
            .navigationTitle(isDate ? L10n.text("选择出生日期", "Choose a birth date") : L10n.text("选择出生时刻", "Choose a birth time"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("确定", "Confirm")) {
                        guard let selected else { return }
                        onSelect(selected)
                        dismiss()
                    }
                    .disabled(selected == nil)
                    .accessibilityIdentifier("confirmBirthClock")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(InkTheme.cinnabar)
    }
}

struct BirthLunarDate {
    private(set) var year: Int
    private(set) var month: Int
    var day: Int

    private static let firstSolar = Solar(year: ProfileFormDraft.allowedBirthYears.lowerBound, month: 1, day: 1, hour: 12)
    private static let lastSolar = Solar(year: ProfileFormDraft.allowedBirthYears.upperBound, month: 12, day: 31, hour: 12)
    static let years = firstSolar.lunar.year...lastSolar.lunar.year

    init?(date: Date, timeZone: TimeZone) {
        guard let solar = NativeCalendar.solar(date, timeZoneID: timeZone.identifier) else { return nil }
        let lunar = solar.lunar
        year = lunar.year; month = lunar.month; day = lunar.day
    }

    var label: String {
        L10n.text("\(year)年\(Self.monthLabel(month))\(LunarUtil.DAY[day])", "Lunar \(year) · \(Self.monthLabel(month)) · Day \(day)")
    }

    var months: [LunarMonth] {
        LunarYear.fromYear(lunarYear: year).monthsInYear.filter { Self.days(in: $0) != nil }
    }

    static func monthLabel(_ month: Int) -> String {
        L10n.text(
            (month < 0 ? "闰" : "") + LunarUtil.MONTH[abs(month)] + "月",
            "\(month < 0 ? "Leap month" : "Month") \(abs(month))"
        )
    }

    static func days(in month: LunarMonth) -> ClosedRange<Int>? {
        let first = max(1, Int(ceil(firstSolar.julianDay - month.firstJulianDay)) + 1)
        let last = min(month.dayCount, Int(floor(lastSolar.julianDay - month.firstJulianDay)) + 1)
        return first <= last ? first...last : nil
    }

    mutating func selectYear(_ year: Int) {
        self.year = year
        let months = self.months
        if let newMonth = months.first(where: { $0.month == month })
            ?? months.first(where: { $0.month == abs(month) })
            ?? months.first {
            selectMonth(newMonth)
        }
    }

    mutating func selectMonth(_ month: LunarMonth) {
        guard let days = Self.days(in: month) else { return }
        self.month = month.month
        day = min(max(day, days.lowerBound), days.upperBound)
    }

    func solarDate(in timeZone: TimeZone) -> Date? {
        guard let month = months.first(where: { $0.month == self.month }),
              Self.days(in: month)?.contains(day) == true else { return nil }
        let solar = Solar.fromJulianDay(julianDay: month.firstJulianDay + Double(day - 1))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let civilDate = DateComponents(year: solar.year, month: solar.month, day: solar.day)
        var noon = civilDate
        noon.hour = 12
        guard let date = calendar.date(from: noon),
              calendar.dateComponents([.year, .month, .day], from: date) == civilDate else { return nil }
        return date
    }
}

private struct BirthLunarWheel: View {
    @Binding var selection: BirthLunarDate

    var body: some View {
        let months = selection.months
        HStack(spacing: 0) {
            Picker(L10n.text("农历年", "Lunar year"), selection: Binding(get: { selection.year }, set: { selection.selectYear($0) })) {
                ForEach(BirthLunarDate.years, id: \.self) { year in
                    Text(L10n.text("\(year)年", String(year))).tag(year)
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()
            Picker(L10n.text("农历月", "Lunar month"), selection: Binding(get: { selection.month }, set: { month in
                if let selected = months.first(where: { $0.month == month }) { selection.selectMonth(selected) }
            })) {
                ForEach(months, id: \.month) { Text(BirthLunarDate.monthLabel($0.month)).tag($0.month) }
            }
            .frame(maxWidth: .infinity)
            .clipped()
            if let month = months.first(where: { $0.month == selection.month }),
               let days = BirthLunarDate.days(in: month) {
                Picker(L10n.text("农历日", "Lunar day"), selection: $selection.day) {
                    ForEach(days, id: \.self) { Text(L10n.text(LunarUtil.DAY[$0], String($0))).tag($0) }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}

struct ProfileEditor: View {
    let profile: OracleProfile
    let onSave: (OracleProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        IntakeView(plan: OraclePlan(intent: "编辑基础资料", subject: "事件", methods: [], requiredFields: [], note: "", question: "保存档案，往后直接选取。"), profile: profile) { updated, _, _ in
            onSave(updated); dismiss()
        }.id(profile.id)
    }
}
