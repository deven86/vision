import SwiftUI

enum SettingsKeys {
    static let biometricsEnabled = "security.biometrics"
    static let autoLockSeconds = "security.autoLockSeconds"
    static let heroPreview = "playback.heroPreview"
    static let binRetentionDays = "bin.retentionDays"
}

/// Cinematic dark theme. Signature accent is VISION gold — deliberately not
/// a streaming-brand red, so the app has its own identity.
enum Theme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let surface = Color(white: 0.12)
    static let surfaceRaised = Color(white: 0.18)
    static let accent = Color(red: 0.93, green: 0.69, blue: 0.27)
    static let accentDeep = Color(red: 0.80, green: 0.47, blue: 0.13)
    static let secondaryText = Color.white.opacity(0.64)
    static let tertiaryText = Color.white.opacity(0.40)
    static let cardCorner: CGFloat = 6

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 1.0, green: 0.84, blue: 0.46), accentDeep],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct Wordmark: View {
    var size: CGFloat = 24
    var body: some View {
        Text("VISION")
            .font(.system(size: size, weight: .black))
            .tracking(size * 0.16)
            .foregroundStyle(Theme.accentGradient)
            .shadow(color: Theme.accent.opacity(0.35), radius: size * 0.3)
            .accessibilityLabel("VISION")
    }
}

/// Subtle press-down for cards and tiles.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

enum Format {
    /// 1:05:09 or 5:09
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 1h 12m · 12m · 45s
    static func runtime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
