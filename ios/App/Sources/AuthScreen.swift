import SwiftUI

struct AuthScreen: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @FocusState private var focusedField: Field?
    @State private var showEndpointSheet = false

    enum Field {
        case account
        case password
    }

    var body: some View {
        ZStack {
            galaxyBackground

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 30)
                hero
                Spacer(minLength: 26)
                authPanel
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showEndpointSheet) {
            NavigationStack {
                Form {
                    Section("认证服务地址") {
                        TextField("https://chatapp-auth-worker-v2.xxx.workers.dev", text: $authViewModel.baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button("保存") {
                            authViewModel.saveBaseURL()
                            showEndpointSheet = false
                        }
                    }
                }
                .navigationTitle("连接设置")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button("设置") {
                showEndpointSheet = true
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 24)
            .padding(.vertical, 11)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Text("IEXA")
                .font(.system(size: 78, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .white.opacity(0.18), radius: 14, x: 0, y: 2)

            Text("Understand the Universe_")
                .font(.system(size: 34, weight: .regular, design: .monospaced))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity)
    }

    private var authPanel: some View {
        VStack(spacing: 14) {
            credentialField(icon: "person.crop.circle.fill", placeholder: "账号（可填手机号）", text: $authViewModel.phone)
                .focused($focusedField, equals: .account)

            secureCredentialField(icon: "lock.fill", placeholder: "密码（至少 6 位）", text: $authViewModel.password)
                .focused($focusedField, equals: .password)

            VStack(spacing: 12) {
                capsuleActionButton(
                    title: authViewModel.isSubmitting && authViewModel.mode == .login ? "登录中…" : "登录使用",
                    systemIcon: "person.fill",
                    highlighted: true
                ) {
                    Task { await authViewModel.submit(as: .login) }
                }
                .disabled(!authViewModel.canSubmit || authViewModel.isSubmitting)

                capsuleActionButton(
                    title: authViewModel.isSubmitting && authViewModel.mode == .register ? "注册中…" : "注册使用",
                    systemIcon: "person.badge.plus.fill",
                    highlighted: false
                ) {
                    Task { await authViewModel.submit(as: .register) }
                }
                .disabled(!authViewModel.canSubmit || authViewModel.isSubmitting)
            }
            .padding(.top, 4)

            if !authViewModel.statusMessage.isEmpty {
                Text(authViewModel.statusMessage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }

            if !authViewModel.errorMessage.isEmpty {
                Text(authViewModel.errorMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            Text("管理员账号：blank    密码：888888")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.56))
                .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blur(radius: 6)
                .opacity(0.5)
        }
    }

    private func credentialField(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24)

            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func secureCredentialField(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24)

            SecureField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func capsuleActionButton(
        title: String,
        systemIcon: String,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemIcon)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(highlighted ? 0.97 : 0.9))
            .padding(.horizontal, 22)
            .frame(height: 70)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(highlighted ? 0.14 : 0.09))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                highlighted
                                    ? Color(red: 0.86, green: 0.53, blue: 0.28).opacity(0.88)
                                    : Color.white.opacity(0.12),
                                lineWidth: highlighted ? 1.8 : 1
                            )
                    )
            )
            .shadow(
                color: highlighted
                    ? Color(red: 0.86, green: 0.53, blue: 0.28).opacity(0.24)
                    : .black.opacity(0.22),
                radius: 12,
                x: 0,
                y: 4
            )
        }
        .buttonStyle(.plain)
    }

    private var galaxyBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.01, green: 0.05, blue: 0.13),
                    Color(red: 0.02, green: 0.03, blue: 0.08),
                    Color(red: 0.01, green: 0.01, blue: 0.03)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(0.34),
                    Color.white.opacity(0.14),
                    Color.clear
                ],
                center: .init(x: 0.05, y: 0.64),
                startRadius: 20,
                endRadius: 420
            )
            .blendMode(.plusLighter)

            RadialGradient(
                colors: [
                    Color.white.opacity(0.28),
                    Color.clear
                ],
                center: .init(x: 0.76, y: 0.57),
                startRadius: 12,
                endRadius: 360
            )
            .blendMode(.screen)

            GalaxyStarField()
        }
    }
}

private struct GalaxyStarField: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ForEach(0..<210, id: \.self) { index in
                    let x = pseudoRandom(index * 23 + 7)
                    let y = pseudoRandom(index * 37 + 13)
                    let radius = 0.6 + pseudoRandom(index * 29 + 3) * 2.3
                    let alpha = 0.2 + pseudoRandom(index * 17 + 11) * 0.7

                    Circle()
                        .fill(Color.white.opacity(alpha))
                        .frame(width: radius, height: radius)
                        .position(x: x * size.width, y: y * size.height)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func pseudoRandom(_ seed: Int) -> CGFloat {
        let value = sin(Double(seed) * 12.9898) * 43758.5453
        return CGFloat(value - floor(value))
    }
}
