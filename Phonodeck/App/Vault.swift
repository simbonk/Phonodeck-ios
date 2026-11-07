import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import Security

/// Optional passcodes.
///
/// - No passcode set: the app opens straight to your own space.
/// - Secret passcode (or Face ID): opens your own space, with your chats and experiences.
/// - Demo passcode: opens a separate, empty space to show people. It is wiped every time it is
///   opened, so it always looks like a fresh install. Downloaded models are shared by both.
@Observable
@MainActor
final class Vault {
    enum Space: String { case mine, demo }

    private(set) var unlocked: Space?
    private(set) var hasSecret = Keychain.read("secretHash") != nil
    private(set) var hasDemo = Keychain.read("demoHash") != nil
    var useFaceID: Bool {
        didSet { UserDefaults.standard.set(useFaceID, forKey: "useFaceID") }
    }

    var isLocked: Bool { unlocked == nil }
    var needsPasscode: Bool { hasSecret }

    init() {
        useFaceID = UserDefaults.standard.bool(forKey: "useFaceID")
        if !hasSecret { unlocked = .mine }
    }

    // MARK: Unlocking

    /// Returns false when the passcode matches neither.
    @discardableResult
    func unlock(with code: String) -> Bool {
        let h = Self.hash(code)
        if h == Keychain.read("secretHash") { enter(.mine); return true }
        if h == Keychain.read("demoHash") { enter(.demo); return true }
        return false
    }

    func unlockWithFaceID() async -> Bool {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Open your Phonodeck")) ?? false
        if ok { enter(.mine) }
        return ok
    }

    static var biometryName: String? {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    private func enter(_ space: Space) {
        if space == .demo { Self.wipe(.demo) }
        unlocked = space
    }

    /// Called when the app goes to the background.
    func lock() {
        if hasSecret { unlocked = nil }
    }

    // MARK: Setting passcodes (only from your own space)

    func setSecret(_ code: String?) {
        if let code, !code.isEmpty {
            Keychain.write("secretHash", Self.hash(code))
        } else {
            Keychain.delete("secretHash")
            Keychain.delete("demoHash")   // a demo passcode only makes sense behind a secret one
        }
        hasSecret = Keychain.read("secretHash") != nil
        hasDemo = Keychain.read("demoHash") != nil
    }

    /// Fails (returns false) when it equals the secret passcode.
    @discardableResult
    func setDemo(_ code: String?) -> Bool {
        if let code, !code.isEmpty {
            guard Self.hash(code) != Keychain.read("secretHash") else { return false }
            Keychain.write("demoHash", Self.hash(code))
        } else {
            Keychain.delete("demoHash")
        }
        hasDemo = Keychain.read("demoHash") != nil
        return true
    }

    // MARK: Storage

    /// Each space keeps its chats and experiences in its own folder.
    static func folder(_ space: Space) -> URL {
        let url = URL.documentsDirectory.appending(path: space == .mine ? "Mine" : "Demo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func wipe(_ space: Space) {
        try? FileManager.default.removeItem(at: folder(space))
        _ = folder(space)
    }

    private static func hash(_ code: String) -> String {
        let salt = "phonodeck.v1."
        return SHA256.hash(data: Data((salt + code).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A tiny Keychain wrapper for the passcode hashes.
enum Keychain {
    private static let service = "Phonodeck"

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
