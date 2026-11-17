import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import Security

/// The optional privacy lock, and the key that encrypts your stories and chats.
///
/// Everything Phonodeck saves about you is encrypted with one random key (AES-GCM), so a copy of
/// the app's folder or a phone backup can't be read on its own.
/// - No passcode: the key sits in this phone's Keychain and the app opens straight away.
/// - Passcode: the key is kept only wrapped by your passcode, and (if you turn it on) behind
///   Face ID. Without one of them nobody, including you, can read the files.
@Observable
@MainActor
final class Vault {
    /// The key for your files while Phonodeck is unlocked; nil behind the lock screen.
    private(set) var key: SymmetricKey?
    private(set) var hasPasscode: Bool
    private(set) var useFaceID: Bool

    var isLocked: Bool { key == nil }

    /// Set after updating from a version that kept files unencrypted: the passcode is needed once
    /// (Face ID can't be used) to create the key and encrypt them.
    var needsPasscodeOnce: Bool { Keychain.read("secretHash") != nil }

    init() {
        // Older versions had a "demo" passcode that opened a second, empty space. It's gone.
        Keychain.delete("demoHash")
        try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: "Demo", directoryHint: .isDirectory))

        let legacy = Keychain.read("secretHash") != nil
        hasPasscode = legacy || Keychain.read("wrappedKey") != nil
        useFaceID = !legacy && UserDefaults.standard.bool(forKey: "useFaceID")
        if !hasPasscode { key = Self.openKey() }
    }

    // MARK: Unlocking

    /// Returns false when the passcode doesn't match.
    @discardableResult
    func unlock(with code: String) -> Bool {
        if let legacy = Keychain.read("secretHash") {
            guard Self.legacyHash(code) == legacy else { return false }
            let k = SymmetricKey(size: .bits256)
            guard let blob = Self.wrap(k, passcode: code) else { return false }
            Keychain.write("wrappedKey", blob.base64EncodedString())
            Keychain.delete("secretHash")
            key = k
            if UserDefaults.standard.bool(forKey: "useFaceID") { setFaceID(true) }
            return true
        }
        guard let s = Keychain.read("wrappedKey"), let blob = Data(base64Encoded: s),
              let k = Self.unwrap(blob, passcode: code) else { return false }
        key = k
        return true
    }

    func unlockWithFaceID() async -> Bool {
        guard useFaceID else { return false }
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Open your Phonodeck")) ?? false
        guard ok, let raw = Keychain.readProtected("faceIDKey", context: ctx) else { return false }
        key = SymmetricKey(data: raw)
        return true
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

    /// Called when the app goes to the background.
    func lock() {
        if hasPasscode { key = nil }
    }

    // MARK: Changing the lock (only while unlocked)

    /// Sets or changes the passcode; nil removes it (the files stay encrypted with a key kept on the phone).
    func setPasscode(_ code: String?) {
        guard let key else { return }
        if let code, !code.isEmpty {
            guard let blob = Self.wrap(key, passcode: code) else { return }
            Keychain.write("wrappedKey", blob.base64EncodedString())
            Keychain.delete("openKey")
            hasPasscode = true
        } else {
            Keychain.write("openKey", Self.raw(key).base64EncodedString())
            Keychain.delete("wrappedKey")
            setFaceID(false)
            hasPasscode = false
        }
    }

    func setFaceID(_ on: Bool) {
        Keychain.delete("faceIDKey")
        var stored = false
        if on, let key { stored = Keychain.writeProtected("faceIDKey", Self.raw(key)) }
        useFaceID = stored
        UserDefaults.standard.set(stored, forKey: "useFaceID")
    }

    // MARK: Storage

    /// Your chats and experiences.
    static var folder: URL {
        let url = URL.documentsDirectory.appending(path: "Mine", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        return url
    }

    // MARK: Keys

    private static func raw(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    /// The key used when there's no passcode, created on first use.
    private static func openKey() -> SymmetricKey {
        if let s = Keychain.read("openKey"), let d = Data(base64Encoded: s) { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        Keychain.write("openKey", raw(k).base64EncodedString())
        return k
    }

    /// 16 bytes of salt, then the file key sealed with a key derived from the passcode.
    private static func wrap(_ k: SymmetricKey, passcode: String) -> Data? {
        let salt = raw(SymmetricKey(size: .bits128))
        guard let sealed = try? AES.GCM.seal(raw(k), using: derive(passcode, salt: salt)).combined else { return nil }
        return salt + sealed
    }

    private static func unwrap(_ blob: Data, passcode: String) -> SymmetricKey? {
        guard blob.count > 16 else { return nil }
        let salt = Data(blob.prefix(16))
        guard let box = try? AES.GCM.SealedBox(combined: Data(blob.dropFirst(16))),
              let k = try? AES.GCM.open(box, using: derive(passcode, salt: salt)) else { return nil }
        return SymmetricKey(data: k)
    }

    /// PBKDF2-SHA256, slow on purpose so a short passcode can't be guessed quickly from a copied file.
    private static func derive(_ passcode: String, salt: Data) -> SymmetricKey {
        let password = Array(passcode.utf8).map { CChar(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                                     &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    /// How older versions checked the passcode, kept only to recognise it once.
    private static func legacyHash(_ code: String) -> String {
        let salt = "phonodeck.v1."
        return SHA256.hash(data: Data((salt + code).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A tiny Keychain wrapper. Items stay on this device and never go into backups.
enum Keychain {
    private static let service = "Phonodeck"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        var q = base(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    /// Stores a secret that only Face ID (with the faces enrolled now) can read back.
    static func writeProtected(_ key: String, _ value: Data) -> Bool {
        delete(key)
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, nil) else { return false }
        var q = base(key)
        q[kSecValueData as String] = value
        q[kSecAttrAccessControl as String] = access
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Reads a Face ID item using a context that has already passed Face ID, so it doesn't ask again.
    static func readProtected(_ key: String, context: LAContext) -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = context
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}
