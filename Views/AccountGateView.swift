import SwiftUI

/// Sign-in controls are mounted only when authentication is actually required.
struct AccountGateView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var apple = AppleAccountSignInCoordinator()
    @ScaledMetric(relativeTo: .footnote) private var progressHeight = 24
    @ScaledMetric(relativeTo: .footnote) private var messageHeight = 72
    private var isSigningIn: Bool { account.isBusy || apple.isRunning }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    PaperBackground()
                    ScrollView {
                        VStack(spacing: 0) {
                            HStack(spacing: 9) {
                                RoundedRectangle(cornerRadius: 1).fill(InkTheme.cinnabar).frame(width: 3, height: 16)
                                Text(L10n.text("瞎子", "BlindOracle")).font(.system(size: 20, weight: .medium, design: .serif))
                                Spacer()
                            }.foregroundStyle(InkTheme.ink)
                            Spacer(minLength: 44)
                            VStack(spacing: 28) {
                                OracleMark(size: 112)
                                Text(L10n.text("慢听一问，静观其变。", "A little clarity,\none question at a time."))
                                    .font(.system(.largeTitle, design: .serif).weight(.medium))
                                    .foregroundStyle(InkTheme.ink).lineSpacing(8)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(AppLanguage.current.isEnglish ? 2 : 1)
                                    .minimumScaleFactor(0.45)
                                    .frame(maxWidth: .infinity)
                            }
                            Spacer(minLength: 52)
                            VStack(spacing: 12) {
                                NativeAppleSignInButton { apple.start(account: account) }
                                    .frame(height: 54).disabled(isSigningIn)
                                    .accessibilityIdentifier("appleSignInButton")
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.text("正在完成登录…", "Signing you in…")).font(.footnote).foregroundStyle(InkTheme.secondary)
                                }
                                .frame(height: progressHeight)
                                .opacity(isSigningIn ? 1 : 0)
                                .accessibilityHidden(!isSigningIn)
                                .accessibilityIdentifier("signInProgress")
                                ScrollView {
                                    Text(account.message ?? "").font(.footnote).foregroundStyle(InkTheme.cinnabar)
                                        .multilineTextAlignment(.center).lineSpacing(4)
                                        .frame(maxWidth: .infinity)
                                        .accessibilityIdentifier("accountMessage")
                                }
                                .frame(height: messageHeight)
                                .scrollBounceBehavior(.basedOnSize)
                                .opacity(account.message == nil ? 0 : 1)
                                .accessibilityHidden(account.message == nil)
                                .allowsHitTesting(account.message != nil)
                            }
                            Spacer(minLength: 32)
                            VStack(spacing: 7) {
                                Text(L10n.text("登录即表示你已阅读并同意", "By signing in, you agree to our"))
                                    .foregroundStyle(InkTheme.secondary).multilineTextAlignment(.center)
                                HStack(spacing: 12) {
                                    NavigationLink(L10n.text("用户协议", "User Agreement")) { LegalDocumentView(document: .userAgreement) }.accessibilityIdentifier("gateUserAgreement")
                                    Text("·").foregroundStyle(InkTheme.line)
                                    NavigationLink(L10n.text("隐私政策", "Privacy Policy")) { LegalDocumentView(document: .privacyPolicy) }.accessibilityIdentifier("gatePrivacyPolicy")
                                }.foregroundStyle(InkTheme.ink)
                            }
                            .font(.caption)
                        }
                        .frame(maxWidth: 430).frame(minHeight: max(0, geometry.size.height - 48))
                        .padding(.horizontal, 28).padding(.vertical, 24).frame(maxWidth: .infinity)
                    }.scrollBounceBehavior(.basedOnSize)
                }
            }.tint(InkTheme.cinnabar).accessibilityIdentifier("accountGate")
        }
    }
}

/// Returning users see a quiet launch surface, never a sign-in form.
struct AccountRestoringView: View {
    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 17) {
                OracleMark(size: 80)
                HStack(spacing: 7) {
                    Text(L10n.text("瞎子", "BlindOracle")).font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                    TestEnvironmentBadge()
                }
                ProgressView().controlSize(.small).tint(InkTheme.secondary).padding(.top, 12)
                    .accessibilityLabel(L10n.text("正在恢复账号", "Restoring your account"))
            }.padding(.bottom, 30)
        }.accessibilityIdentifier("accountLaunchScreen")
    }
}

/// A temporary connection failure does not send a returning user to sign-in.
struct AccountRecoveryView: View {
    @EnvironmentObject private var account: AccountStore
    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 22) {
                OracleMark(size: 72)
                Text(account.deletionCleanupRequired ? L10n.text("完成最后的清理", "Finish clearing your data") : L10n.text("稍等，连接有些慢。", "Let’s reconnect.")).font(.system(size: 25, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                Text(account.deletionCleanupRequired ? L10n.text("账号已经永久注销。请完成本机资料清理后再重新登录。", "Your account has been permanently deleted. Finish clearing local records before signing in again.") : L10n.text("你的登录信息已保留。请检查网络，再试一次。", "Your saved session is still here. Check your connection and try again."))
                    .font(.subheadline).foregroundStyle(InkTheme.secondary).lineSpacing(4).multilineTextAlignment(.center)
                Button(account.deletionCleanupRequired ? L10n.text("重试清理", "Retry cleanup") : L10n.text("重新连接", "Try again")) {
                    Task {
                        if account.deletionCleanupRequired { await account.retryDeletionCleanup() }
                        else { await account.restore(force: true) }
                    }
                }
                    .buttonStyle(InkPrimaryButton()).accessibilityIdentifier("retrySession")
                    .disabled(account.isBusy)
                if !account.deletionCleanupRequired {
                    Button(L10n.text("重新使用 Apple 登录", "Sign in again with Apple")) { Task { await account.chooseSignIn() } }
                        .font(.footnote).foregroundStyle(InkTheme.secondary).padding(.top, 3).accessibilityIdentifier("chooseSignIn")
                }
                if let message = account.message {
                    Text(message).font(.caption).foregroundStyle(InkTheme.secondary).multilineTextAlignment(.center).accessibilityIdentifier("accountMessage")
                }
            }.padding(28).frame(maxWidth: 430)
        }.accessibilityIdentifier("accountRecovery")
    }
}
