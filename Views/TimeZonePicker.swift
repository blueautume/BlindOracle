import SwiftUI

struct ChinaDistrictPicker: View {
    let title: String
    let onSelect: (ChinaDistrict) -> Void
    @Environment(\.dismiss) private var dismiss
    private let catalog = ChinaDistrictCatalog.shared

    var body: some View {
        NavigationStack {
            districtList(catalog.provinces, parent: nil)
                .navigationDestination(for: ChinaDistrict.self) { district in
                    districtList(catalog.children(of: district), parent: district)
                }
        }
        .tint(InkTheme.cinnabar)
    }

    private func districtList(_ districts: [ChinaDistrict], parent: ChinaDistrict?) -> some View {
        List {
            if let parent, let selectionTitle = parent.wholeAreaSelectionTitle {
                Button(selectionTitle) { select(parent) }
                    .foregroundStyle(InkTheme.ink)
                    .accessibilityIdentifier("chinaWholeCity-\(parent.id)")
            }
            if districts.isEmpty, parent == nil {
                Text("暂时无法读取地区列表。")
                    .foregroundStyle(InkTheme.secondary)
            }
            ForEach(districts) { district in
                if catalog.children(of: district).isEmpty {
                    Button(district.name) { select(district) }
                        .foregroundStyle(InkTheme.ink)
                        .accessibilityIdentifier("chinaDistrict-\(district.id)")
                } else {
                    NavigationLink(value: district) { Text(district.name) }
                        .accessibilityIdentifier("chinaDistrict-\(district.id)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(InkTheme.paper)
        .navigationTitle(parent?.name ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.accessibilityIdentifier("cancelChinaDistrictPicker")
            }
        }
        .accessibilityIdentifier("chinaDistrictPicker")
    }

    private func select(_ district: ChinaDistrict) {
        onSelect(district)
        dismiss()
    }
}
