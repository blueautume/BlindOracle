import SwiftUI

struct AccountAllowanceGauge: View {
    @EnvironmentObject private var account: AccountStore
    private var percent: Int? { account.wallet?.quota?.displayedPercent }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("剩余额度", "Remaining allowance"))
                    .font(.system(size: 13, design: .serif)).foregroundStyle(InkTheme.secondary)
                Spacer()
                Text(percent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 34, weight: .medium, design: .serif)).monospacedDigit()
                    .foregroundStyle(InkTheme.ink).accessibilityIdentifier("remainingQuotaPercentage")
            }
            ProgressView(value: Double(percent ?? 0), total: 100)
                .tint(InkTheme.cinnabar).accessibilityIdentifier("remainingQuotaProgress")
            if let quota = account.wallet?.quota, !quota.canStart {
                Text(quota.refundDebt > 0
                     ? L10n.text("有退款事项待处理，请核对购买或联系我们。", "A refund needs attention. Check your purchases or contact us.")
                     : L10n.text("请补充额度后继续。", "Replenish your allowance to continue."))
                    .font(.footnote).foregroundStyle(InkTheme.secondary)
            }
        }
    }
}

struct AccountTopUpView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var purchases: AccountPurchaseStore
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L10n.text("补充额度", "Replenish allowance"))
                        .font(.system(size: 32, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                    if ServiceEnvironment.current.isSandbox {
                        Text(L10n.text("测试环境 · 购买不扣款\n测试额度只在本测试环境使用。系统购买请使用沙盒测试账号。", "Test environment · No purchase charges\nTest allowance is separate. Use your Sandbox tester in the system purchase sheet."))
                            .font(.footnote).foregroundStyle(InkTheme.cinnabar).lineSpacing(4)
                            .accessibilityIdentifier("sandboxPurchaseNotice")
                    }
                    PaperCard { AccountAllowanceGauge() }
                    Text(L10n.text("补充后，可用额度会自动更新。付款金额以 Apple 确认页面为准。", "Your available allowance updates after delivery. The Apple confirmation sheet shows the final charge."))
                        .font(.footnote).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                    if purchases.isLoading { ProgressView().tint(InkTheme.cinnabar) }
                    ForEach(purchases.products, id: \.id) { product in
                        Button { Task { await purchases.purchase(product) } } label: {
                            HStack {
                                Text(L10n.text("补充额度", "Replenish allowance"))
                                Spacer()
                                Text(product.displayPrice).monospacedDigit()
                            }.font(.system(size: 18, design: .serif)).foregroundStyle(InkTheme.ink)
                                .padding(20).background(Color.white.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
                        }.disabled(purchases.isPurchasing || purchases.isCheckingPurchases || purchases.hasUnresolvedPurchase).accessibilityIdentifier("purchaseAllowance")
                    }
                    if purchases.isPurchasing { ProgressView(L10n.text("正在确认购买…", "Confirming purchase…")).tint(InkTheme.cinnabar) }
                    if purchases.isCheckingPurchases { ProgressView(L10n.text("正在核对购买…", "Checking purchases…")).tint(InkTheme.cinnabar) }
                    if let message = purchases.message {
                        Text(message).font(.footnote).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                            .accessibilityIdentifier("purchaseMessage")
                    }
                    Button(L10n.text("核对购买", "Check purchases")) {
                        Task { await purchases.resumeUnfinished(userInitiated: true); await account.refreshOverview() }
                    }.disabled(purchases.isPurchasing || purchases.isCheckingPurchases).accessibilityIdentifier("checkPurchases")
                    Button(L10n.text("刷新购买选项", "Refresh purchase options")) { Task { await purchases.loadProducts() } }
                        .disabled(purchases.isLoading || purchases.isPurchasing)
                }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.navigationBarTitleDisplayMode(.inline).tint(InkTheme.cinnabar)
        .task { await purchases.loadProducts(); await purchases.resumeUnfinished() }
    }
}
