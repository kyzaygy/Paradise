import AppIntents
import Foundation
import NetworkExtension

/// Shortcuts actions. They use the VPN configuration saved by the last connection from the app.
enum TunnelShortcuts {
  enum Failure: Error, CustomLocalizedStringResourceConvertible {
    case notConfigured

    var localizedStringResource: LocalizedStringResource {
      switch self {
      case .notConfigured: return "Open Paradise and connect once first."
      }
    }
  }

  static func manager() async throws -> NETunnelProviderManager {
    let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error = error { continuation.resume(throwing: error) } else { continuation.resume(returning: managers ?? []) }
      }
    }
    guard let manager = managers.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["config"] != nil }) else {
      throw Failure.notConfigured
    }
    return manager
  }

  static func connect() async throws {
    let manager = try await manager()
    if !manager.isEnabled {
      manager.isEnabled = true
      try await manager.saveToPreferences()
      try await manager.loadFromPreferences()
    }
    try manager.connection.startVPNTunnel()
  }

  static func disconnect() async throws {
    let manager = try await manager()
    if manager.isOnDemandEnabled {
      manager.isOnDemandEnabled = false
      try await manager.saveToPreferences()
    }
    manager.connection.stopVPNTunnel()
  }

  static func toggle() async throws -> Bool {
    let manager = try await manager()
    switch manager.connection.status {
    case .connected, .connecting, .reasserting:
      try await disconnect()
      return false
    default:
      try await connect()
      return true
    }
  }
}

struct ConnectParadiseIntent: AppIntent {
  static let title: LocalizedStringResource = "Connect Paradise"
  static let description = IntentDescription("Connects the VPN with the last used server.")

  func perform() async throws -> some IntentResult {
    try await TunnelShortcuts.connect()
    return .result()
  }
}

struct DisconnectParadiseIntent: AppIntent {
  static let title: LocalizedStringResource = "Disconnect Paradise"
  static let description = IntentDescription("Disconnects the VPN.")

  func perform() async throws -> some IntentResult {
    try await TunnelShortcuts.disconnect()
    return .result()
  }
}

struct ToggleParadiseIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle Paradise"
  static let description = IntentDescription("Connects or disconnects the VPN.")

  func perform() async throws -> some IntentResult {
    _ = try await TunnelShortcuts.toggle()
    return .result()
  }
}

struct ParadiseShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: ConnectParadiseIntent(), phrases: ["Connect \(.applicationName)", "Turn on \(.applicationName)"])
    AppShortcut(intent: DisconnectParadiseIntent(), phrases: ["Disconnect \(.applicationName)", "Turn off \(.applicationName)"])
    AppShortcut(intent: ToggleParadiseIntent(), phrases: ["Toggle \(.applicationName)"])
  }
}
