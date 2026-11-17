import Foundation
import NetworkExtension

/// Manages the Packet Tunnel configuration and its connection state.
/// Connection flow adapted from SVOI (MIT, SVOI contributors), see third_party/SVOI-LICENSE.
@MainActor
final class VPNController: ObservableObject {
  @Published private(set) var status: NEVPNStatus = .invalid
  @Published private(set) var connectedServerID = ""
  @Published private(set) var connectedDate: Date?
  @Published private(set) var busy = false

  private var manager: NETunnelProviderManager?
  private var observer: NSObjectProtocol?
  private var attempt = 0

  var isConnected: Bool { status == .connected || status == .reasserting }
  var isActive: Bool { isConnected || status == .connecting || status == .disconnecting }

  init() {
    observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  deinit {
    if let observer = observer { NotificationCenter.default.removeObserver(observer) }
  }

  func load() async {
    try? await loadManager()
  }

  private func providerID() throws -> String {
    guard let directory = Bundle.main.builtInPlugInsURL,
          let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
          let url = urls.first(where: { $0.pathExtension == "appex" }),
          let identifier = Bundle(url: url)?.bundleIdentifier else {
      throw CoreError(code: "tunnel_missing", detail: nil)
    }
    return identifier
  }

  private func loadManager() async throws {
    let identifier = try providerID()
    let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error = error { continuation.resume(throwing: error) } else { continuation.resume(returning: managers ?? []) }
      }
    }
    manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier }
    refresh()
  }

  private func refresh() {
    status = manager?.connection.status ?? .invalid
    connectedDate = isConnected ? manager?.connection.connectedDate : nil
    connectedServerID = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["serverId"] as? String ?? ""
  }

  func connect(_ tunnel: TunnelConfig) async throws {
    guard !busy else { return }
    busy = true
    attempt += 1
    let current = attempt
    defer { busy = false; refresh() }
    do {
      try await loadManager()
      if isActive { try await stopAndWait() }
      guard current == attempt else { throw CancellationError() }
      let manager = self.manager ?? NETunnelProviderManager()
      self.manager = manager
      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = try providerID()
      proto.serverAddress = tunnel.address.isEmpty ? "Paradise" : tunnel.address
      proto.providerConfiguration = ["config": tunnel.config, "serverId": tunnel.serverId, "serverName": tunnel.serverName]
      proto.disconnectOnSleep = false
      proto.includeAllNetworks = tunnel.killSwitch
      proto.excludeLocalNetworks = true
      manager.protocolConfiguration = proto
      manager.localizedDescription = "Paradise"
      manager.isEnabled = true
      manager.isOnDemandEnabled = false
      try await save(manager)
      guard current == attempt else { throw CancellationError() }
      try manager.connection.startVPNTunnel()
      for tick in 0..<250 {
        refresh()
        if isConnected { return }
        guard current == attempt else { throw CancellationError() }
        if tick > 15 && (status == .disconnected || status == .invalid) {
          throw CoreError(code: "tunnel_stopped", detail: nil)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      manager.connection.stopVPNTunnel()
      throw CoreError(code: "tunnel_timeout", detail: nil)
    } catch let error as NSError where error.domain == NEVPNErrorDomain {
      if error.code == NEVPNError.Code.configurationReadWriteFailed.rawValue || error.code == 5 {
        throw CoreError(code: "tunnel_permission", detail: nil)
      }
      throw CoreError(code: "tunnel", detail: error.localizedDescription)
    }
  }

  private func save(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.saveToPreferences { error in
        if let error = error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.loadFromPreferences { error in
        if let error = error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  func disconnect() async {
    attempt += 1
    try? await stopAndWait()
    refresh()
  }

  private func stopAndWait() async throws {
    guard let manager = manager else { return }
    manager.connection.stopVPNTunnel()
    for _ in 0..<100 {
      refresh()
      if status == .invalid || status == .disconnected { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  /// Asks the extension for diagnostics (memory, core version).
  func diagnostics() async -> String {
    guard let session = manager?.connection as? NETunnelProviderSession, isConnected else { return "" }
    return await withCheckedContinuation { continuation in
      do {
        try session.sendProviderMessage(Data("diag".utf8)) { data in
          continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
      } catch {
        continuation.resume(returning: "")
      }
    }
  }
}
