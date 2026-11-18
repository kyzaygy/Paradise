import Combine
import Foundation
import Network
import NetworkExtension
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
  enum Sheet: Identifiable {
    case subscriptions, add, export, diagnostics, notifications, controlCenter
    case preview(String)

    var id: String {
      switch self {
      case .subscriptions: return "subscriptions"
      case .add: return "add"
      case .export: return "export"
      case .diagnostics: return "diagnostics"
      case .notifications: return "notifications"
      case .controlCenter: return "controlCenter"
      case .preview(let code): return "preview-\(code.hashValue)"
      }
    }
  }

  enum Latency: Equatable {
    case testing
    case ms(Int64)
    case failed

    var value: Int64? {
      if case .ms(let v) = self { return v }
      return nil
    }
  }

  struct Banner: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
  }

  struct Notice: Identifiable, Hashable {
    enum Kind { case announce, expiry, traffic, error, geo }
    let id: String
    let kind: Kind
    let title: String
    let body: String
    var link: String?
  }

  /// A country on the map: aggregated servers and the best latency.
  struct CountryNode: Identifiable, Equatable {
    var cc: String
    var region: String
    var lat: Double
    var lon: Double
    var servers: [CoreServer]
    var best: Int64?
    var testing: Bool
    var id: String { cc.isEmpty ? "??" : cc }
  }

  @Published var state = CoreState.empty
  @Published var latency: [String: Latency] = [:]
  @Published var banner: Banner?
  @Published var loading = true
  @Published var refreshing = false
  @Published var probing = false
  @Published var sheet: Sheet?
  @Published var controlSection: ControlCenterView.Section = .settings
  @Published var scrollTarget: String?
  @Published var storageBroken = false
  @Published var online = true
  @Published var publicIP: String?
  @Published var publicCountry: String?
  @Published var publicCity: String?
  @Published var traffic: TrafficStats?
  @Published var rateUp: Double = 0
  @Published var rateDown: Double = 0
  @Published var geo: GeoStatus?

  let vpn = VPNController()
  let prefs = AppPrefs.shared
  /// Screenshot scenario from the `-ParadiseDemo` launch argument (nil in normal use).
  let demo = Demo.scenario
  private var locateTask: Task<Void, Never>?
  private let monitor = NWPathMonitor()
  private var probeTask: Task<Void, Never>?
  private var statsTask: Task<Void, Never>?
  private var ipTask: Task<Void, Never>?
  private var started = false
  private var physicalInterface: String?
  private var userDisconnecting = false
  private var lastStatus: NEVPNStatus = .invalid
  private var statusSubscription: AnyCancellable?

  // MARK: Lifecycle

  func start() async {
    guard !started else { return }
    started = true
    HangDetector.shared.start()
    AppLog.info("app", DiagnosticsView.deviceLine())
    monitor.pathUpdateHandler = { [weak self] path in
      let iface = path.availableInterfaces.first { $0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet }?.name
      let up = path.status == .satisfied
      Task { @MainActor in
        self?.online = up
        self?.physicalInterface = iface
      }
    }
    monitor.start(queue: DispatchQueue(label: "app.paradise.path"))
    statusSubscription = vpn.$status
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        Task { @MainActor in self?.vpnStatusChanged(status) }
      }
    if let demo = demo { Demo.resetData(for: demo) }
    let opened = await Task.detached(priority: .userInitiated) { Result { try Core.open() } }.value
    do {
      try opened.get()
    } catch let error as CoreError where error.code == "storage" {
      AppLog.error("app", "storage unavailable: \(error.detail ?? "")")
      storageBroken = true
      loading = false
      return
    } catch {
      show(error)
      loading = false
      return
    }
    if let demo = demo {
      await Demo.load(demo, into: self)
      lastStatus = vpn.status
      loading = false
      Demo.markReady()
      return
    }
    await reload()
    await vpn.load()
    lastStatus = vpn.status
    loading = false
    AppLog.info("app", "ready: \(state.subscriptions.count) subscriptions, \(state.servers.count) servers, vpn \(VPNController.name(vpn.status))")
    refreshIPInfo()
    if vpn.isConnected { startStatsPolling() }
    locateServers()
    if state.settings.autoRefresh, state.subscriptions.contains(where: { $0.remote }) {
      await refreshAll(silent: true)
    }
    if prefs.probeOnLaunch, !state.servers.isEmpty {
      probe(state.servers)
    }
    if state.settings.autoUpdateConfigs {
      await updateRemoteConfigs()
    }
  }

  func eraseAndRestart() async {
    Core.eraseData()
    storageBroken = false
    started = false
    loading = true
    await start()
  }

  func reload() async {
    do { state = try await Core.call("state") } catch { show(error) }
  }

  func becameActive() {
    guard started, !loading, demo == nil else { return }
    refreshIPInfo()
    if vpn.isConnected { startStatsPolling() }
    checkPasteboard()
    if state.settings.refreshHours > 0, let oldest = oldestRefresh(), Date().timeIntervalSince(oldest) > Double(state.settings.refreshHours) * 3600 {
      Task { await refreshAll(silent: true) }
    }
  }

  func becameInactive() {
    statsTask?.cancel()
    statsTask = nil
  }

  private func oldestRefresh() -> Date? {
    state.subscriptions.filter(\.remote).compactMap { Format.parseDate($0.updatedAt) }.min()
  }

  // MARK: Messages

  func show(_ error: Error) {
    if error is CancellationError { return }
    if let core = error as? CoreError, core.code == "cancelled" { return }
    AppLog.warn("ui", "shown error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    banner = Banner(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
  }

  func info(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
    banner = Banner(text: text, isError: false, actionTitle: actionTitle, action: action)
  }

  // MARK: Import

  func importInput(_ raw: String) async -> Bool {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    do {
      let kind: Classification = try await Core.call("classify", ["text": text])
      if kind.kind == "transfer" {
        sheet = .preview(text)
        return true
      }
      refreshing = true
      defer { refreshing = false }
      let result: ImportResult = try await Core.call("importText", ["text": text])
      state = result.state
      switch result.kind {
      case "routing":
        info(L("import.routing"))
      case "ruleconfig":
        info(L("import.ruleconfig"), actionTitle: L("tab.config")) { [weak self] in self?.openControlCenter(.config) }
      default:
        var message = LF("import.added", result.added)
        if let replaced = result.replaced, replaced > 0 { message += " " + LF("import.replaced", replaced) }
        if let duplicates = result.duplicates, duplicates > 0 { message += " " + LF("import.duplicates", duplicates) }
        if result.warnings > 0 { message += " " + LF("import.skipped", result.warnings) }
        info(message)
        let fresh = state.servers.filter { latency[$0.id] == nil }
        if !fresh.isEmpty { probe(fresh) }
        locateServers()
      }
      Haptics.success()
      return true
    } catch {
      Haptics.error()
      show(error)
      return false
    }
  }

  func handle(url: URL) {
    if url.isFileURL {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      guard let data = try? Data(contentsOf: url), data.count < 12 << 20,
            let text = String(data: data, encoding: .utf8) else {
        show(CoreError(code: "transfer_corrupted", detail: nil))
        return
      }
      Task { _ = await importInput(text) }
      return
    }
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme == "paradise" {
      switch url.host?.lowercased() {
      case "connect":
        Task { if !vpn.isActive { await connect() } }
      case "disconnect":
        Task { await disconnect() }
      case "toggle":
        Task { await toggleConnection() }
      default:
        sheet = .preview(url.absoluteString)
      }
      return
    }
  }

  private func checkPasteboard() {
    guard prefs.pasteboardDetect, UIPasteboard.general.hasStrings else { return }
    UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { [weak self] result in
      guard case .success(let patterns) = result, !patterns.isEmpty else { return }
      Task { @MainActor in
        guard let self = self else { return }
        self.info(L("pasteboard.found"), actionTitle: L("pasteboard.import")) {
          guard let text = UIPasteboard.general.string else { return }
          Task { _ = await self.importInput(text) }
        }
      }
    }
  }

  // MARK: Subscriptions

  func refreshAll(silent: Bool = false) async {
    refreshing = true
    defer { refreshing = false }
    do {
      let result: RefreshResult = try await Core.call("refreshAll")
      state = result.state
      if !silent, let code = result.errors.values.first {
        show(CoreError(code: code, detail: nil))
      }
      let fresh = state.servers.filter { latency[$0.id] == nil }
      if !fresh.isEmpty { probe(fresh) }
      locateServers()
    } catch {
      if !silent { show(error) }
    }
  }

  /// Looks up the country and city of servers whose names don't say them (cached by the core).
  func locateServers() {
    guard demo == nil, state.settings.locateServers, !state.servers.isEmpty, locateTask == nil else { return }
    locateTask = Task { [weak self] in
      let next: CoreState? = try? await Core.call("locateServers")
      guard let self = self else { return }
      if let next = next { self.state = next }
      self.locateTask = nil
    }
  }

  func refresh(_ sub: CoreSubscription) async {
    refreshing = true
    defer { refreshing = false }
    do { state = try await Core.call("refresh", ["id": sub.id]) } catch { show(error) }
  }

  func delete(_ sub: CoreSubscription) async {
    do { state = try await Core.call("deleteSubscription", ["id": sub.id]) } catch { show(error) }
  }

  func rename(_ sub: CoreSubscription, to name: String) async {
    do { state = try await Core.call("renameSubscription", ["id": sub.id, "name": name]) } catch { show(error) }
  }

  func deleteAllServers() async {
    if vpn.isActive { await disconnect() }
    do { state = try await Core.call("deleteAllServers") } catch { show(error) }
    latency = [:]
  }

  // MARK: Servers

  func toggleFavorite(_ server: CoreServer) async {
    Haptics.selection()
    do { state = try await Core.call("setFavorite", ["key": server.key, "favorite": !server.favorite]) } catch { show(error) }
  }

  /// The server the home screen talks about: the connected one while the tunnel is up, else the selected one.
  var currentServer: CoreServer? {
    if vpn.isActive, let s = state.servers.first(where: { $0.id == vpn.connectedServerID }) { return s }
    return state.selectedServer
  }

  /// Star in the action bar.
  func toggleFavoriteSelected() async {
    guard let server = currentServer else { return }
    await toggleFavorite(server)
  }

  func openControlCenter(_ section: ControlCenterView.Section) {
    controlSection = section
    sheet = .controlCenter
  }

  func select(_ server: CoreServer) async {
    let previous = state.selected
    Haptics.selection()
    do { state = try await Core.call("select", ["id": server.id]) } catch { show(error); return }
    if vpn.isActive && previous != server.id {
      await connect()
    }
  }

  /// Selects a server and connects (or switches the running tunnel).
  func connect(to server: CoreServer) async {
    if state.selected != server.id {
      do { state = try await Core.call("select", ["id": server.id]) } catch { show(error); return }
    }
    if vpn.isConnected && vpn.connectedServerID == server.id { return }
    await connect()
  }

  func probe(_ servers: [CoreServer]) {
    if demo != nil {
      Demo.applyLatency(to: self, servers: servers)
      return
    }
    probeTask?.cancel()
    let ids = Array(servers.prefix(300).map(\.id))
    guard !ids.isEmpty else { return }
    for id in ids { latency[id] = .testing }
    probing = true
    let iface = vpn.isActive ? physicalInterface : nil
    probeTask = Task { [weak self] in
      await withTaskGroup(of: Void.self) { group in
        var index = 0
        while index < min(6, ids.count) {
          let id = ids[index]
          group.addTask { await self?.probeOne(id, iface: iface) }
          index += 1
        }
        while await group.next() != nil {
          if Task.isCancelled { break }
          if index < ids.count {
            let id = ids[index]
            group.addTask { await self?.probeOne(id, iface: iface) }
            index += 1
          }
        }
      }
      self?.probing = false
    }
  }

  private func probeOne(_ id: String, iface: String?) async {
    do {
      var args: [String: Any] = ["id": id]
      if let iface = iface { args["iface"] = iface }
      let result: ProbeResult = try await Core.call("probe", args)
      latency[id] = .ms(result.ms)
    } catch let error as CoreError where error.code == "cancelled" {
      if latency[id] == .testing { latency[id] = nil }
    } catch {
      latency[id] = .failed
    }
  }

  func cancelProbes() {
    probeTask?.cancel()
    probeTask = nil
    probing = false
    Task { let _: [String: Bool]? = try? await Core.call("cancelProbes") }
    for (id, value) in latency where value == .testing { latency[id] = nil }
  }

  /// The server with the lowest measured latency (optionally within a region).
  func fastest(in servers: [CoreServer]? = nil) -> CoreServer? {
    let pool = servers ?? state.servers
    return pool.compactMap { s -> (CoreServer, Int64)? in
      guard let ms = latency[s.id]?.value else { return nil }
      return (s, ms)
    }.min { $0.1 < $1.1 }?.0
  }

  // MARK: Protocol filter

  /// Protocol families present in the servers ("wireguard", "vless-reality", …), in list order.
  var availableProtocols: [String] {
    var seen = Set<String>(), out: [String] = []
    for s in state.servers {
      let f = ServerText.family(s)
      if seen.insert(f).inserted { out.append(f) }
    }
    return out
  }

  /// "auto" or one family; a family that is no longer present means "auto".
  var protocolFilter: String {
    availableProtocols.contains(prefs.protocolFilter) ? prefs.protocolFilter : "auto"
  }

  func setProtocolFilter(_ family: String) {
    guard family != prefs.protocolFilter else { return }
    Haptics.selection()
    prefs.protocolFilter = family
    objectWillChange.send()
  }

  /// Servers shown in the list and on the map (after the protocol filter).
  var visibleServers: [CoreServer] {
    let filter = protocolFilter
    guard filter != "auto" else { return state.servers }
    return state.servers.filter { ServerText.family($0) == filter }
  }

  /// Value of the Protocol column: the protocol in use, the filter, or the only protocol present.
  var protocolDisplay: String {
    if vpn.isActive, let s = state.servers.first(where: { $0.id == vpn.connectedServerID }) { return ServerText.familyName(ServerText.family(s)) }
    let filter = protocolFilter
    if filter != "auto" { return ServerText.familyName(filter) }
    if let s = state.selectedServer { return ServerText.familyName(ServerText.family(s)) }
    let families = availableProtocols
    if families.count == 1 { return ServerText.familyName(families[0]) }
    return L("protocol.auto")
  }

  /// Countries on the map, in subscription order (only countries with visible servers).
  var countryNodes: [CountryNode] {
    var byCC: [String: [CoreServer]] = [:]
    for s in visibleServers { byCC[s.cc ?? "", default: []].append(s) }
    return state.countries.compactMap { c in
      guard let servers = byCC[c.cc], !servers.isEmpty else { return nil }
      let values = servers.compactMap { latency[$0.id]?.value }
      let testing = servers.contains { latency[$0.id] == .testing }
      return CountryNode(cc: c.cc, region: c.region, lat: c.lat, lon: c.lon, servers: servers, best: values.min(), testing: testing)
    }
  }

  func connect(country: CountryNode) async {
    let server = fastest(in: country.servers) ?? country.servers.first { $0.id == state.selected } ?? country.servers.first
    guard let server = server else { return }
    Haptics.tap()
    await connect(to: server)
  }

  // MARK: Connection

  func toggleConnection() async {
    if vpn.isActive {
      await disconnect()
      return
    }
    await connect()
  }

  func disconnect() async {
    userDisconnecting = true
    if demo != nil {
      await vpn.demoDisconnect()
    } else {
      await vpn.disconnect()
    }
    Haptics.tap()
  }

  /// The server Connect uses: the selected one, else the fastest visible, else the first visible.
  var connectTarget: CoreServer? {
    state.selectedServer ?? fastest(in: visibleServers) ?? visibleServers.first ?? state.servers.first
  }

  func connect() async {
    guard let target = connectTarget else {
      sheet = .add
      return
    }
    if state.selected != target.id {
      do { state = try await Core.call("select", ["id": target.id]) } catch { show(error); return }
    }
    if demo != nil {
      userDisconnecting = false
      await vpn.demoConnect(serverID: target.id)
      Haptics.success()
      return
    }
    do {
      let tunnel: TunnelConfig = try await Core.call("tunnelConfig", ["id": target.id])
      await reload()
      if tunnel.droppedRules > 0 { info(LF("connect.dropped_rules", tunnel.droppedRules)) }
      if let missing = tunnel.missingGeo, !missing.isEmpty {
        info(LF("connect.missing_geo", missing.count), actionTitle: L("geo.download")) { [weak self] in
          Task { await self?.updateGeo() }
        }
      }
      userDisconnecting = false
      try await vpn.connect(tunnel)
      Haptics.success()
    } catch {
      Haptics.error()
      show(error)
    }
  }

  private func vpnStatusChanged(_ status: NEVPNStatus) {
    defer { lastStatus = status }
    guard status != lastStatus else { return }
    if demo != nil {
      Demo.statusChanged(status, model: self)
      return
    }
    switch status {
    case .connected:
      startStatsPolling()
      refreshIPInfo(delay: 1)
    case .disconnected, .invalid:
      statsTask?.cancel()
      statsTask = nil
      rateUp = 0
      rateDown = 0
      refreshIPInfo(delay: 1)
      if lastStatus == .connected || lastStatus == .reasserting, !userDisconnecting, prefs.vpnReminder {
        Self.notify(title: L("reminder.title"), body: L("reminder.body"))
      }
      userDisconnecting = false
    default:
      break
    }
  }

  static func notify(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  // MARK: Public IP

  func refreshIPInfo(delay: Double = 0) {
    guard demo == nil else { return }
    ipTask?.cancel()
    ipTask = Task { [weak self] in
      if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
      guard !Task.isCancelled else { return }
      let info = await Self.fetchPublicIP()
      guard !Task.isCancelled else { return }
      self?.publicIP = info?.ip
      self?.publicCountry = info?.country
      self?.publicCity = info?.city
    }
  }

  struct PublicIPInfo: Equatable {
    var ip: String
    var country: String?
    var city: String?
  }

  /// Public IP with country and city (ipinfo.io), falling back to Cloudflare's trace (country only).
  nonisolated static func fetchPublicIP() async -> PublicIPInfo? {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    func get(_ link: String) async -> Data? {
      guard let url = URL(string: link) else { return nil }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
      request.setValue("Paradise", forHTTPHeaderField: "User-Agent")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      guard let reply = try? await session.data(for: request), (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
      return reply.0
    }
    struct IPInfo: Decodable { var ip: String?; var country: String?; var city: String? }
    if let data = await get("https://ipinfo.io/json"), let v = try? JSONDecoder().decode(IPInfo.self, from: data),
       let ip = v.ip, !ip.isEmpty {
      let cc = v.country?.uppercased()
      return PublicIPInfo(ip: ip, country: cc?.count == 2 ? cc : nil, city: v.city?.isEmpty == false ? v.city : nil)
    }
    guard let data = await get("https://www.cloudflare.com/cdn-cgi/trace"), let text = String(data: data, encoding: .utf8) else { return nil }
    var ip = "", loc = ""
    for line in text.split(separator: "\n") {
      if line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
      if line.hasPrefix("loc=") { loc = String(line.dropFirst(4)) }
    }
    return ip.isEmpty ? nil : PublicIPInfo(ip: ip, country: loc.count == 2 ? loc : nil, city: nil)
  }

  // MARK: Traffic statistics

  func startStatsPolling() {
    guard statsTask == nil else { return }
    statsTask = Task { [weak self] in
      var previous: (TrafficStats, Date)?
      while !Task.isCancelled {
        guard let self = self else { return }
        if let stats = await self.vpn.trafficStats() {
          let now = Date()
          if let prev = previous, stats.up >= prev.0.up, stats.down >= prev.0.down {
            let dt = max(0.2, now.timeIntervalSince(prev.1))
            self.rateUp = Double(stats.up - prev.0.up) / dt
            self.rateDown = Double(stats.down - prev.0.down) / dt
          }
          previous = (stats, now)
          self.traffic = stats
          UserDefaults.standard.set(try? JSONEncoder().encode(StoredStats(stats)), forKey: "stats.last")
        } else if !self.vpn.isActive {
          break
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      self?.statsTask = nil
    }
  }

  struct StoredStats: Codable {
    var totalUp: UInt64
    var totalDown: UInt64
    init(_ s: TrafficStats) { totalUp = s.totalUp; totalDown = s.totalDown }
  }

  var storedTotals: StoredStats? {
    guard let data = UserDefaults.standard.data(forKey: "stats.last") else { return nil }
    return try? JSONDecoder().decode(StoredStats.self, from: data)
  }

  func resetStats() async {
    _ = await vpn.send("resetStats")
    UserDefaults.standard.removeObject(forKey: "stats.last")
    traffic = nil
  }

  // MARK: Notices (bell)

  var notices: [Notice] {
    var out: [Notice] = []
    if demo != nil { out.append(Demo.notice) }
    let now = Date().timeIntervalSince1970
    for sub in state.subscriptions {
      let name = sub.displayName
      if let text = sub.meta?.announce, !text.isEmpty {
        out.append(Notice(id: "a-\(sub.id)-\(text.hashValue)", kind: .announce, title: name, body: text, link: sub.meta?.supportUrl))
      }
      if let expire = sub.meta?.expire, expire > 0 {
        let left = Double(expire) - now
        if left < 0 {
          out.append(Notice(id: "e-\(sub.id)-\(expire)", kind: .expiry, title: name, body: L("notice.expired"), link: sub.meta?.webUrl))
        } else if left < 3 * 86400 {
          out.append(Notice(id: "e-\(sub.id)-\(expire)", kind: .expiry, title: name, body: LF("notice.expires", Format.date(expire)), link: sub.meta?.webUrl))
        }
      }
      if let total = sub.meta?.total, total > 0 {
        let used = (sub.meta?.upload ?? 0) + (sub.meta?.download ?? 0)
        if Double(used) / Double(total) > 0.9 {
          out.append(Notice(id: "t-\(sub.id)-\(total)", kind: .traffic, title: name, body: LF("notice.traffic", Format.bytes(used), Format.bytes(total)), link: sub.meta?.webUrl))
        }
      }
      if let code = sub.lastError, !code.isEmpty {
        out.append(Notice(id: "x-\(sub.id)-\(code)", kind: .error, title: name, body: CoreError.message(code: code), link: nil))
      }
    }
    return out
  }

  var unseenNotices: Int { notices.filter { !prefs.seenNotices.contains($0.id) }.count }

  func markNoticesSeen() {
    var seen = prefs.seenNotices
    for n in notices where !seen.contains(n.id) { seen.append(n.id) }
    prefs.seenNotices = Array(seen.suffix(200))
  }

  // MARK: Settings

  func updateSettings(_ patch: [String: Any], reconnectHint: Bool = false) async {
    do {
      state = try await Core.call("updateSettings", patch)
      if reconnectHint && vpn.isConnected {
        info(L("settings.reconnect_hint"), actionTitle: L("settings.reconnect")) { [weak self] in
          Task { await self?.connect() }
        }
      }
    } catch { show(error) }
  }

  func resetSettings() async {
    do { state = try await Core.call("resetSettings") } catch { show(error) }
    prefs.resetUI()
  }

  func resetAll() async {
    await disconnect()
    do { state = try await Core.call("resetAll") } catch { show(error) }
    latency = [:]
  }

  // MARK: Routing configs

  func activateConfig(_ id: String) async {
    do {
      state = try await Core.call("activateConfig", ["id": id])
      Haptics.selection()
      if vpn.isConnected { await connect() }
    } catch { show(error) }
  }

  func vpnConnectedWithConfig(_ id: String) -> Bool {
    vpn.isConnected && state.settings.mode == "config" && state.activeConfig?.id == id
  }

  func setMode(_ mode: String) async {
    guard state.settings.mode != mode else { return }
    Haptics.selection()
    await updateSettings(["mode": mode])
    if vpn.isConnected { await connect() }
  }

  func updateRemoteConfigs() async {
    for c in state.configs where c.remote {
      if let result: ConfigSaveResult = try? await Core.call("updateConfig", ["id": c.id]) {
        state = result.state
      }
    }
  }

  func loadGeo() async {
    geo = try? await Core.call("geoStatus")
  }

  func updateGeo(ipURL: String = "", siteURL: String = "") async {
    refreshing = true
    defer { refreshing = false }
    do {
      geo = try await Core.call("updateGeo", ["ipUrl": ipURL, "siteUrl": siteURL])
      await reload()
      info(L("geo.updated"))
      Haptics.success()
    } catch {
      show(error)
      await loadGeo()
    }
  }

  // MARK: Transfer

  func export(_ options: [String: Any]) async throws -> ExportResult {
    try await Core.call("exportTransfer", options)
  }

  func preview(code: String, password: String) async throws -> TransferPreview {
    try await Core.call("previewTransfer", ["code": code, "password": password])
  }

  func importTransfer(code: String, password: String, replace: Bool, applySettings: Bool, applyIdentity: Bool) async throws {
    let result: ImportTransferResult = try await Core.call("importTransfer", [
      "code": code, "password": password, "strategy": replace ? "replace" : "merge",
      "applySettings": applySettings, "applyIdentity": applyIdentity,
    ])
    state = result.state
    if !result.pendingRefresh.isEmpty {
      refreshing = true
      for id in result.pendingRefresh {
        if let next: CoreState = try? await Core.call("refresh", ["id": id]) { state = next }
      }
      refreshing = false
    }
    await reload()
    var message = LF("transfer.imported", result.added)
    if result.duplicates > 0 { message += " " + LF("transfer.imported_duplicates", result.duplicates) }
    info(message)
    probe(state.servers.filter { latency[$0.id] == nil })
  }
}
