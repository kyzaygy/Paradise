import Foundation
import NetworkExtension

/// Reproducible screens for the simulator: launch with `-ParadiseDemo <scenario>`.
/// The demo keeps its data in a temporary folder, imports fixture servers (documentation
/// addresses 203.0.113.0/24 and 198.51.100.0/24, generated keys), uses fixed latencies and
/// makes no network requests. The tunnel state is simulated because the simulator has no
/// Network Extension.
enum Demo {
  enum Scenario: String, CaseIterable {
    case reference, connecting, connected, empty, long, full, collapsed, search, favorites, routes
  }

  static let scenario: Scenario? = UserDefaults.standard.string(forKey: "ParadiseDemo").flatMap(Scenario.init(rawValue:))
  /// `-ParadiseDemoKeep YES` keeps the demo profile from the previous launch (persistence checks).
  static let keep = UserDefaults.standard.bool(forKey: "ParadiseDemoKeep")
  /// `-ParadiseDemoMotion YES` keeps the space animated (the demo is still otherwise, for screenshots and tests).
  static let motion = UserDefaults.standard.bool(forKey: "ParadiseDemoMotion")

  static var initialDetent: ServerPanel.Detent {
    switch scenario {
    case .full, .search, .long: return .full
    case .collapsed: return .collapsed
    default: return .standard
    }
  }

  static var initialSection: ServerPanel.Section {
    switch scenario {
    case .favorites: return .favorites
    case .routes: return .routes
    default: return .servers
    }
  }

  static var initialQuery: String { scenario == .search ? "an" : "" }

  static var directory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ParadiseDemo", isDirectory: true)
  }

  struct Fixture {
    let name: String
    let ms: Int64?
    let link: (Int) -> String
  }

  /// The eleven countries of the mock. Latency is the same number on the map and in the list.
  static let fixtures: [Fixture] = [
    wg("🇩🇪 Frankfurt · 10 Gbps", 24), wg("🇳🇱 Amsterdam · 10 Gbps", 28), wg("🇬🇧 London · 10 Gbps", 42),
    wg("🇫🇷 Paris · 10 Gbps", 51), wg("🇺🇸 New York · 10 Gbps", 76), wg("🇨🇦 Toronto · 10 Gbps", 108),
    wg("🇷🇺 Moscow · 10 Gbps", 96), wg("🇹🇷 Istanbul · 10 Gbps", 69), wg("🇧🇷 Sao Paulo · 10 Gbps", 182),
    wg("🇸🇬 Singapore · 10 Gbps", 237), wg("🇦🇺 Sydney · 10 Gbps", 289),
  ]

  /// Extra servers for the long-names scenario: long labels, unknown country, other protocols.
  static let extras: [Fixture] = [
    wg("🇧🇦 Premium Ultra Low Latency Residential Node #12", 131),
    wg("🇨🇫 Bangui Backup · 1 Gbps", nil),
    Fixture(name: "Server without a country", ms: 143) { n in
      "vless://3f6b8c1e-2d4a-4e7b-9a10-5c2d8e6f7a90@198.51.100.\(n):443?security=reality&sni=www.example.com&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=01&fp=chrome&type=tcp&flow=xtls-rprx-vision&encryption=none#" + escape("Server without a country")
    },
    Fixture(name: "🇩🇪 Франкфурт #2", ms: 33) { n in
      "trojan://demo-password@198.51.100.\(n):443?security=tls&sni=www.example.com&type=tcp#" + escape("🇩🇪 Франкфурт #2")
    },
    Fixture(name: "🇯🇵 Tokyo", ms: 164) { n in
      "hysteria2://demo-password@198.51.100.\(n):443?sni=www.example.com#" + escape("🇯🇵 Tokyo")
    },
  ]

  private static func wg(_ name: String, _ ms: Int64?) -> Fixture {
    Fixture(name: name, ms: ms) { n in
      let secret = Data((0..<32).map { UInt8(($0 * 7 + n) & 0xFF) }).base64EncodedString()
      let peer = Data((0..<32).map { UInt8(($0 * 13 + n * 3 + 1) & 0xFF) }).base64EncodedString()
      return "wireguard://\(escape(secret))@203.0.113.\(n):51820?publickey=\(escape(peer))&address=10.66.0.\(n)/32&mtu=1420#" + escape(name)
    }
  }

  private static func escape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
  }

  static let notice = AppModel.Notice(id: "demo", kind: .announce, title: "Paradise", body: L("demo.notice"), link: nil)

  static let homeIP = (ip: "212.109.219.74", cc: "EE", city: "Tallinn")

  /// Written when the scenario is on screen; the screenshot script waits for it.
  static func markReady() {
    guard let scenario = scenario else { return }
    try? Data(scenario.rawValue.utf8).write(to: directory.appendingPathComponent("ready"))
  }

  /// Starts every demo launch from an empty profile unless asked to keep it.
  static func resetData(for scenario: Scenario) {
    guard !keep else { return }
    try? FileManager.default.removeItem(at: directory)
  }

  @MainActor
  static func load(_ scenario: Scenario, into model: AppModel) async {
    var list = scenario == .empty ? [] : fixtures
    if scenario == .long { list += extras }
    if keep, let saved: CoreState = try? await Core.call("state"), !saved.servers.isEmpty {
      model.state = saved
      list = []
    }
    if !list.isEmpty {
      let text = list.enumerated().map { $0.element.link($0.offset + 10) }.joined(separator: "\n")
      do {
        let result: ImportResult = try await Core.call("importText", ["text": text])
        model.state = result.state
      } catch {
        model.show(error)
      }
    }
    if scenario == .favorites || scenario == .connected {
      for server in model.state.servers where ["DE", "NL", "SG"].contains(server.cc ?? "") {
        if let next: CoreState = try? await Core.call("setFavorite", ["key": server.key, "favorite": true]) { model.state = next }
      }
    }
    applyLatency(to: model, servers: model.state.servers)
    setHome(model)
    model.vpn.demoSet(.disconnected)
    switch scenario {
    case .connected:
      if let server = model.state.servers.first(where: { $0.cc == "DE" }) {
        if let next: CoreState = try? await Core.call("select", ["id": server.id]) { model.state = next }
        model.vpn.demoSet(.connected, serverID: server.id, since: Date().addingTimeInterval(-754))
        statusChanged(.connected, model: model)
      }
    case .connecting:
      if let server = model.state.servers.first(where: { $0.cc == "NL" }) {
        if let next: CoreState = try? await Core.call("select", ["id": server.id]) { model.state = next }
        model.vpn.demoSet(.connecting, serverID: server.id)
      }
    default:
      break
    }
  }

  /// Fixed latencies by server name (the same value feeds the map and the list).
  @MainActor
  static func applyLatency(to model: AppModel, servers: [CoreServer]) {
    let table = Dictionary((fixtures + extras).map { ($0.name, $0.ms) }, uniquingKeysWith: { a, _ in a })
    for server in servers {
      if let entry = table[server.name] {
        model.latency[server.id] = entry.map { AppModel.Latency.ms($0) } ?? AppModel.Latency.failed
      }
    }
  }

  @MainActor
  static func statusChanged(_ status: NEVPNStatus, model: AppModel) {
    switch status {
    case .connected, .reasserting:
      if let server = model.state.servers.first(where: { $0.id == model.vpn.connectedServerID }) {
        model.publicIP = server.address
        model.publicCountry = server.cc
        model.publicCity = server.city
      }
      model.rateDown = 4_718_592
      model.rateUp = 389_120
    case .disconnected, .invalid:
      setHome(model)
      model.rateDown = 0
      model.rateUp = 0
    default:
      break
    }
  }

  @MainActor
  private static func setHome(_ model: AppModel) {
    model.publicIP = homeIP.ip
    model.publicCountry = homeIP.cc
    model.publicCity = homeIP.city
  }
}
