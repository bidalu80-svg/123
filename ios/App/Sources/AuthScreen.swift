import SwiftUI

struct AuthScreen: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @FocusState private var focusedField: Field?

    enum Field {
        case endpoint
        case phone
        case password
        case confirmPassword
        case code
    }

    var body: some View {
        Form {
            Section("账号认证") {
                Picker("模式", selection: $authViewModel.mode) {
                    ForEach(AuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                TextField("认证服务地址（Cloudflare Worker）", text: $authViewModel.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .endpoint)

                Button("保存认证地址") {
                    authViewModel.saveBaseURL()
                }
                .buttonStyle(.bordered)
            }

            Section(authViewModel.mode == .login ? "登录信息" : "注册信息") {
                TextField("手机号（支持 +86 / 国际号码）", text: $authViewModel.phone)
                    .keyboardType(.phonePad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .phone)

                SecureField("密码（至少 8 位，含字母和数字）", text: $authViewModel.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)

                if authViewModel.mode == .register {
                    SecureField("确认密码", text: $authViewModel.confirmPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .confirmPassword)

                    HStack(spacing: 8) {
                        TextField("短信验证码", text: $authViewModel.verificationCode)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .code)

                        Button(codeButtonTitle) {
                            Task { await authViewModel.sendVerificationCode() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(authViewModel.isSendingCode || authViewModel.cooldownRemaining > 0)
                    }
                }
            }

            Section {
                Button(authViewModel.mode == .login ? "登录" : "注册并登录") {
                    Task { await authViewModel.submit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!authViewModel.canSubmit || authViewModel.isSubmitting)
            }

            if !authViewModel.statusMessage.isEmpty {
                Section("状态") {
                    Text(authViewModel.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !authViewModel.errorMessage.isEmpty {
                Section("错误") {
                    Text(authViewModel.errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("注册限制") {
                Text("为防止滥用，注册必须通过短信验证码验证手机号，且服务端会限制验证码请求频率与失败重试次数。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("欢迎使用 IEXA")
        .onChange(of: authViewModel.mode) { _, mode in
            if mode == .register {
                focusedField = .phone
            }
        }
    }

    private var codeButtonTitle: String {
        if authViewModel.isSendingCode {
            return "发送中…"
        }
        if authViewModel.cooldownRemaining > 0 {
            return "重发 \(authViewModel.cooldownRemaining)s"
        }
        return "发送验证码"
    }
}
