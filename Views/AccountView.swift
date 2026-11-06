import SwiftUI
import AuthenticationServices

struct AccountView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var apple = AppleAccountSignInCoordinator()
    @State private var confirmLogout = false
    @State private var confirmDeletion = false
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L10n.text("账号设置", "Account settings"))
                        .font(.system(size: 32, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                    PaperCard {
                        VStack(alignment: .leading, spacing: 14) {
                            if let user = account.user {
                                AccountIdentityHeader(user: user)

                            } else {
                                Text(L10n.text("用 Apple 登录", "Sign in with Apple")).font(.system(size: 20, design: .serif)).foregroundStyle(InkTheme.ink)
                                Text(L10n.text("登录后使用应用并查看剩余额度。本机资料仍会保留。", "Sign in to use the app and view your remaining allowance. Local records remain on this device."))
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
                    if account.user != nil {
                        PaperCard {
                            VStack(alignment: .leading, spacing: 18) {
                                AccountAllowanceGauge()
                                NavigationLink { AccountTopUpView() } label: {
                                    HStack {
                                        Text(L10n.text("补充额度", "Replenish allowance"))
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption)
                                    }.font(.system(size: 16, design: .serif))
                                }.accessibilityIdentifier("topUpEntry")
                                Button { Task { await account.refreshOverview() } } label: {
                                    HStack { if account.isLoading { ProgressView() }; Label(L10n.text("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                                }.disabled(account.isLoading || account.isBusy).accessibilityIdentifier("refreshAccount")
                            }
                        }
                    }
                    if let message = account.message {
                        Text(message).font(.subheadline).foregroundStyle(InkTheme.cinnabar).lineSpacing(4)
                            .accessibilityIdentifier("accountMessage")
                    }
                    PaperCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L10n.text("本机资料独立保存", "Local records stay on this device"), systemImage: "iphone")
                                .font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                            Text(L10n.text("人员资料、聊天与推演记录属于当前设备，不随账号自动上传或同步。退出、切换或删除账号不会清除或隔离本机记录；登录后仍可查看当前设备上的记录。共享设备或删除账号前，请先在数据和历史中删除相应记录。", "Profiles, chats and readings belong to this device and are not automatically uploaded or synced with your account. Signing out, switching or deleting an account does not clear or separate local records; they remain accessible after signing in on this device. Remove relevant records in Data and History before sharing the device or deleting your account."))
                                .font(.footnote).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                            Text(L10n.text("发起在线解读时，所需问题、上下文与资料将经过账号服务器转交 AI 服务。", "When you request an online reading, the required question, context and profile details pass through the account server to the AI service."))
                                .font(.footnote).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                        }
                    }
                    if account.user != nil {
                        Button(L10n.text("退出登录", "Sign out")) { confirmLogout = true }
                            .disabled(account.isBusy).accessibilityIdentifier("logoutAccount")
                        Button(L10n.text("删除账号", "Delete account"), role: .destructive) { confirmDeletion = true }
                            .disabled(account.isBusy).accessibilityIdentifier("deleteAccount")
                    }
                }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.refreshable { await account.refreshOverview() }
        }
        .navigationBarTitleDisplayMode(.inline).tint(InkTheme.cinnabar)
        .task { await account.restore(); if account.user != nil { await account.refreshOverview() } }
        .alert(L10n.text("退出登录？", "Sign out?"), isPresented: $confirmLogout) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) { }
            Button(L10n.text("退出", "Sign out"), role: .destructive) { Task { await account.logout() } }
        } message: { Text(L10n.text("退出后需重新登录才能使用应用。本机资料与聊天仍会保留。", "You will need to sign in again to use the app. Local profiles and chats will remain.")) }
        .alert(L10n.text("删除服务器账号？", "Delete your server account?"), isPresented: $confirmDeletion) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) { }
            Button(L10n.text("删除账号", "Delete account"), role: .destructive) { Task { await account.deleteAccount() } }
        } message: {
            Text(ServiceEnvironment.current.isSandbox
                 ? L10n.text("仅删除测试服务器账号；Apple 授权保留，以免影响正式版本。本机资料保留。请先在数据和历史清理需要删除的记录；删除后将回到测试环境登录页。", "This deletes only the test server account. Apple authorization is retained to protect the production app. Local records remain; remove them in Data and History first if needed. You will return to the test environment sign-in screen.")
                 : L10n.text("将向服务器申请删除账号并撤销登录授权，此操作不能撤销。本机资料不会自动删除，请先返回数据和历史清理需要删除的记录；删除账号后将回到登录页。", "This requests permanent deletion of your server account and revocation of sign-in authorization. Local records are not automatically deleted. Go back and remove them in Data and History before deleting your account; deletion returns you to the sign-in screen."))
        }
    }
    private var unavailableValue: some View { Text(L10n.text("尚未获取，请刷新或稍后重试。", "Not available yet. Refresh or try again later.")).font(.footnote).foregroundStyle(InkTheme.secondary) }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(InkTheme.secondary); Spacer(); Text(value).foregroundStyle(InkTheme.ink).monospacedDigit() }.font(.subheadline)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                if let user = account.user { AccountIdentityHeader(user: user) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InkTheme.secondary.opacity(0.65)).accessibilityHidden(true)
            }
            Rectangle().fill(InkTheme.line.opacity(0.6)).frame(height: 0.5)
            AccountAllowanceGauge()

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
