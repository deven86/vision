import SwiftUI

struct LockView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.scenePhase) private var scenePhase

    private enum Stage { case create, confirm, enter }
    private enum Key: Hashable { case digit(Int), biometric, delete }

    private static let rows: [[Key]] = [
        [.digit(1), .digit(2), .digit(3)],
        [.digit(4), .digit(5), .digit(6)],
        [.digit(7), .digit(8), .digit(9)],
        [.biometric, .digit(0), .delete]
    ]
    private let length = 6

    @State private var stage: Stage = .enter
    @State private var entry = ""
    @State private var firstPIN = ""
    @State private var message: String?
    @State private var shake: CGFloat = 0
    @State private var busy = false
    @State private var didAutoPrompt = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Theme.accent.opacity(0.20), Theme.background],
                           center: .top, startRadius: 10, endRadius: 560)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer(minLength: 20)
                Wordmark(size: 42)
                VStack(spacing: 8) {
                    Text(title).font(.headline)
                    if stage == .create {
                        Text("Used when Face ID isn't available. It can't be recovered, so choose one you'll remember.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }
                dots.modifier(Shake(animatableData: shake))
                Text(message ?? " ")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 18)
                    .padding(.horizontal, 30)
                keypad
                Spacer(minLength: 20)
            }
            .foregroundStyle(.white)
        }
        .onAppear {
            stage = auth.hasPIN ? .enter : .create
            if scenePhase == .active { autoPrompt() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { autoPrompt() }
        }
    }

    private var title: String {
        switch stage {
        case .create: return "Create a 6-digit PIN"
        case .confirm: return "Confirm your PIN"
        case .enter: return "Enter your PIN"
        }
    }

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < entry.count ? Theme.accent : Color.clear)
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                    .scaleEffect(index < entry.count ? 1.1 : 1)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: entry.count)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(entry.count) of \(length) digits entered")
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach(0..<Self.rows.count, id: \.self) { row in
                HStack(spacing: 26) {
                    ForEach(Self.rows[row], id: \.self) { key in keyButton(key) }
                }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: Key) -> some View {
        switch key {
        case .digit(let digit):
            Button { press(digit) } label: {
                Text("\(digit)")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(CardPressStyle())
            .disabled(busy)
        case .biometric:
            if stage == .enter && auth.canUseBiometrics && auth.biometricsEnabled {
                Button { Task { await auth.unlockWithBiometrics() } } label: {
                    Image(systemName: auth.biometryType == .faceID ? "faceid" : "touchid")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 76, height: 76)
                }
                .accessibilityLabel(auth.biometryType == .faceID ? "Use Face ID" : "Use Touch ID")
            } else {
                Color.clear.frame(width: 76, height: 76)
            }
        case .delete:
            Button {
                if !entry.isEmpty { entry.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 24))
                    .frame(width: 76, height: 76)
            }
            .accessibilityLabel("Delete digit")
        }
    }

    private func autoPrompt() {
        guard !didAutoPrompt, stage == .enter, auth.hasPIN else { return }
        didAutoPrompt = true
        Task { await auth.unlockWithBiometrics() }
    }

    private func press(_ digit: Int) {
        guard !busy, entry.count < length else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        entry.append(String(digit))
        if entry.count == length { submit() }
    }

    private func submit() {
        let pin = entry
        switch stage {
        case .create:
            firstPIN = pin
            entry = ""
            message = nil
            stage = .confirm
        case .confirm:
            if pin == firstPIN {
                do {
                    try auth.createPIN(pin)
                } catch {
                    fail("Couldn't save your PIN. Please try again.")
                    stage = .create
                }
            } else {
                fail("PINs didn't match. Start again.")
                stage = .create
            }
            firstPIN = ""
        case .enter:
            busy = true
            Task {
                let result = await auth.verifyPIN(pin)
                busy = false
                switch result {
                case .success:
                    entry = ""
                case .wrong(let remaining):
                    fail(remaining > 0 ? "Wrong PIN. \(remaining) more before a timeout." : "Wrong PIN.")
                case .lockedOut(let until):
                    fail("Too many attempts. Try again \(until.formatted(.relative(presentation: .named))).")
                }
            }
        }
    }

    private func fail(_ text: String) {
        message = text
        entry = ""
        withAnimation(.linear(duration: 0.4)) { shake += 1 }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}
