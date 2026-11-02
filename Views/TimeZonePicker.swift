import SwiftUI

struct TimeZoneOption: Identifiable, Equatable {
    let id: String
    let city: String
    let region: String
    let offset: String
    var title: String { "\(city) · \(offset)" }

    func matches(_ query: String) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || [id, city, region, offset].contains { $0.localizedStandardContains(value) }
    }
}

enum TimeZoneCatalog {
    static let options: [TimeZoneOption] = {
        let locale = Locale(identifier: "zh_CN")
        let formatter = DateFormatter(); formatter.locale = locale; formatter.dateFormat = "VVV"
        let date = Date()
        return Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"]).compactMap { identifier -> TimeZoneOption? in
            guard let zone = TimeZone(identifier: identifier) else { return nil }
            formatter.timeZone = zone
            let city = identifier == "UTC" ? "协调世界时" : formatter.string(from: date)
            let seconds = zone.secondsFromGMT(for: date)
            let sign = seconds >= 0 ? "+" : "−"
            let offset = String(format: "UTC%@%02d:%02d", sign, abs(seconds) / 3600, abs(seconds) % 3600 / 60)
            return TimeZoneOption(id: identifier, city: city,
                                  region: zone.localizedName(for: .generic, locale: locale) ?? "", offset: offset)
        }.sorted { $0.city.localizedStandardCompare($1.city) == .orderedAscending }
    }()
    static let commonIDs = ["Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo", "Asia/Singapore", "Europe/London", "America/New_York", "America/Los_Angeles", "Australia/Sydney", "UTC"]

    static func label(for identifier: String) -> String {
        options.first { $0.id == identifier }?.title ?? "请选择时区"
    }
    static func matching(_ query: String) -> [TimeZoneOption] { options.filter { $0.matches(query) } }
}

/// A selected timezone is always a system-supported IANA identifier. Users can
/// search Chinese city names without having to type or remember that identifier.
struct TimeZoneSelectionField: View {
    let title: String
    @Binding var selection: String
    let accessibilityID: String
    var isUnknown = false
    var onSelection: (() -> Void)? = nil
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    Text(isUnknown ? "尚未确认，点击选择" : TimeZoneCatalog.label(for: selection))
                        .font(.system(size: 13, design: .serif)).foregroundStyle(InkTheme.ink)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(accessibilityID).accessibilityValue(selection)
            .sheet(isPresented: $isPresented) {
                TimeZonePicker(selection: $selection) { onSelection?() }
            }
    }
}

struct TimeZonePicker: View {
    @Binding var selection: String
    var onSelection: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var common: [TimeZoneOption] {
        TimeZoneCatalog.commonIDs.compactMap { id in TimeZoneCatalog.options.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("常用时区") { ForEach(common) { option in row(option) } }
                    Section("全部时区") {
                        ForEach(TimeZoneCatalog.options.filter { !TimeZoneCatalog.commonIDs.contains($0.id) }) { option in row(option) }
                    }
                } else {
                    ForEach(TimeZoneCatalog.matching(query)) { option in row(option) }
                }
            }.scrollContentBackground(.hidden).background(InkTheme.paper)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索城市、地区或时区")
                .navigationTitle("选择时区").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("取消") { dismiss() }.accessibilityIdentifier("cancelTimeZonePicker")
                    }
                }
                .overlay {
                    if !query.isEmpty && TimeZoneCatalog.matching(query).isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private func row(_ option: TimeZoneOption) -> some View {
        Button {
            selection = option.id; onSelection?(); dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(option.city).font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                    Text("\(option.id) · \(option.offset)").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                }
                Spacer()
                if option.id == selection { Image(systemName: "checkmark").foregroundStyle(InkTheme.cinnabar) }
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("timeZone-\(option.id)")
    }
}
