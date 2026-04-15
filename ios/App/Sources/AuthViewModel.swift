import Foundation

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
}
