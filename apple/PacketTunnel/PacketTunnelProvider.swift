import Darwin
import NetworkExtension

/// Packet Tunnel: feeds IP packets between NEPacketTunnelFlow and the Xray TUN inbound through a socketpair.
/// Packet path adapted from SVOI (MIT, SVOI contributors), see third_party/SVOI-LICENSE.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let lifecycle = DispatchQueue(label: "app.paradise.tunnel.lifecycle", qos: .userInitiated)
  private var pump: PacketPump?
  private var generation = 0
  private var running = false

  private static let excluded4: [(String, String)] = [
    ("10.0.0.0", "255.0.0.0"), ("172.16.0.0", "255.240.0.0"), ("192.168.0.0", "255.255.0.0"),
    ("169.254.0.0", "255.255.0.0"), ("100.64.0.0", "255.192.0.0"), ("224.0.0.0", "240.0.0.0"),
  ]

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    lifecycle.async {
      self.generation += 1
      let attempt = self.generation
      guard let config = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["config"] as? String,
            !config.isEmpty, config.utf8.count <= 4 * 1024 * 1024 else {
        completionHandler(self.error("No server configuration. Open Paradise and connect again."))
        return
      }
      self.cleanup()
      let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
      let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
      ipv4.includedRoutes = [NEIPv4Route.default()]
      ipv4.excludedRoutes = Self.excluded4.map { NEIPv4Route(destinationAddress: $0.0, subnetMask: $0.1) }
      settings.ipv4Settings = ipv4
      let ipv6 = NEIPv6Settings(addresses: ["fd70:6172:6164::1"], networkPrefixLengths: [126])
      ipv6.includedRoutes = [NEIPv6Route.default()]
      ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10),
                             NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7)]
      settings.ipv6Settings = ipv6
      let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
      dns.matchDomains = [""]
      settings.dnsSettings = dns
      settings.mtu = 1500
      self.setTunnelNetworkSettings(settings) { error in
        self.lifecycle.async {
          guard attempt == self.generation else {
            completionHandler(self.error("Cancelled"))
            return
          }
          if let error = error {
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
            let result: String? = PdcoreStartTunnel(config, fds[0])
            if let failure = result, !failure.isEmpty { throw self.error(failure) }
            self.running = true
            Darwin.close(fds[0])
            fds[0] = -1
            let pump = PacketPump(flow: self.packetFlow, descriptor: fds[1]) { [weak self] in
              guard let self = self else { return }
              self.lifecycle.async {
                guard self.generation == attempt else { return }
                self.cleanup()
                self.cancelTunnelWithError(self.error("Packet channel stopped"))
              }
            }
            fds[1] = -1
            self.pump = pump
            pump.start()
            completionHandler(nil)
          } catch {
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
      self.generation += 1
      self.cleanup()
      completionHandler()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    lifecycle.async {
      let stats: String? = PdcoreMemoryStats()
      let version: String? = PdcoreVersion()
      let text = "xray \(version ?? "") · \(stats ?? "")"
      completionHandler?(Data(text.utf8))
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }

  override func wake() {}

  private func cleanup() {
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
