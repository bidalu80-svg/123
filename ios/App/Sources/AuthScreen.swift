import SwiftUI

struct AuthScreen: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @FocusState private var focusedField: Field?

    enum Field {
        case endpoint
        case phone
        case password
        case confirmPassword
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
                TextField("账号（可填手机号）", text: $authViewModel.phone)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .phone)

                SecureField("密码（至少 6 位）", text: $authViewModel.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)

                if authViewModel.mode == .register {
                    SecureField("确认密码", text: $authViewModel.confirmPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .confirmPassword)
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

            Section("管理员") {
                Text("管理员账号可直接登录：blank / 888888（无需注册）。")
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
}
