import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var mode: AuthMode = .login
    @Published var baseURL: String
    @Published var phone = ""
    @Published var password = ""
    @Published var confirmPassword = ""

    @Published var isSubmitting = false
    @Published var statusMessage = ""
    @Published var errorMessage = ""
    @Published private(set) var session: AuthSession?

    private let service: AuthService

    init(service: AuthService = AuthService()) {
        self.service = service
        self.baseURL = AuthSessionStore.loadBaseURL()
        self.session = AuthSessionStore.loadSession()
        if let session {
            self.phone = session.user.phone
        }
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var currentUserPhone: String {
        session?.user.phone ?? "未登录"
    }

    var canSubmit: Bool {
        let endpoint = AuthSessionStore.normalizedBaseURL(baseURL)
        let normalizedAccount = AuthService.normalizedAccount(phone)
        guard !endpoint.isEmpty, AuthService.isAccountValid(normalizedAccount), AuthService.isPasswordValid(password) else {
            return false
        }
        return true
    }

    var hasAuthEndpoint: Bool {
        !AuthSessionStore.normalizedBaseURL(baseURL).isEmpty
    }

    var canUseGoogleSignIn: Bool {
        guard let rawClientID = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String else {
            return false
        }
        return !rawClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveBaseURL() {
        let normalized = AuthSessionStore.normalizedBaseURL(baseURL)
        baseURL = normalized
        AuthSessionStore.saveBaseURL(normalized)
        statusMessage = normalized.isEmpty ? "认证地址已清空" : "认证地址已保存"
    }

    func submit() async {
        guard !isSubmitting else { return }
        let endpoint = AuthSessionStore.normalizedBaseURL(baseURL)
        guard !endpoint.isEmpty else {
            errorMessage = "请先填写认证服务地址。"
            return
        }

        let normalizedAccount = AuthService.normalizedAccount(phone)
        guard AuthService.isAccountValid(normalizedAccount) else {
            errorMessage = "账号格式无效。"
            return
        }

        guard AuthService.isPasswordValid(password) else {
            errorMessage = "密码至少 6 位。"
            return
        }

        errorMessage = ""
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let result: AuthSession
            switch mode {
            case .login:
                result = try await service.login(baseURL: endpoint, account: normalizedAccount, password: password)
            case .register:
                result = try await service.register(
                    baseURL: endpoint,
                    account: normalizedAccount,
                    password: password
                )
            }
            AuthSessionStore.saveBaseURL(endpoint)
            AuthSessionStore.saveSession(result)
            session = result
            statusMessage = mode == .login ? "登录成功" : "注册并登录成功"
            password = ""
            confirmPassword = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submit(as mode: AuthMode) async {
        self.mode = mode
        if mode == .register {
            confirmPassword = password
        }
        await submit()
    }

    func submitGoogleSignIn() async {
        guard !isSubmitting else { return }
        let endpoint = AuthSessionStore.normalizedBaseURL(baseURL)
        guard !endpoint.isEmpty else {
            errorMessage = "请先填写认证服务地址。"
            return
        }

        errorMessage = ""
        isSubmitting = true
        defer { isSubmitting = false }

        #if canImport(GoogleSignIn)
        guard let rawClientID = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String else {
            errorMessage = "缺少 GOOGLE_CLIENT_ID 配置。"
            return
        }
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            errorMessage = "GOOGLE_CLIENT_ID 为空。"
            return
        }

        guard let presenter = topPresentingViewController() else {
            errorMessage = "无法打开 Google 登录页面。"
            return
        }

        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString, !idToken.isEmpty else {
                throw AuthServiceError.server("Google 未返回可用登录凭证。")
            }

            let session = try await service.loginWithGoogle(baseURL: endpoint, idToken: idToken)
            AuthSessionStore.saveBaseURL(endpoint)
            AuthSessionStore.saveSession(session)
            self.session = session
            self.phone = session.user.phone
            self.password = ""
            self.confirmPassword = ""
            self.statusMessage = "Google 登录成功"
        } catch {
            errorMessage = error.localizedDescription
        }
        #else
        errorMessage = "当前构建未集成 GoogleSignIn SDK。"
        #endif
    }

    func submitAppleSignIn() async {
        guard !isSubmitting else { return }
        let endpoint = AuthSessionStore.normalizedBaseURL(baseURL)
        guard !endpoint.isEmpty else {
            errorMessage = "请先填写认证服务地址。"
            return
        }

        errorMessage = ""
        isSubmitting = true
        defer { isSubmitting = false }

        #if canImport(AuthenticationServices)
        do {
            let token = try await AppleSignInCoordinator.shared.requestIdentityToken()
            let session = try await service.loginWithApple(baseURL: endpoint, idToken: token)
            AuthSessionStore.saveBaseURL(endpoint)
            AuthSessionStore.saveSession(session)
            self.session = session
            self.phone = session.user.phone
            self.password = ""
            self.confirmPassword = ""
            self.statusMessage = "Apple 登录成功"
        } catch {
            errorMessage = error.localizedDescription
        }
        #else
        errorMessage = "当前系统不支持 Apple 登录。"
        #endif
    }

    func logout() async {
        guard let session else {
            AuthSessionStore.clearSession()
            return
        }

        let endpoint = AuthSessionStore.normalizedBaseURL(baseURL)
        if !endpoint.isEmpty {
            await service.logout(baseURL: endpoint, token: session.token)
        }

        AuthSessionStore.clearSession()
        self.session = nil
        self.password = ""
        self.confirmPassword = ""
        self.statusMessage = "已退出登录"
    }

    private func topPresentingViewController() -> UIViewController? {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }

        let windows = scenes.flatMap { $0.windows }
        let keyWindow = windows.first(where: { $0.isKeyWindow }) ?? windows.first

        var controller = keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
        #else
        return nil
        #endif
    }
}

#if canImport(AuthenticationServices) && canImport(UIKit)
private final class AppleSignInCoordinator: NSObject {
    static let shared = AppleSignInCoordinator()

    private var continuation: CheckedContinuation<String, Error>?

    enum AppleSignInError: LocalizedError {
        case unavailable
        case cancelled
        case invalidCredential
        case missingIdentityToken

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "当前设备不支持 Apple 登录。"
            case .cancelled:
                return "已取消 Apple 登录。"
            case .invalidCredential:
                return "Apple 返回了无效登录凭证。"
            case .missingIdentityToken:
                return "Apple 未返回可用身份令牌。"
            }
        }
    }

    func requestIdentityToken() async throws -> String {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            guard self.continuation == nil else {
                continuation.resume(throwing: AppleSignInError.unavailable)
                return
            }

            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AppleSignInError.invalidCredential)
            continuation = nil
            return
        }

        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty else {
            continuation?.resume(throwing: AppleSignInError.missingIdentityToken)
            continuation = nil
            return
        }

        continuation?.resume(returning: token)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError {
            let mappedError: Error
            switch authError.code {
            case .canceled:
                mappedError = AppleSignInError.cancelled
            case .unknown:
                mappedError = NSError(
                    domain: "AppleSignIn",
                    code: Int(authError.code.rawValue),
                    userInfo: [
                        NSLocalizedDescriptionKey: """
                        Apple 登录初始化失败（错误 1000）。
                        请确认：
                        1) Apple Developer 的 App ID 已开启 Sign in with Apple；
                        2) 当前 Provisioning Profile 已重新生成并包含该能力；
                        3) App 使用了包含此能力的签名重新安装。
                        """
                    ]
                )
            case .notHandled:
                mappedError = NSError(
                    domain: "AppleSignIn",
                    code: Int(authError.code.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "Apple 登录请求未被系统处理，请稍后重试。"]
                )
            case .invalidResponse:
                mappedError = NSError(
                    domain: "AppleSignIn",
                    code: Int(authError.code.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "Apple 登录返回无效响应，请稍后重试。"]
                )
            case .failed:
                mappedError = NSError(
                    domain: "AppleSignIn",
                    code: Int(authError.code.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "Apple 登录失败，请稍后重试。"]
                )
            @unknown default:
                mappedError = authError
            }
            continuation?.resume(throwing: mappedError)
            continuation = nil
            return
        }

        continuation?.resume(throwing: error)
        continuation = nil
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        let windows = scenes.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? UIWindow(frame: .zero)
    }
}
#endif
