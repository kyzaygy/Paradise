import Foundation
import Security

/// Stores the 32-byte key that encrypts the profile on disk.
/// The item is device-only and readable after the first unlock.
enum Keychain {
  private static let service = "app.paradise.storage"
  private static let account = "profile-key"

  static func storageKey() throws -> Data {
    if let existing = try read() { return existing }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CoreError(code: "storage", detail: "random")
    }
    let key = Data(bytes)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: key,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw CoreError(code: "storage", detail: "keychain \(status)") }
    return key
  }

  private static func read() throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
      throw CoreError(code: "storage", detail: "keychain \(status)")
    }
    return data
  }
}
