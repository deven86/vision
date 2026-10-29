import Foundation
import LocalAuthentication
import Observation

struct LockoutState: Codable {
    var failures: Int = 0
    var lockedUntil: Date?
}

enum PINResult {
    case success
    case wrong(remainingBeforeTimeout: Int)
    case lockedOut(until: Date)
}

/// App-level lock. Face ID / Touch ID via LocalAuthentication, app PIN as fallback.
/// Note: this gate protects against someone opening the app on an unlocked phone.
/// File confidentiality comes from the vault encryption, not from this screen.
@MainActor
@Observable
final class AuthService {
    private(set) var isUnlocked = false
    private(set) var hasPIN: Bool

    private static let pinAccount = "pin.v1"
    private static let lockoutAccount = "pin.lockout.v1"
    static let freeAttempts = 5

    init() {
        hasPIN = ((try? Keychain.read(Self.pinAccount)) ?? nil) != nil
    }

    // MARK: Biometrics

    var canUseBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    var biometricsEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.biometricsEnabled) as? Bool ?? true
    }

    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard hasPIN, biometricsEnabled else { return false }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter PIN"
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                      localizedReason: "Unlock your VISION vault")
            if ok { isUnlocked = true }
            return ok
        } catch {
            return false
        }
    }

    // MARK: PIN

    func createPIN(_ pin: String) throws {
        let record = PINHasher.makeRecord(pin: pin)
        try Keychain.set(try JSONEncoder().encode(record), for: Self.pinAccount)
        hasPIN = true
        saveLockout(LockoutState())
        isUnlocked = true
    }

    func verifyPIN(_ pin: String) async -> PINResult {
        var state = loadLockout()
        if let until = state.lockedUntil, until > Date() { return .lockedOut(until: until) }

        guard let data = (try? Keychain.read(Self.pinAccount)) ?? nil,
              let record = try? JSONDecoder().decode(PINRecord.self, from: data) else {
            return .wrong(remainingBeforeTimeout: 0)
        }

        // PBKDF2 is deliberately slow — keep it off the main thread.
        let ok = await Task.detached(priority: .userInitiated) {
            PINHasher.verify(pin, against: record)
        }.value

        if ok {
            saveLockout(LockoutState())
            isUnlocked = true
            return .success
        }

        state.failures += 1
        let delay = Self.timeout(afterFailures: state.failures)
        state.lockedUntil = delay > 0 ? Date().addingTimeInterval(delay) : nil
        saveLockout(state)
        if let until = state.lockedUntil { return .lockedOut(until: until) }
        return .wrong(remainingBeforeTimeout: max(0, Self.freeAttempts - state.failures))
    }

    /// Requires the current PIN (counts toward lockout).
    func changePIN(current: String, new: String) async -> Bool {
        guard PINHasher.isValidPIN(new) else { return false }
        guard case .success = await verifyPIN(current) else { return false }
        do { try createPIN(new); return true } catch { return false }
    }

    static func timeout(afterFailures failures: Int) -> TimeInterval {
        switch failures {
        case ..<freeAttempts: return 0
        case freeAttempts: return 30
        case freeAttempts + 1: return 60
        case freeAttempts + 2: return 300
        default: return 900
        }
    }

    // MARK: Lock

    func lock() {
        isUnlocked = false
        ThumbnailCache.shared.purge()
    }

    private func loadLockout() -> LockoutState {
        guard let data = (try? Keychain.read(Self.lockoutAccount)) ?? nil,
              let state = try? JSONDecoder().decode(LockoutState.self, from: data) else { return LockoutState() }
        return state
    }

    private func saveLockout(_ state: LockoutState) {
        if let data = try? JSONEncoder().encode(state) { try? Keychain.set(data, for: Self.lockoutAccount) }
    }
}
