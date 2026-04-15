import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var mode: AuthMode = .login
    @Published var baseURL: String
    @Published var phone = ""
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published var verificationCode = ""

    @Published var isSubmitting = false
    @Published var isSendingCode = false
    @Published var cooldownRemaining = 0
    @Published var statusMessage = ""
    @Published var errorMessage = ""
    @Published private(set) var session: AuthSession?

    private let service: AuthService
    private var cooldownTask: Task<Void, Never>?

    init(service: AuthService = AuthService()) {
        self.service = service
        self.baseURL = AuthSessionStore.loadBaseURL()
        self.session = AuthSessionStore.loadSession()
        if let session {
            self.phone = session.user.phone
        }
    }

    deinit {
        cooldownTask?.cancel()
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var currentUserPhone: String {
        session?.user.phone ?? "未登录"
    }

    var canSubmit: Bool {
        let endpoint = AuthSessionStore.normalizedBaseURL(baseURL)
        let normalizedPhone = AuthService.normalizedPhone(phone)
        guard !endpoint.isEmpty, AuthService.isPhoneValid(normalizedPhone), AuthService.isPasswordValid(password) else {
            return false
        }

        if mode == .register {
            guard password == confirmPassword else { return false }
            guard AuthService.isCodeValid(verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        }
        return true
    }

    func saveBaseURL() {
        let normalized = AuthSessionStore.normalizedBaseURL(baseURL)
        baseURL = normalized
        AuthSessionStore.saveBaseURL(normalized)
        statusMessage = normalized.isEmpty ? "认证地址已清空" : "认证地址已保存"
    }

    func sendVerificationCode() async {
        guard !isSendingCode else { return }
        let endpoint = AuthSessionStore.normalizedBaseURL(baseURL)
        let normalizedPhone = AuthService.normalizedPhone(phone)
        guard !endpoint.isEmpty else {
            errorMessage = "请先填写认证服务地址。"
            return
        }
        guard AuthService.isPhoneValid(normalizedPhone) else {
            errorMessage = "请填写有效手机号。"
            return
        }

        errorMessage = ""
        isSendingCode = true
        defer { isSendingCode = false }

        do {
            let result = try await service.sendCode(baseURL: endpoint, phone: normalizedPhone)
            cooldownRemaining = result.cooldownSeconds
            statusMessage = result.message
            startCooldownTickerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submit() async {
        guard !isSubmitting else { return }
        let endpoint = AuthSessionStore.normalizedBaseURL(baseURL)
        guard !endpoint.isEmpty else {
            errorMessage = "请先填写认证服务地址。"
            return
        }

        let normalizedPhone = AuthService.normalizedPhone(phone)
        guard AuthService.isPhoneValid(normalizedPhone) else {
            errorMessage = "手机号格式无效。"
            return
        }

        guard AuthService.isPasswordValid(password) else {
            errorMessage = "密码至少 8 位，且需包含字母和数字。"
            return
        }

        if mode == .register, password != confirmPassword {
            errorMessage = "两次输入的密码不一致。"
            return
        }

        errorMessage = ""
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let result: AuthSession
            switch mode {
            case .login:
                result = try await service.login(baseURL: endpoint, phone: normalizedPhone, password: password)
            case .register:
                result = try await service.register(
                    baseURL: endpoint,
                    phone: normalizedPhone,
                    password: password,
                    code: verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            AuthSessionStore.saveBaseURL(endpoint)
            AuthSessionStore.saveSession(result)
            session = result
            statusMessage = mode == .login ? "登录成功" : "注册并登录成功"
            password = ""
            confirmPassword = ""
            verificationCode = ""
        } catch {
            errorMessage = error.localizedDescription
        }
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
        self.verificationCode = ""
        self.statusMessage = "已退出登录"
    }

    private func startCooldownTickerIfNeeded() {
        cooldownTask?.cancel()
        guard cooldownRemaining > 0 else { return }
        cooldownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let remaining = await MainActor.run { () -> Int in
                    guard let self else { return 0 }
                    if self.cooldownRemaining > 0 {
                        self.cooldownRemaining -= 1
                    }
                    return self.cooldownRemaining
                }
                if remaining <= 0 {
                    break
                }
            }
        }
    }
}
