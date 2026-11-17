import Foundation
import UIKit

// MARK: - Models mirrored from the Go core (core/internal/engine)

struct CoreMeta: Codable, Hashable {
  var title: String?
  var upload: Int64?
  var download: Int64?
  var total: Int64?
  var expire: Int64?
  var updateHours: Int?
  var supportUrl: String?
  var webUrl: String?
  var announce: String?
}

struct CoreSubscription: Codable, Identifiable, Hashable {
  var id: String
  var name: String
  var host: String?
  var remote: Bool
  var count: Int
  var meta: CoreMeta?
  var updatedAt: String?
  var lastError: String?
  var warnings: Int?

  var displayName: String {
    if !name.isEmpty { return name }
    if let title = meta?.title, !title.isEmpty { return title }
    if let host = host, !host.isEmpty { return host }
    return L("subscription.local")
  }
}

struct CoreServer: Codable, Identifiable, Hashable {
  var id: String
  var key: String
  var subscriptionId: String
  var name: String
  var `protocol`: String
  var address: String
  var port: Int
  var network: String
  var security: String
  var favorite: Bool
  var fullProfile: Bool

  var detail: String {
    var parts = [`protocol`.uppercased()]
    if network != "tcp" { parts.append(network) }
    if security != "none" { parts.append(security) }
    return parts.joined(separator: " · ")
  }
}

struct CoreSettings: Codable, Hashable {
  var mode: String
  var killSwitch: Bool
  var autoRefresh: Bool
  var sendHwid: Bool
  var probeUrl: String
}

struct CoreState: Codable {
  var subscriptions: [CoreSubscription]
  var servers: [CoreServer]
  var selected: String
  var settings: CoreSettings
  var hwid: String

  static let empty = CoreState(subscriptions: [], servers: [], selected: "",
                               settings: CoreSettings(mode: "all", killSwitch: false, autoRefresh: true, sendHwid: true, probeUrl: ""),
                               hwid: "")

  var selectedServer: CoreServer? { servers.first { $0.id == selected } }
}

struct ImportResult: Codable {
  var state: CoreState
  var subscriptionId: String
  var added: Int
  var warnings: Int
}

struct RefreshResult: Codable {
  var state: CoreState
  var errors: [String: String]
}

struct TunnelConfig: Codable {
  var config: String
  var serverId: String
  var serverName: String
  var address: String
  var killSwitch: Bool
  var droppedRules: Int
}

struct ProbeResult: Codable {
  var id: String
  var ms: Int64
}

struct TransferCounts: Codable, Hashable {
  var subscriptions: Int
  var remote: Int
  var servers: Int
  var favorites: Int
}

struct ExportResult: Codable {
  var code: String
  var link: String
  var format: String
  var chars: Int
  var fitsQr: Bool
  var encrypted: Bool
  var expiresAt: Int64?
  var counts: TransferCounts
  var skipped: Int
}

struct PreviewSource: Codable, Hashable {
  var name: String
  var host: String?
  var remote: Bool
  var servers: Int
  var duplicate: Bool
}

struct TransferPreview: Codable {
  var format: String
  var encrypted: Bool
  var locked: Bool
  var expiresAt: Int64?
  var name: String?
  var app: String?
  var created: Int64?
  var counts: TransferCounts
  var sources: [PreviewSource]
  var hasSettings: Bool
  var hasIdentity: Bool
  var skipped: Int
  var duplicates: Int
}

struct ImportTransferResult: Codable {
  var state: CoreState
  var added: Int
  var duplicates: Int
  var invalid: Int
  var pendingRefresh: [String]
}

struct Classification: Codable { var kind: String }

// MARK: - Errors

struct CoreError: Error, LocalizedError, Codable {
  var code: String
  var detail: String?

  var errorDescription: String? { CoreError.message(code: code, detail: detail) }

  static func message(code: String, detail: String? = nil) -> String {
    let key = "error.\(code)"
    let text = L(key)
    if text == key { return L("error.internal") }
    if code == "http_status", let detail = detail, !detail.isEmpty {
      return String(format: L("error.http_status.code"), detail)
    }
    if code == "invalid_input", detail == "duplicate" { return L("error.duplicate") }
    return text
  }
}

private struct Envelope<T: Decodable>: Decodable {
  var ok: Bool
  var data: T?
  var error: CoreError?
}

private struct Empty: Decodable {}

// MARK: - Bridge to the gomobile framework (PDCore.xcframework, package pdcore)

enum Core {
  private static let queue = DispatchQueue(label: "app.paradise.core", qos: .userInitiated, attributes: .concurrent)
  private(set) static var isOpen = false

  static var dataDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Paradise", isDirectory: true)
  }

  static func open() throws {
    if isOpen { return }
    let dir = dataDirectory
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let key = try Keychain.storageKey()
    let device: [String: String] = [
      "platform": "iOS",
      "osVersion": UIDevice.current.systemVersion,
      "model": Device.modelIdentifier,
      "locale": Locale.current.identifier,
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
    ]
    let deviceJSON = String(data: try JSONSerialization.data(withJSONObject: device), encoding: .utf8) ?? "{}"
    let raw: String? = PdcoreOpen(dir.path, key.base64EncodedString(), deviceJSON)
    let envelope = try JSONDecoder().decode(Envelope<Empty>.self, from: Data((raw ?? "").utf8))
    if !envelope.ok { throw envelope.error ?? CoreError(code: "internal", detail: nil) }
    isOpen = true
  }

  /// Deletes the encrypted profile (used when the storage key no longer matches).
  static func eraseData() {
    try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("profile.pdx"))
  }

  static func call<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
    let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
    let raw: String = try await withCheckedThrowingContinuation { continuation in
      queue.async {
        let result: String? = PdcoreCall(method, json)
        continuation.resume(returning: result ?? "")
      }
    }
    let envelope = try JSONDecoder().decode(Envelope<T>.self, from: Data(raw.utf8))
    if envelope.ok, let data = envelope.data { return data }
    throw envelope.error ?? CoreError(code: "internal", detail: "empty")
  }

  static var xrayVersion: String {
    let v: String? = PdcoreVersion()
    return v ?? ""
  }
}

enum Device {
  static var modelIdentifier: String {
    var info = utsname()
    uname(&info)
    let mirror = Mirror(reflecting: info.machine)
    let id = mirror.children.reduce(into: "") { result, element in
      guard let value = element.value as? Int8, value != 0 else { return }
      result.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
    }
    return id.isEmpty ? "iPhone" : id
  }
}
