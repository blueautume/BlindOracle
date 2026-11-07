import SwiftUI

/// A purchase is reviewed here before the user opens Apple's payment sheet.
struct AccountTopUpView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var purchases: AccountPurchaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProductID: String?

    private var selectedProduct: AccountPurchaseProduct? {
        purchases.products.first { $0.id == selectedProductID } ?? purchases.products.first
    }
    private var purchaseInProgress: Bool { purchases.isPurchasing || purchases.isCheckingPurchases }
    private var canPurchase: Bool {
        selectedProduct?.allowanceTokens != nil && !purchases.isLoading
            && !purchaseInProgress && !purchases.hasUnresolvedPurchase
    }

    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 18) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(InkTheme.cinnabar)
                            .frame(width: 86, height: 86)
                            .background(InkTheme.cinnabar.opacity(0.06), in: Circle())
                            .accessibilityHidden(true)
                        Text(L10n.text("补充额度", "Replenish allowance"))
                            .font(.system(size: 29, weight: .medium, design: .serif))
                            .foregroundStyle(InkTheme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.text("为接下来的问事，留一点余量。", "A little more room for your next question."))
                            .font(.system(size: 14, design: .serif))
                            .foregroundStyle(InkTheme.secondary)
                            .multilineTextAlignment(.center)
                    }.padding(.top, 14)

                    if let product = selectedProduct {
                        offerDetails(product)
                    } else {
                        PaperCard {
                            HStack(spacing: 12) {
                                if purchases.isLoading { ProgressView().tint(InkTheme.sage) }
                                Text(purchases.isLoading
                                     ? L10n.text("正在获取购买选项…", "Loading purchase options…")
                                     : L10n.text("暂时没有可用的购买选项。", "No purchase options are available right now."))
                                    .font(.subheadline).foregroundStyle(InkTheme.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 70)
                        }
                    }

                    VStack(spacing: 14) {
                        if ServiceEnvironment.current.isSandbox {
                            Text(L10n.text("测试环境 · 购买不扣款", "Test environment · No purchase charges"))
                                .font(.footnote).foregroundStyle(InkTheme.secondary)
                                .accessibilityIdentifier("sandboxPurchaseNotice")
                        }
                        if let message = purchases.message {
                            Text(message).font(.footnote).foregroundStyle(InkTheme.secondary)
                                .multilineTextAlignment(.center).lineSpacing(4)
                                .accessibilityIdentifier("purchaseMessage")
                        }
                        Button(L10n.text("核对购买", "Check purchases")) {
                            Task { await purchases.resumeUnfinished(userInitiated: true); await account.refreshOverview() }
                        }.disabled(purchaseInProgress).accessibilityIdentifier("checkPurchases")
                        if selectedProduct?.allowanceTokens == nil {
                            Button(L10n.text("重新加载购买选项", "Reload purchase options")) {
                                Task { await purchases.loadProducts() }
                            }.disabled(purchases.isLoading || purchaseInProgress)
                                .accessibilityIdentifier("reloadPurchaseOptions")
                        }
                    }.font(.system(size: 13)).foregroundStyle(InkTheme.secondary)
                }
                .padding(.horizontal, 26).padding(.bottom, 24)
                .frame(maxWidth: 520).frame(maxWidth: .infinity)
            }.scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("topUpPurchasePage")
        }
        .navigationBarTitleDisplayMode(.inline).tint(InkTheme.cinnabar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(InkTheme.ink).frame(width: 34, height: 34)
                        .background(InkTheme.ink.opacity(0.045), in: Circle())
                }.accessibilityLabel(L10n.text("关闭", "Close")).accessibilityIdentifier("closeTopUp")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { purchaseFooter }
        .task { await purchases.loadProducts(); await purchases.resumeUnfinished() }
    }

    private func offerDetails(_ product: AccountPurchaseProduct) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 22) {
                if purchases.products.count > 1 {
                    Picker(L10n.text("选择补充包", "Choose a top-up"), selection: Binding(
                        get: { selectedProduct?.id ?? "" }, set: { selectedProductID = $0 })) {
                        ForEach(purchases.products) { offer in
                            Text(offer.displayPrice).tag(offer.id)
                        }
                    }.pickerStyle(.segmented).disabled(purchaseInProgress)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("额度补充包", "Allowance top-up"))
                            .font(.system(size: 13, design: .serif)).foregroundStyle(InkTheme.secondary)
                        if let tokens = product.allowanceTokens {
                            Text(tokens.formatted(.number.locale(AppLanguage.current.locale)) + " Token")
                                .font(.system(size: 25, weight: .medium, design: .serif))
                                .foregroundStyle(InkTheme.ink).minimumScaleFactor(0.65).lineLimit(1)
                                .accessibilityIdentifier("topUpTokenAmount")
                        } else {
                            Text(L10n.text("暂时无法读取补充数量，请重新加载。", "The top-up amount is unavailable. Please reload."))
                                .font(.subheadline).foregroundStyle(InkTheme.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(product.displayPrice).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(InkTheme.ink).accessibilityIdentifier("topUpPrice")
                }
                Divider().overlay(InkTheme.line.opacity(0.65))
                benefit(L10n.text("用于在线解读与后续追问", "For online readings and follow-up questions"))
                benefit(L10n.text("一次性购买，非自动续费", "One-time purchase, no automatic renewal"))
                benefit(L10n.text("核实购买后，额度自动加入当前账号", "Added to this account once the purchase is verified"))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func benefit(_ title: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .medium))
                .foregroundStyle(InkTheme.sage).padding(.top, 2).accessibilityHidden(true)
            Text(title).font(.system(size: 14)).foregroundStyle(InkTheme.ink).lineSpacing(4)
        }
    }

    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(purchases.isPurchasing ? L10n.text("正在确认购买…", "Confirming purchase…")
                     : L10n.text("正在核对购买…", "Checking purchases…"))
                    .font(.footnote).foregroundStyle(InkTheme.secondary)
            }.opacity(purchaseInProgress ? 1 : 0).accessibilityHidden(!purchaseInProgress)
                .frame(minHeight: 20)
            Button {
                guard let product = selectedProduct else { return }
                Task { await purchases.purchase(product) }
            } label: {
                Text(selectedProduct.map { L10n.text("购买 · \($0.displayPrice)", "Purchase · \($0.displayPrice)") }
                     ?? L10n.text("购买", "Purchase"))
            }.buttonStyle(InkPrimaryButton())
                .disabled(!canPurchase).opacity(canPurchase ? 1 : 0.45)
                .accessibilityIdentifier("purchaseAllowance")
            Text(L10n.text("付款金额以 Apple 确认页面为准。", "The Apple confirmation sheet shows the final charge."))
                .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 18)
        .frame(maxWidth: 520).frame(maxWidth: .infinity).background(InkTheme.paper)
    }
}
