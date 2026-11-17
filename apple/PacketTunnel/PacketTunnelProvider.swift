import Darwin
import NetworkExtension

/// Packet Tunnel: feeds IP packets between NEPacketTunnelFlow and the Xray TUN inbound through a socketpair.
/// Packet path adapted from SVOI (MIT, SVOI contributors), see third_party/SVOI-LICENSE.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let lifecycle = DispatchQueue(label: "app.paradise.tunnel.lifecycle", qos: .userInitiated)
  private var pump: PacketPump?
  private var generation = 0
  private var running = false
  private var memoryTimer: DispatchSourceTimer?
  private let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("xray.log").path

  private func log(_ level: String, _ msg: String) { PdcoreLog(level, "tunnel", msg) }

  private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }

  private func startMemoryLog() {
    memoryTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: lifecycle)
    timer.schedule(deadline: .now() + 5, repeating: 20)
    timer.setEventHandler { [weak self] in
      let mb = Self.footprintMB()
      self?.log(mb > 40 ? "warn" : "info", String(format: "memory footprint %.1f MB (limit ~50 MB)", mb))
    }
    timer.resume()
    memoryTimer = timer
  }

  /// Network options computed by the core (see core/internal/xcfg.Net).
  struct NetOptions: Decodable {
    var mtu: Int?
    var ipv6: Bool?
    var dns: [String]?
    var excluded: [String]?
    var included: [String]?
    var reflect: [String]?
    var keepLogs: Bool?
  }

  private static let defaultExcluded = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "224.0.0.0/4", "fe80::/10", "fc00::/7"]

  static func route4(_ cidr: String) -> NEIPv4Route? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits), parts[0].contains(".") else { return nil }
    let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
    let text = "\((mask >> 24) & 255).\((mask >> 16) & 255).\((mask >> 8) & 255).\(mask & 255)"
    return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: text)
  }

  static func route6(_ cidr: String) -> NEIPv6Route? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, let bits = Int(parts[1]), (0...128).contains(bits), parts[0].contains(":") else { return nil }
    return NEIPv6Route(destinationAddress: String(parts[0]), networkPrefixLength: NSNumber(value: bits))
  }

  // MARK: Traffic statistics (persisted in the extension's defaults)

  private let statsDefaults = UserDefaults.standard
  private var statsTimer: DispatchSourceTimer?
  private var savedUp: UInt64 = 0
  private var savedDown: UInt64 = 0
  private var sessionStart = Date()

  private func flushStats() {
    guard let pump = pump else { return }
    let c = pump.snapshot
    let up = c.up &- savedUp, down = c.down &- savedDown
    savedUp = c.up
    savedDown = c.down
    let totalUp = ((statsDefaults.object(forKey: "stats.totalUp") as? NSNumber)?.uint64Value ?? 0) &+ up
    let totalDown = ((statsDefaults.object(forKey: "stats.totalDown") as? NSNumber)?.uint64Value ?? 0) &+ down
    statsDefaults.set(NSNumber(value: totalUp), forKey: "stats.totalUp")
    statsDefaults.set(NSNumber(value: totalDown), forKey: "stats.totalDown")
  }

  private func statsJSON() -> Data? {
    flushStats()
    let c = pump?.snapshot ?? PacketPump.Counters()
    let json: [String: Any] = [
      "up": NSNumber(value: c.up), "down": NSNumber(value: c.down), "reflected": NSNumber(value: c.reflected),
      "totalUp": (statsDefaults.object(forKey: "stats.totalUp") as? NSNumber) ?? NSNumber(value: 0),
      "totalDown": (statsDefaults.object(forKey: "stats.totalDown") as? NSNumber) ?? NSNumber(value: 0),
      "since": sessionStart.timeIntervalSince1970,
    ]
    return try? JSONSerialization.data(withJSONObject: json)
  }

  private func startStatsTimer() {
    statsTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: lifecycle)
    timer.schedule(deadline: .now() + 15, repeating: 15)
    timer.setEventHandler { [weak self] in self?.flushStats() }
    timer.resume()
    statsTimer = timer
  }

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    lifecycle.async {
      self.generation += 1
      let attempt = self.generation
      self.log("info", String(format: "start requested, footprint %.1f MB", Self.footprintMB()))
      guard let config = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["config"] as? String,
            !config.isEmpty, config.utf8.count <= 4 * 1024 * 1024 else {
        self.log("error", "no configuration in providerConfiguration")
        completionHandler(self.error("No server configuration. Open Paradise and connect again."))
        return
      }
      let providerConfig = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
      var net = NetOptions()
      if let raw = providerConfig?["net"] as? String, let data = raw.data(using: .utf8),
         let decoded = try? JSONDecoder().decode(NetOptions.self, from: data) {
        net = decoded
      }
      if !(net.keepLogs ?? false) {
        try? FileManager.default.removeItem(atPath: self.logPath)
        try? FileManager.default.removeItem(atPath: (self.logPath as NSString).deletingPathExtension + "-access.log")
      }
      self.cleanup()
      let excluded = net.excluded ?? Self.defaultExcluded
      let included = net.included ?? []
      let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
      let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
      ipv4.includedRoutes = [NEIPv4Route.default()] + included.compactMap(Self.route4)
      ipv4.excludedRoutes = excluded.compactMap(Self.route4)
      settings.ipv4Settings = ipv4
      let ipv6 = NEIPv6Settings(addresses: ["fd70:6172:6164::1"], networkPrefixLengths: [126])
      ipv6.includedRoutes = [NEIPv6Route.default()] + included.compactMap(Self.route6)
      ipv6.excludedRoutes = excluded.compactMap(Self.route6)
      settings.ipv6Settings = ipv6
      let servers = (net.dns ?? []).isEmpty ? ["1.1.1.1", "8.8.8.8"] : (net.dns ?? [])
      let dns = NEDNSSettings(servers: servers)
      dns.matchDomains = [""]
      settings.dnsSettings = dns
      let mtu = net.mtu ?? 1500
      settings.mtu = NSNumber(value: (1280...9000).contains(mtu) ? mtu : 1500)
      self.log("info", "network: mtu \(mtu), dns \(servers.count), excluded \(excluded.count), included \(included.count), reflect \(net.reflect?.count ?? 0)")
      self.setTunnelNetworkSettings(settings) { error in
        self.lifecycle.async {
          guard attempt == self.generation else {
            completionHandler(self.error("Cancelled"))
            return
          }
          if let error = error {
            self.log("error", "setTunnelNetworkSettings failed: \(error.localizedDescription)")
            completionHandler(error)
            return
          }
          var fds: [Int32] = [-1, -1]
          do {
            guard Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
              throw self.error("socketpair failed: \(errno)")
            }
            var size: Int32 = 256 * 1024
            for fd in fds {
              _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
              _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            }
            guard fcntl(fds[1], F_SETFL, O_NONBLOCK) != -1 else { throw self.error("fcntl failed: \(errno)") }
            var on: Int32 = 1
            _ = setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let result: String? = PdcoreStartTunnel(config, fds[0], self.logPath)
            if let failure = result, !failure.isEmpty { throw self.error(failure) }
            self.startMemoryLog()
            self.running = true
            Darwin.close(fds[0])
            fds[0] = -1
            let pump = PacketPump(flow: self.packetFlow, descriptor: fds[1], reflect: net.reflect ?? []) { [weak self] in
              guard let self = self else { return }
              self.lifecycle.async {
                guard self.generation == attempt else { return }
                self.log("error", "packet channel stopped")
                self.cleanup()
                self.cancelTunnelWithError(self.error("Packet channel stopped"))
              }
            }
            fds[1] = -1
            self.pump = pump
            self.savedUp = 0
            self.savedDown = 0
            self.sessionStart = Date()
            pump.start()
            self.startStatsTimer()
            self.log("info", String(format: "tunnel up, footprint %.1f MB", Self.footprintMB()))
            completionHandler(nil)
          } catch {
            self.log("error", "start failed: \(error.localizedDescription)")
            for fd in fds where fd >= 0 { Darwin.close(fd) }
            self.cleanup()
            completionHandler(error)
          }
        }
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    lifecycle.async {
      self.log("info", "stop requested, reason \(reason.rawValue)")
      self.generation += 1
      self.cleanup()
      completionHandler()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    lifecycle.async {
      let request = String(data: messageData, encoding: .utf8) ?? ""
      if request == "stats" {
        completionHandler?(self.statsJSON())
        return
      }
      if request == "clearLogs" {
        PdcoreClearTunnelLogs(self.logPath)
        completionHandler?(Data("ok".utf8))
        return
      }
      if request == "resetStats" {
        self.flushStats()
        self.statsDefaults.set(0, forKey: "stats.totalUp")
        self.statsDefaults.set(0, forKey: "stats.totalDown")
        completionHandler?(Data("ok".utf8))
        return
      }
      if request == "logs" {
        let raw: String? = PdcoreTunnelLogs(self.logPath)
        var json = (try? JSONSerialization.jsonObject(with: Data((raw ?? "{}").utf8))) as? [String: Any] ?? [:]
        json["footprintMB"] = Self.footprintMB()
        completionHandler?(try? JSONSerialization.data(withJSONObject: json))
        return
      }
      let stats: String? = PdcoreMemoryStats()
      let version: String? = PdcoreVersion()
      let text = String(format: "xray %@ · footprint %.1f MB · %@", version ?? "", Self.footprintMB(), stats ?? "")
      completionHandler?(Data(text.utf8))
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }

  override func wake() {}

  private func cleanup() {
    memoryTimer?.cancel()
    memoryTimer = nil
    statsTimer?.cancel()
    statsTimer = nil
    flushStats()
    pump?.stop()
    pump = nil
    if running {
      _ = PdcoreStopTunnel()
      running = false
    }
  }

  private func error(_ message: String) -> NSError {
    NSError(domain: "app.paradise.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
