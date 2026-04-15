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
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let safeBottom = proxy.safeAreaInsets.bottom

            ZStack {
                galaxyBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 24)
                    hero
                    Spacer(minLength: 22)
                    authPanel
                    bottomPolicyText
                }
                .padding(.horizontal, 22)
                .padding(.top, safeTop + 8)
                .padding(.bottom, max(10, safeBottom + 4))
            }
        }
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
            Button("跳过") {
                showEndpointSheet = true
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
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
                .font(.custom("AvenirNext-Bold", size: 72))
                .tracking(3.2)
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .white.opacity(0.18), radius: 14, x: 0, y: 2)

            LoopTypewriterText(
                fullText: "目前的你，尚未发掘_",
                typingSpeed: 7.5,
                holdAtEnd: 1.0,
                holdAtStart: 0.35
            )
            .font(.system(size: 22, weight: .regular, design: .monospaced))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity)
    }

    private var authPanel: some View {
        VStack(spacing: 11) {
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

            VStack(spacing: 5) {
                Text("IEXA 为你提供简洁高效的智能助手体验")
                Text("支持聊天、图像与代码能力，登录后即可开始使用")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.56))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24)

            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func secureCredentialField(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24)

            SecureField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
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
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(highlighted ? 0.97 : 0.9))
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(highlighted ? 0.14 : 0.09))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                highlighted
                                    ? Color(red: 0.86, green: 0.53, blue: 0.28).opacity(0.88)
                                    : Color.white.opacity(0.12),
                                lineWidth: highlighted ? 1.4 : 0.9
                            )
                    )
            )
            .overlay {
                if highlighted {
                    OrbitingCapsuleStroke(
                        lineWidth: 1.45,
                        cyclesPerSecond: 0.06,
                        segmentFraction: 0.16
                    )
                        .padding(-1.2)
                }
            }
            .shadow(
                color: highlighted
                    ? Color(red: 0.86, green: 0.53, blue: 0.28).opacity(0.24)
                    : .black.opacity(0.22),
                radius: 7,
                x: 0,
                y: 2
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

    private var bottomPolicyText: some View {
        Text("继续即表示你同意服务条款和隐私政策")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, 10)
    }
}

private struct GalaxyStarField: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            GeometryReader { proxy in
                let size = proxy.size
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    ForEach(0..<200, id: \.self) { index in
                        let star = starSpec(index: index)
                        let normalizedY = wrappedUnit(star.baseY - time * star.speed)

                        Circle()
                            .fill(Color.white.opacity(star.alpha))
                            .frame(width: star.radius, height: star.radius)
                            .position(x: star.baseX * size.width, y: normalizedY * size.height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func wrappedUnit(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1.0)
        return remainder >= 0 ? remainder : remainder + 1.0
    }

    private func starSpec(index: Int) -> (baseX: CGFloat, baseY: Double, radius: CGFloat, alpha: CGFloat, speed: Double) {
        let x = pseudoRandom(index * 23 + 7)
        let y = Double(pseudoRandom(index * 37 + 13))
        let radius = 0.55 + pseudoRandom(index * 29 + 3) * 2.1
        let alpha = 0.16 + pseudoRandom(index * 17 + 11) * 0.66
        let speed = 0.006 + Double(pseudoRandom(index * 41 + 19)) * 0.03
        return (x, y, radius, alpha, speed)
    }

    private func pseudoRandom(_ seed: Int) -> CGFloat {
        let value = sin(Double(seed) * 12.9898) * 43758.5453
        return CGFloat(value - floor(value))
    }
}

private struct OrbitingCapsuleStroke: View {
    let lineWidth: CGFloat
    let cyclesPerSecond: Double
    let segmentFraction: Double

    private let goldGradient = LinearGradient(
        colors: [
            Color(red: 0.99, green: 0.86, blue: 0.52),
            Color(red: 0.94, green: 0.69, blue: 0.28),
            Color(red: 0.79, green: 0.45, blue: 0.12)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let start = wrapped(elapsed * cyclesPerSecond)
            let end = start + max(0.02, min(segmentFraction, 0.35))
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            ZStack {
                movingSegment(from: start, to: end, style: style)
                    .blendMode(.plusLighter)
                    .shadow(color: Color(red: 0.96, green: 0.72, blue: 0.28).opacity(0.45), radius: 3, x: 0, y: 0)

                Capsule(style: .continuous)
                    .stroke(Color(red: 0.86, green: 0.53, blue: 0.22).opacity(0.16), lineWidth: lineWidth * 0.72)
            }
        }
    }

    @ViewBuilder
    private func movingSegment(from start: Double, to end: Double, style: StrokeStyle) -> some View {
        if end <= 1 {
            Capsule(style: .continuous)
                .trim(from: start, to: end)
                .stroke(goldGradient, style: style)
        } else {
            ZStack {
                Capsule(style: .continuous)
                    .trim(from: start, to: 1)
                    .stroke(goldGradient, style: style)
                Capsule(style: .continuous)
                    .trim(from: 0, to: end - 1)
                    .stroke(goldGradient, style: style)
            }
        }
    }

    private func wrapped(_ value: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: 1)
        return r >= 0 ? r : r + 1
    }
}

private struct LoopTypewriterText: View {
    let fullText: String
    let typingSpeed: Double
    let holdAtEnd: Double
    let holdAtStart: Double

    var body: some View {
        let chars = Array(fullText)
        let count = chars.count
        let typeDuration = Double(max(count, 1)) / max(typingSpeed, 0.1)
        let eraseDuration = typeDuration * 0.72
        let cycle = holdAtStart + typeDuration + holdAtEnd + eraseDuration

        return TimelineView(.animation(minimumInterval: 1.0 / 28.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            let visibleCount: Int

            if t < holdAtStart {
                visibleCount = 0
            } else if t < holdAtStart + typeDuration {
                let progress = (t - holdAtStart) / typeDuration
                visibleCount = min(count, max(0, Int(progress * Double(count))))
            } else if t < holdAtStart + typeDuration + holdAtEnd {
                visibleCount = count
            } else {
                let eraseProgress = (t - holdAtStart - typeDuration - holdAtEnd) / eraseDuration
                visibleCount = max(0, min(count, count - Int(eraseProgress * Double(count))))
            }

            Text(String(chars.prefix(visibleCount)))
        }
    }
}
