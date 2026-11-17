import Foundation
import Security

/// Configuración de la sincronización: URL del Worker y token compartido.
/// La URL vive en `UserDefaults` (no es secreta); el token, en el Keychain.
enum SyncConfig {
    private static let urlKey = "sync.workerURL"
    private static let keychainService = "com.simon.moodboard.sync"
    private static let keychainAccount = "token"

    /// URL base del Worker (sin barra final), p. ej. https://moodboard-sync.xxx.workers.dev
    static var workerURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed,
                                      forKey: urlKey)
        }
    }

    static var token: String {
        get { readToken() ?? "" }
        set { writeToken(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static var isConfigured: Bool {
        !workerURL.isEmpty && !token.isEmpty && URL(string: workerURL) != nil
    }

    /// Enlace público del visor web para un token compartido.
    static func publicURL(token: String) -> URL? {
        URL(string: workerURL + "/s/" + token)
    }

    /// Última revisión del documento que este equipo conoce (para el control optimista).
    static var knownRevision: Int {
        get { UserDefaults.standard.integer(forKey: "sync.revision") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.revision") }
    }

    // MARK: - Keychain

    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeToken(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
