import SwiftUI
import AuthenticationServices
import UIKit

struct AccountView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var store: OracleStore
    @StateObject private var apple = AppleAccountSignInCoordinator()
    @State private var confirmLogout = false
    @State private var confirmDeletion = false
    var body: some View {
        ZStack {
            PaperBackground()
            GeometryReader { geometry in
              ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PaperCard {
                        VStack(alignment: .leading, spacing: 14) {
                            if let user = account.user {
                                AccountIdentityHeader(user: user)

                            } else {
                                Text(L10n.text("用 Apple 登录", "Sign in with Apple")).font(.system(size: 20, design: .serif)).foregroundStyle(InkTheme.ink)
                                Text(L10n.text("登录后使用应用。本机资料仍会保留。", "Sign in to use the app. Local records remain on this device."))
                                    .font(.subheadline).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                                NativeAppleSignInButton { apple.start(account: account) }
                                    .frame(height: 48).disabled(account.isBusy || apple.isRunning)
                                    .accessibilityIdentifier("appleSignInButton")
                                HStack(spacing: 8) {
                                    NavigationLink(L10n.text("用户协议", "User Agreement")) { LegalDocumentView(document: .userAgreement) }
                                    Text("·")
                                    NavigationLink(L10n.text("隐私政策", "Privacy Policy")) { LegalDocumentView(document: .privacyPolicy) }
                                }.font(.caption).foregroundStyle(InkTheme.secondary)
                            }
                            if account.isBusy || apple.isRunning { ProgressView().tint(InkTheme.cinnabar) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let message = account.message {
                        Text(message).font(.subheadline).foregroundStyle(InkTheme.cinnabar).lineSpacing(4)
                            .accessibilityIdentifier("accountMessage")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                            Label(L10n.text("本机资料独立保存", "Local records stay on this device"), systemImage: "iphone")
                                .font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                            Text(L10n.text("人员资料、聊天与推演保存在当前设备，不随账号自动同步。退出或切换账号会保留本机记录；永久注销账号将清除本机记录。共享设备前，请先清理需要删除的资料。", "Profiles, chats and readings are stored on this device and are not automatically synced with your account. Signing out or switching accounts keeps local records; permanently deleting your account clears them. Remove relevant records before sharing this device."))
                                .font(.footnote).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                            Text(L10n.text("发起在线解读时，所需问题、上下文与资料将经过账号服务器转交 AI 服务。", "When you request an online reading, the required question, context and profile details pass through the account server to the AI service."))
                                .font(.footnote).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                    }.padding(.horizontal, 4)
                    if account.user != nil {
                        Button { confirmLogout = true } label: {
                            Text(L10n.text("退出登录", "Sign out"))
                                .font(.system(size: 18, weight: .medium, design: .serif))
                                .foregroundStyle(InkTheme.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 20)
                                .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
                                .overlay(RoundedRectangle(cornerRadius: 20).stroke(InkTheme.line.opacity(0.6), lineWidth: 0.7))
                        }.buttonStyle(.plain)
                            .disabled(account.isBusy).accessibilityIdentifier("logoutAccount")
                        Spacer(minLength: 112)
                        Button { account.message = nil; confirmDeletion = true } label: {
                            Text(L10n.text("删除账号", "Delete account"))
                                .font(.system(size: 14))
                                .foregroundStyle(InkTheme.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.plain)
                            .disabled(account.isBusy).accessibilityIdentifier("deleteAccount")
                    }
                }.padding(22).frame(maxWidth: 760, minHeight: max(0, geometry.size.height), alignment: .top)
                    .frame(maxWidth: .infinity)
              }.refreshable { await account.refreshOverview() }
            }
        }
        .navigationTitle(L10n.text("账号", "Account"))
        .navigationBarTitleDisplayMode(.inline).tint(InkTheme.cinnabar)
        .task { await account.restore(); if account.user != nil { await account.refreshOverview() } }
        .alert(L10n.text("退出登录？", "Sign out?"), isPresented: $confirmLogout) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) { }
            Button(L10n.text("退出", "Sign out"), role: .destructive) { Task { await account.logout() } }
        } message: { Text(L10n.text("退出后需重新登录才能使用应用。本机资料与聊天仍会保留。", "You will need to sign in again to use the app. Local profiles and chats will remain.")) }
        .sheet(isPresented: $confirmDeletion) {
            if let user = account.user {
                AccountDeletionConfirmationView(user: user)
                    .environmentObject(account).environmentObject(store)
            }
        }
    }
}

struct AccountUsageView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var topUpPresented = false

    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if account.user != nil {
                        PaperCard {
                            VStack(alignment: .leading, spacing: 12) {
                                AccountAllowanceGauge()
                                Rectangle().fill(InkTheme.line.opacity(0.6)).frame(height: 0.5)
                                Button { topUpPresented = true } label: {
                                    HStack {
                                        Text(L10n.text("补充额度", "Replenish allowance"))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(InkTheme.secondary)
                                    }
                                    .font(.system(size: 15))
                                    .foregroundStyle(InkTheme.ink)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("topUpEntry")
                            }
                        }
                        Button { Task { await account.refreshOverview() } } label: {
                            HStack(spacing: 8) {
                                if account.isLoading { ProgressView().controlSize(.small) }
                                Label(L10n.text("刷新", "Refresh"), systemImage: "arrow.clockwise")
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(InkTheme.secondary)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(account.isLoading || account.isBusy)
                        .accessibilityIdentifier("refreshAccount")
                    } else {
                        NavigationLink { AccountView() } label: {
                            Text(L10n.text("登录后查看使用情况", "Sign in to view usage"))
                                .font(.system(size: 16, design: .serif))
                                .foregroundStyle(InkTheme.ink)
                                .frame(minHeight: 44)
                        }
                    }
                    if let message = account.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(InkTheme.secondary)
                            .lineSpacing(4)
                            .accessibilityIdentifier("usageMessage")
                    }
                }
                .padding(22)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await account.refreshOverview() }
        }
        .navigationTitle(L10n.text("使用情况", "Usage"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(InkTheme.ink)
        .task { await account.refreshOverview() }
        .sheet(isPresented: $topUpPresented) {
            NavigationStack { AccountTopUpView() }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("accountUsageView")
    }
}

struct AccountAllowanceGauge: View {
    @EnvironmentObject private var account: AccountStore
    private var percent: Int? { account.wallet?.quota?.displayedPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("可用额度", "Available allowance"))
                    .foregroundStyle(InkTheme.ink)
                Spacer()
                Text(percent.map { L10n.text("剩余 \($0)%", "\($0)% remaining") } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(InkTheme.secondary)
                    .accessibilityIdentifier("remainingQuotaPercentage")
            }
            .font(.system(size: 15))
            .frame(minHeight: 44)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("usageRemaining")
            ProgressView(value: Double(percent ?? 0), total: 100)
                .tint(InkTheme.sage)
                .scaleEffect(x: 1, y: 0.65)
                .frame(height: 4)
                .accessibilityLabel(L10n.text("剩余额度", "Remaining allowance"))
                .accessibilityIdentifier("remainingQuotaProgress")
        }
    }
}

private struct AccountDeletionConfirmationView: View {
    let user: AccountUser
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var store: OracleStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var copied = false
    @FocusState private var inputFocused: Bool

    private var accountLabel: String {
        let suffix = String(user.id.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
        return "\(user.presentationName)（\(suffix)）"
    }
    private var confirmationPhrase: String {
        L10n.text("我确认永久注销\(accountLabel)", "I confirm permanent deletion of \(accountLabel)")
    }
    private var canDelete: Bool {
        confirmation == confirmationPhrase && account.user?.id == user.id && !account.isBusy
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.minus")
                                .font(.system(size: 32, weight: .light)).foregroundStyle(InkTheme.cinnabar)
                                .accessibilityHidden(true)
                            Text(L10n.text("永久注销账号", "Permanently delete account"))
                                .font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                            Text(accountLabel).font(.subheadline).foregroundStyle(InkTheme.secondary)
                        }
                        PaperCard {
                            VStack(alignment: .leading, spacing: 18) {
                                consequence("person.crop.circle.badge.xmark", title: L10n.text("账号与资料将被清除", "Your account and records will be removed"),
                                            detail: L10n.text("将清除账号身份资料，以及本机保存的全部人员资料、聊天、推演和未完成记录。此操作无法撤销。", "Your account identity information and all profiles, chats, readings and unfinished work saved on this device will be cleared. This cannot be undone."))
                                Rectangle().fill(InkTheme.line.opacity(0.6)).frame(height: 0.5)
                                consequence("creditcard", title: L10n.text("已购额度无法恢复", "Purchased allowance cannot be recovered"),
                                            detail: L10n.text("剩余赠送及已购买的额度将无法使用、转移或恢复。重新注册也不能找回。注销账号不会自动申请退款。", "Remaining complimentary and purchased allowance will no longer be usable, transferable or recoverable, including after registering again. Deleting your account does not automatically request a refund."))
                            }
                        }.accessibilityIdentifier("deletionConsequences")
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("请在下方输入完整确认文字", "Enter the complete confirmation below"))
                                .font(.system(size: 16, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                            Text(confirmationPhrase).font(.subheadline).foregroundStyle(InkTheme.ink)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("deletionConfirmationPhrase")
                            Button {
                                UIPasteboard.general.setItems([["public.utf8-plain-text": confirmationPhrase]],
                                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                                copied = true
                            } label: {
                                Label(copied ? L10n.text("已复制", "Copied") : L10n.text("复制确认文字", "Copy confirmation"),
                                      systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(.vertical, 10).padding(.horizontal, 12)
                                    .background(InkTheme.wash, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).foregroundStyle(InkTheme.ink)
                                .disabled(account.isBusy).accessibilityIdentifier("copyDeletionConfirmation")
                            TextField(L10n.text("输入或粘贴确认文字", "Type or paste the confirmation"), text: $confirmation, axis: .vertical)
                                .font(.system(size: 16)).foregroundStyle(InkTheme.ink)
                                .lineLimit(2...4).padding(14)
                                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(inputFocused ? InkTheme.cinnabar : InkTheme.line, lineWidth: 1))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($inputFocused).disabled(account.isBusy)
                                .accessibilityIdentifier("deletionConfirmationInput")
                        }
                        if let message = account.message {
                            Text(message).font(.footnote).foregroundStyle(InkTheme.cinnabar).lineSpacing(4)
                                .accessibilityIdentifier("deletionMessage")
                        }
                        Button(role: .destructive) {
                            guard canDelete else { return }
                            inputFocused = false
                            Task {
                                let deleted = await account.deleteAccount {
                                    try await store.eraseLocalDataAfterAccountDeletion()
                                }
                                if deleted { dismiss() }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if account.isBusy { ProgressView().tint(.white) }
                                Text(account.isBusy ? L10n.text("正在注销…", "Deleting…") : L10n.text("永久注销账号", "Permanently delete account"))
                            }.font(.system(size: 16, weight: .medium, design: .serif))
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .foregroundStyle(canDelete || account.isBusy ? .white : InkTheme.secondary)
                                .background(canDelete || account.isBusy ? InkTheme.cinnabar : InkTheme.line.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).disabled(!canDelete).accessibilityIdentifier("confirmPermanentDeletion")
                        Text(ServiceEnvironment.current.isSandbox
                             ? L10n.text("本次注销仅影响测试账号；Apple 授权保留，以免影响正式账号。去标识化的账务、用量及防重记录按隐私政策保留，既有备份随备份轮换处理。", "This deletes only the test account; the shared Apple authorization is retained to protect your production account. Pseudonymous accounting, usage and abuse-prevention records remain as described in the Privacy Policy, and existing backups follow backup rotation.")
                             : L10n.text("注销会撤销已知 Apple 登录授权。去标识化的账务、用量及防重记录按隐私政策保留，既有备份随备份轮换处理。", "Known Sign in with Apple grants will be revoked. Pseudonymous accounting, usage and abuse-prevention records remain as described in the Privacy Policy, and existing backups follow backup rotation."))
                            .font(.footnote).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                        NavigationLink(L10n.text("查看隐私政策", "Read the Privacy Policy")) { LegalDocumentView(document: .privacyPolicy) }
                            .font(.footnote).foregroundStyle(InkTheme.secondary)
                    }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("取消", "Cancel")) { dismiss() }
                        .disabled(account.isBusy).accessibilityIdentifier("cancelAccountDeletion")
                }
            }
            .tint(InkTheme.cinnabar).interactiveDismissDisabled(account.isBusy)
        }.accessibilityIdentifier("accountDeletionConfirmation")
    }

    private func consequence(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(InkTheme.cinnabar)
                .frame(width: 22).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 16, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                Text(detail).font(.footnote).foregroundStyle(InkTheme.secondary).lineSpacing(4)
            }
        }
    }
}

extension AccountUser {
    var presentationName: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "用户" ? L10n.text("Apple 用户", "Apple user") : name
    }
}

struct AccountIdentityHeader: View {
    let user: AccountUser
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(String(user.presentationName.prefix(1)))
                .font(.system(size: 26, weight: .medium, design: .serif))
                .foregroundStyle(InkTheme.cinnabar).frame(width: 54, height: 54)
                .background(InkTheme.cinnabar.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(user.presentationName).font(.system(size: 21, weight: .medium, design: .serif))
                    .foregroundStyle(InkTheme.ink).lineLimit(1).accessibilityIdentifier("accountDisplayName")
                Label(L10n.text("Apple 账号", "Apple account"), systemImage: "apple.logo")
                    .font(.system(size: 11)).foregroundStyle(InkTheme.secondary).accessibilityIdentifier("accountIdentity")
                if let email = user.email, !email.isEmpty {
                    Text(email).font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                        .lineLimit(1).truncationMode(.middle).accessibilityIdentifier("accountEmail")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A real account summary, shared with the data library instead of a generic menu row.
struct AccountSummaryContent: View {
    @EnvironmentObject private var account: AccountStore
    var body: some View {
        HStack(spacing: 8) {
            if let user = account.user { AccountIdentityHeader(user: user) }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                .foregroundStyle(InkTheme.secondary.opacity(0.65)).accessibilityHidden(true)
        }.accessibilityIdentifier("accountSummary")
    }

}

struct NativeAppleSignInButton: UIViewRepresentable {
    var action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: .black)
        button.cornerRadius = 14
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) { context.coordinator.action = action }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}

@MainActor final class AppleAccountSignInCoordinator: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    @Published private(set) var isRunning = false
    private weak var account: AccountStore?
    private var attempt: AppleSignInAttempt?
    private var controller: ASAuthorizationController?
    func start(account: AccountStore) {
        guard !isRunning else { return }
        isRunning = true; self.account = account
        Task {
            do {
                let attempt = try await account.beginAppleSignIn()
                self.attempt = attempt
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.fullName, .email]
                request.nonce = attempt.challenge.hashedNonce
                request.state = attempt.challenge.challengeID
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self; controller.presentationContextProvider = self
                controller.performRequests()
            } catch { isRunning = false; controller = nil }
        }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let attempt, let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == attempt.challenge.challengeID,
              let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8), !token.isEmpty,
              let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8), !code.isEmpty else {
            account?.cancelAppleSignIn(attempt: attempt, message: L10n.text("Apple 未返回完整的登录信息，请重试。", "Apple did not return complete sign-in information. Please try again."))
            finish(); return
        }
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        Task {
            await account?.completeAppleSignIn(attempt: attempt, identityToken: token, authorizationCode: code, fullName: name, appleUserID: credential.user)
            finish()
        }
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        account?.cancelAppleSignIn(attempt: attempt, message: cancelled ? nil : L10n.text("Apple 登录未完成，请检查网络或设备上的 Apple 账号后重试。", "Apple sign-in did not complete. Check your connection and Apple account on this device, then try again."))
        finish()
    }
    private func finish() { isRunning = false; controller = nil; attempt = nil }
}
