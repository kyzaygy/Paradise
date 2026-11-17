import Foundation
import Security

/// Stores the 32-byte key that encrypts the profile on disk.
/// Preferred: Keychain (device-only, after first unlock). Fallback for builds without
/// keychain entitlements (e.g. TrollStore installs): a protected file in the app container.
enum Keychain {
  private static let service = "app.paradise.storage"
  private static let account = "profile-key"

  enum Mode: String { case keychain, file }
  private(set) static var mode: Mode = .keychain
  private(set) static var lastStatus: OSStatus = errSecSuccess

  private static var fileURL: URL {
    Core.dataDirectory.appendingPathComponent(".storage-key")
  }

  static func storageKey() throws -> Data {
    if let data = try? Data(contentsOf: fileURL), data.count == 32 {
      mode = .file
      AppLog.info("storage", "key: file (fallback)")
      return data
    }
    switch read() {
    case .found(let data):
      mode = .keychain
      AppLog.info("storage", "key: keychain")
      return data
    case .missing:
      let key = try random()
      let status = add(key)
      lastStatus = status
      if status == errSecSuccess {
        mode = .keychain
        AppLog.info("storage", "key: keychain (new)")
        return key
      }
      AppLog.warn("storage", "keychain add failed \(status) (\(describe(status))), using file key")
      return try writeFileKey(key)
    case .failed(let status):
      lastStatus = status
      AppLog.warn("storage", "keychain read failed \(status) (\(describe(status))), using file key")
      return try writeFileKey(try random())
    }
  }

  private enum ReadResult { case found(Data), missing, failed(OSStatus) }

  private static func read() -> ReadResult {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return .missing }
    guard status == errSecSuccess, let data = item as? Data, data.count == 32 else { return .failed(status) }
    return .found(data)
  }

  private static func add(_ key: Data) -> OSStatus {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: key,
    ]
    return SecItemAdd(query as CFDictionary, nil)
  }

  private static func random() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CoreError(code: "storage", detail: "random")
    }
    return Data(bytes)
  }

  private static func writeFileKey(_ key: Data) throws -> Data {
    do {
      try FileManager.default.createDirectory(at: Core.dataDirectory, withIntermediateDirectories: true)
      try key.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      var url = fileURL
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
      mode = .file
      return key
    } catch {
      AppLog.error("storage", "file key write failed: \(error.localizedDescription)")
      throw CoreError(code: "storage", detail: "key file")
    }
  }

  static func describe(_ status: OSStatus) -> String {
    if status == -34018 { return "missing keychain entitlement" }
    return (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
  }
}
