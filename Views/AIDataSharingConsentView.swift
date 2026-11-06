import SwiftUI

struct AIDataSharingConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authorized = false
    @State private var isSaving = false
    private let consent: AIDataSharingConsentStore
    private let onContinue: () -> Void
    private let onDecline: () -> Void

    init(consent: AIDataSharingConsentStore = .shared,
         onContinue: @escaping () -> Void = {}, onDecline: @escaping () -> Void = {}) {
        self.consent = consent
        self.onContinue = onContinue
        self.onDecline = onDecline
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Image(systemName: "hand.raised").font(.system(size: 30, weight: .light)).foregroundStyle(InkTheme.cinnabar)
                        Text(L10n.text("使用 AI 前，请先了解", "Before you use AI"))
                            .font(.system(size: 27, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                        Text(L10n.text("为了理解你的问题并生成回答，相关内容会经开发者的 wellecho.cn 服务器发送给第三方 AI 服务 DeepSeek 处理。", "To understand your question and generate a reply, relevant content is sent through the developer’s wellecho.cn server to the third-party AI service DeepSeek."))
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("可能发送的内容", "What may be sent")).font(.headline).foregroundStyle(InkTheme.ink)
                            Text(L10n.text("• 你的问题及相关对话、对话摘要\n• 相关人员资料，例如姓名、性别、出生日期与时间；理解问题时也会发送已保存的人员目录（姓名及资料完整程度）\n• 出生地、当前问事地点及其经纬度、时区\n• 相关的本地推演结果", "• Your question, related conversation and summaries\n• Relevant profile details, such as names, sex, and birth date and time; the saved profile directory (names and which details are available) is also sent to understand your question\n• Birthplace, the current reading location, their coordinates and time zones\n• Relevant results calculated on this device"))
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(InkTheme.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 15))
                        Text(L10n.text("你可以暂不使用 AI，继续查看账号和本机资料。登录本身不会授予这项许可。", "You can decline and continue viewing your account and local records. Signing in does not grant this permission."))
                        Text(L10n.text("第三方可能按其适用条款留存内容，并使用去标识化数据优化服务或训练模型。详情见隐私政策。", "The third party may retain content under its applicable terms and use de-identified data to improve its services or train models. See the Privacy Policy for details."))
                        Text(L10n.text("你可随时在对话页右上角「AI 数据使用」撤回许可。撤回只阻止之后的发送，无法收回已经发送的数据，也不保证终止正在处理的请求。", "You can withdraw permission from “AI data use” at the top right of Chat. Withdrawal blocks future sending; it cannot recall data already sent or guarantee that a request in progress will stop."))
                            .font(.footnote).foregroundStyle(InkTheme.secondary)
                        NavigationLink { LegalDocumentView(document: .privacyPolicy) } label: {
                            Label(L10n.text("阅读隐私政策", "Read the Privacy Policy"), systemImage: "doc.text")
                        }.foregroundStyle(InkTheme.cinnabar).accessibilityIdentifier("aiDataSharingPrivacy")
                        if authorized {
                            Text(L10n.text("你已同意当前版本的数据使用说明。", "You have agreed to the current data-use notice."))
                                .font(.footnote).foregroundStyle(InkTheme.secondary).accessibilityIdentifier("aiDataSharingAuthorized")
                            Button(L10n.text("撤回许可", "Withdraw permission")) {
                                isSaving = true
                                Task { @MainActor in
                                    await consent.revoke()
                                    authorized = false
                                    isSaving = false
                                }
                            }.buttonStyle(InkPrimaryButton()).accessibilityIdentifier("revokeAIDataSharing")
                        } else {
                            Button(L10n.text("同意并继续", "Agree and continue")) {
                                isSaving = true
                                Task { @MainActor in
                                    await consent.grant()
                                    isSaving = false
                                    onContinue()
                                    dismiss()
                                }
                            }.buttonStyle(InkPrimaryButton()).accessibilityIdentifier("agreeAIDataSharing")
                            Button(L10n.text("暂不使用AI", "Not now")) {
                                onDecline()
                                dismiss()
                            }.frame(maxWidth: .infinity).foregroundStyle(InkTheme.secondary).accessibilityIdentifier("declineAIDataSharing")
                        }
                    }.font(.system(size: 15)).foregroundStyle(InkTheme.ink).lineSpacing(5)
                        .padding(26).frame(maxWidth: 600).frame(maxWidth: .infinity)
                }.accessibilityIdentifier("aiDataSharingScroll")
            }.navigationTitle(L10n.text("AI 数据使用", "AI data use")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("关闭", "Close")) { onDecline(); dismiss() }
                            .foregroundStyle(InkTheme.secondary)
                    }
                }
                .disabled(isSaving)
                .task { authorized = await consent.isAuthorized() }
                .accessibilityIdentifier("aiDataSharingConsent")
        }
    }
}
