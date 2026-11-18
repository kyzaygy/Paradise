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
  var cc: String?
  var city: String?
  var region: String?
  var desc: String?
  var fragment: Bool?
  var bandwidth: String?
  var label: String?

  var detail: String {
    var parts = [`protocol`.uppercased()]
    if network != "tcp" { parts.append(network) }
    if security != "none" { parts.append(security) }
    return parts.joined(separator: " · ")
  }
}

struct CoreSettings: Codable, Hashable {
  var mode: String = "all"
  var activeConfig: String?
  var killSwitch: Bool = false
  var autoRefresh: Bool = true
  var refreshHours: Int = 0
  var sendHwid: Bool = true
  var probeUrl: String = ""
  var testMethod: String = "tcp"
  var mtu: Int = 1500
  var ipv6: Bool = true
  var dns: [String] = ["1.1.1.1", "8.8.8.8"]
  var excludeLocal: Bool = true
  var excludeApns: Bool = true
  var sniffing: Bool = true
  var tcpFastOpen: Bool = false
  var keepAlive: Int = 0
  var mux: Bool = false
  var udpRelay: Bool = true
  var blockQuic: Bool = false
  var proxyShare: Bool = false
  var proxyPort: Int = 1080
  var proxyLan: Bool = false
  var fragment: Bool = false
  var fragmentPackets: String = "tlshello"
  var fragmentLength: String = "100-200"
  var fragmentInterval: String = "10-20"
  var logLevel: String = "warning"
  var dnsLog: Bool = false
  var connectionLog: Bool = false
  var autoDeleteLogs: Bool = true
  var hideVpnIcon: Bool = false
  var loopbackRoute: Bool = false
  var overwriteExisting: Bool = false
  var autoRename: Bool = true
  var geoipUrl: String = ""
  var geositeUrl: String = ""
  var autoUpdateConfigs: Bool = true
  var subUserAgent: String = ""
  var locateServers: Bool = true

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = CoreSettings()
    func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
    mode = v(.mode, d.mode)
    activeConfig = try? c.decodeIfPresent(String.self, forKey: .activeConfig)
    killSwitch = v(.killSwitch, d.killSwitch)
    autoRefresh = v(.autoRefresh, d.autoRefresh)
    refreshHours = v(.refreshHours, d.refreshHours)
    sendHwid = v(.sendHwid, d.sendHwid)
    probeUrl = v(.probeUrl, d.probeUrl)
    testMethod = v(.testMethod, d.testMethod)
    mtu = v(.mtu, d.mtu)
    ipv6 = v(.ipv6, d.ipv6)
    dns = v(.dns, d.dns)
    excludeLocal = v(.excludeLocal, d.excludeLocal)
    excludeApns = v(.excludeApns, d.excludeApns)
    sniffing = v(.sniffing, d.sniffing)
    tcpFastOpen = v(.tcpFastOpen, d.tcpFastOpen)
    keepAlive = v(.keepAlive, d.keepAlive)
    mux = v(.mux, d.mux)
    udpRelay = v(.udpRelay, d.udpRelay)
    blockQuic = v(.blockQuic, d.blockQuic)
    proxyShare = v(.proxyShare, d.proxyShare)
    proxyPort = v(.proxyPort, d.proxyPort)
    proxyLan = v(.proxyLan, d.proxyLan)
    fragment = v(.fragment, d.fragment)
    fragmentPackets = v(.fragmentPackets, d.fragmentPackets)
    fragmentLength = v(.fragmentLength, d.fragmentLength)
    fragmentInterval = v(.fragmentInterval, d.fragmentInterval)
    logLevel = v(.logLevel, d.logLevel)
    dnsLog = v(.dnsLog, d.dnsLog)
    connectionLog = v(.connectionLog, d.connectionLog)
    autoDeleteLogs = v(.autoDeleteLogs, d.autoDeleteLogs)
    hideVpnIcon = v(.hideVpnIcon, d.hideVpnIcon)
    loopbackRoute = v(.loopbackRoute, d.loopbackRoute)
    overwriteExisting = v(.overwriteExisting, d.overwriteExisting)
    autoRename = v(.autoRename, d.autoRename)
    geoipUrl = v(.geoipUrl, d.geoipUrl)
    geositeUrl = v(.geositeUrl, d.geositeUrl)
    autoUpdateConfigs = v(.autoUpdateConfigs, d.autoUpdateConfigs)
    subUserAgent = v(.subUserAgent, d.subUserAgent)
    locateServers = v(.locateServers, d.locateServers)
  }
}

struct CoreConfig: Codable, Identifiable, Hashable {
  var id: String
  var name: String
  var host: String?
  var remote: Bool
  var builtin: Bool
  var provided: Bool
  var active: Bool
  var rules: Int
  var updatedAt: String?
  var lastError: String?
}

struct CoreCountry: Codable, Identifiable, Hashable {
  var cc: String
  var region: String
  var lat: Double
  var lon: Double
  var servers: Int
  var id: String { cc.isEmpty ? "??" : cc }
}

struct CoreState: Codable {
  var subscriptions: [CoreSubscription]
  var servers: [CoreServer]
  var selected: String
  var settings: CoreSettings
  var hwid: String
  var configs: [CoreConfig]
  var countries: [CoreCountry]

  static let empty = CoreState(subscriptions: [], servers: [], selected: "", settings: CoreSettings(), hwid: "", configs: [], countries: [])

  init(subscriptions: [CoreSubscription], servers: [CoreServer], selected: String, settings: CoreSettings, hwid: String, configs: [CoreConfig], countries: [CoreCountry]) {
    self.subscriptions = subscriptions
    self.servers = servers
    self.selected = selected
    self.settings = settings
    self.hwid = hwid
    self.configs = configs
    self.countries = countries
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    subscriptions = try c.decode([CoreSubscription].self, forKey: .subscriptions)
    servers = try c.decode([CoreServer].self, forKey: .servers)
    selected = try c.decode(String.self, forKey: .selected)
    settings = try c.decode(CoreSettings.self, forKey: .settings)
    hwid = (try? c.decodeIfPresent(String.self, forKey: .hwid)) ?? ""
    configs = (try? c.decodeIfPresent([CoreConfig].self, forKey: .configs)) ?? []
    countries = (try? c.decodeIfPresent([CoreCountry].self, forKey: .countries)) ?? []
  }

  var selectedServer: CoreServer? { servers.first { $0.id == selected } }
  var activeConfig: CoreConfig? { configs.first { $0.active } }
}

struct ConfigWarning: Codable, Hashable {
  var line: Int
  var code: String
  var text: String?
}

struct ConfigStats: Codable, Hashable {
  var rules: Int
  var domains: Int
  var ips: Int
}

struct ConfigReport: Codable {
  var warnings: [ConfigWarning]
  var ignored: [String]
  var stats: ConfigStats
  var missingGeo: [String]?
  var missingSets: [String]?
  var geoCodes: [String]?
  var sets: [String]?
  var dnsHijack: Bool
  var final: String
  var valid: Bool
  var error: String?
}

struct ConfigDetail: Codable {
  var config: CoreConfig
  var text: String
  var report: ConfigReport
}

struct ConfigSaveResult: Codable {
  var state: CoreState
  var id: String
  var report: ConfigReport
}

struct GeoFileStatus: Codable, Hashable {
  var present: Bool
  var bytes: Int64
  var codes: Int
  var updatedAt: String?
}

struct GeoStatus: Codable {
  var ip: GeoFileStatus
  var site: GeoFileStatus
  var ipUrl: String
  var siteUrl: String
}

struct ExportServersResult: Codable {
  var text: String
  var format: String
  var count: Int
  var skipped: Int
  var fileName: String
}

struct ImportResult: Codable {
  var state: CoreState
  var kind: String?
  var subscriptionId: String?
  var configId: String?
  var added: Int
  var replaced: Int?
  var duplicates: Int?
  var warnings: Int
}

struct RefreshResult: Codable {
  var state: CoreState
  var errors: [String: String]
}

struct TunnelConfig: Codable {
  var config: String
  var net: String?
  var serverId: String
  var serverName: String
  var address: String
  var killSwitch: Bool
  var excludeLocal: Bool?
  var excludeApns: Bool?
  var droppedRules: Int
  var mode: String?
  var configName: String?
  var ruleWarnings: Int?
  var missingGeo: [String]?
}

struct ProbeResult: Codable {
  var id: String
  var ms: Int64
  var method: String?
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
    if code == "unsupported_format", detail == "happ-crypt" { return L("error.happ_crypt") }
    if code == "invalid_input", detail == "builtin" { return L("error.builtin_config") }
    if ["tunnel", "tunnel_stopped", "storage", "config", "network", "empty_subscription", "unsupported_format"].contains(code), let detail = detail, !detail.isEmpty {
      return text + " (" + detail + ")"
    }
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
    if Demo.scenario != nil { return Demo.directory }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Paradise", isDirectory: true)
  }

  private(set) static var openError: Error?

  static func open() throws {
    if isOpen { return }
    do {
      try openCore()
      openError = nil
    } catch {
      openError = error
      AppLog.error("core", "open failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)") [\((error as? CoreError)?.detail ?? "")]")
      throw error
    }
  }

  private static func openCore() throws {
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
    AppLog.info("core", "opened (key: \(Keychain.mode.rawValue))")
  }

  /// Deletes the encrypted profile (used when the storage key no longer matches).
  static func eraseData() {
    try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("profile.pdx"))
  }

  static func call<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
    if !isOpen {
      do { try open() } catch {
        AppLog.error("core", "\(method): core is not open")
        throw error
      }
    }
    let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
    let started = Date()
    let raw: String = await withCheckedContinuation { continuation in
      queue.async {
        let result: String? = PdcoreCall(method, json)
        continuation.resume(returning: result ?? "")
      }
    }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    if ms > 800 && method != "probe" && method != "selfTest" && !method.hasPrefix("refresh") && method != "addSubscription" && method != "testFetch" {
      AppLog.warn("perf", "\(method) took \(ms) ms")
    }
    let envelope: Envelope<T>
    do {
      envelope = try JSONDecoder().decode(Envelope<T>.self, from: Data(raw.utf8))
    } catch {
      AppLog.error("core", "\(method): cannot decode response (\(String(describing: error).prefix(300)))")
      throw CoreError(code: "internal", detail: "decode \(method)")
    }
    if envelope.ok, let data = envelope.data { return data }
    let err = envelope.error ?? CoreError(code: "internal", detail: "empty \(method)")
    if err.code != "cancelled" { AppLog.warn("core", "\(method) → \(err.code) \(err.detail ?? "")") }
    throw err
  }

  static func log(_ level: String, _ source: String, _ msg: String) {
    guard isOpen else { return }
    PdcoreLog(level, source, msg)
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
