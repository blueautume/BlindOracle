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
                Text(L10n.text("暂时无法读取地区列表。", "The list of regions couldn’t be loaded."))
                    .foregroundStyle(InkTheme.secondary)
            }
            ForEach(districts) { district in
                if catalog.children(of: district).isEmpty {
                    Button(district.displayName) { select(district) }
                        .foregroundStyle(InkTheme.ink)
                        .accessibilityIdentifier("chinaDistrict-\(district.id)")
                } else {
                    NavigationLink(value: district) { Text(district.displayName) }
                        .accessibilityIdentifier("chinaDistrict-\(district.id)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(InkTheme.paper)
        .navigationTitle(parent?.displayName ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text("取消", "Cancel")) { dismiss() }.accessibilityIdentifier("cancelChinaDistrictPicker")
            }
        }
        .accessibilityIdentifier("chinaDistrictPicker")
    }

    private func select(_ district: ChinaDistrict) {
        onSelect(district)
        dismiss()
    }
}
