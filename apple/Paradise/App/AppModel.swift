import Foundation
import Network
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
  enum Sheet: Identifiable {
    case servers, add, export, settings
    case preview(String)

    var id: String {
      switch self {
      case .servers: return "servers"
      case .add: return "add"
      case .export: return "export"
      case .settings: return "settings"
      case .preview(let code): return "preview-\(code.hashValue)"
      }
    }
  }

  enum Latency: Equatable {
    case testing
    case ms(Int64)
    case failed
  }

  struct Banner: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
  }

  @Published var state = CoreState.empty
  @Published var latency: [String: Latency] = [:]
  @Published var banner: Banner?
  @Published var loading = true
  @Published var refreshing = false
  @Published var probing = false
  @Published var sheet: Sheet?
  @Published var storageBroken = false
  @Published var online = true

  let vpn = VPNController()
  private let monitor = NWPathMonitor()
  private var probeTask: Task<Void, Never>?
  private var started = false

  // MARK: Lifecycle

  func start() async {
    guard !started else { return }
    started = true
    monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in self?.online = path.status == .satisfied }
    }
    monitor.start(queue: DispatchQueue(label: "app.paradise.path"))
    do {
      try Core.open()
    } catch let error as CoreError where error.code == "storage" {
      storageBroken = true
      loading = false
      return
    } catch {
      show(error)
      loading = false
      return
    }
    await reload()
    await vpn.load()
    loading = false
    if state.settings.autoRefresh, state.subscriptions.contains(where: { $0.remote }) {
      await refreshAll(silent: true)
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

  // MARK: Messages

  func show(_ error: Error) {
    if error is CancellationError { return }
    if let core = error as? CoreError, core.code == "cancelled" { return }
    banner = Banner(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
  }

  func info(_ text: String) {
    banner = Banner(text: text, isError: false)
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
      var message = LF("import.added", result.added)
      if result.warnings > 0 { message += " " + LF("import.skipped", result.warnings) }
      info(message)
      return true
    } catch {
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
    if url.scheme?.lowercased() == "paradise" {
      sheet = .preview(url.absoluteString)
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
    } catch {
      if !silent { show(error) }
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

  // MARK: Servers

  func toggleFavorite(_ server: CoreServer) async {
    do { state = try await Core.call("setFavorite", ["key": server.key, "favorite": !server.favorite]) } catch { show(error) }
  }

  func select(_ server: CoreServer) async {
    let previous = state.selected
    do { state = try await Core.call("select", ["id": server.id]) } catch { show(error); return }
    if vpn.isActive && previous != server.id {
      await connect()
    }
  }

  func probe(_ servers: [CoreServer]) {
    if vpn.isActive {
      info(L("probe.vpn_active"))
      return
    }
    probeTask?.cancel()
    let ids = servers.prefix(80).map(\.id)
    for id in ids { latency[id] = .testing }
    probing = true
    probeTask = Task { [weak self] in
      await withTaskGroup(of: Void.self) { group in
        var index = 0
        while index < min(4, ids.count) {
          let id = ids[index]
          group.addTask { await self?.probeOne(id) }
          index += 1
        }
        while await group.next() != nil {
          if Task.isCancelled { break }
          if index < ids.count {
            let id = ids[index]
            group.addTask { await self?.probeOne(id) }
            index += 1
          }
        }
      }
      self?.probing = false
    }
  }

  private func probeOne(_ id: String) async {
    do {
      let result: ProbeResult = try await Core.call("probe", ["id": id])
      latency[id] = .ms(result.ms)
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

  // MARK: Connection

  func toggleConnection() async {
    if vpn.isActive {
      await vpn.disconnect()
      return
    }
    await connect()
  }

  func connect() async {
    guard !state.servers.isEmpty else {
      sheet = .add
      return
    }
    cancelProbes()
    do {
      let tunnel: TunnelConfig = try await Core.call("tunnelConfig", ["id": state.selected])
      await reload()
      if tunnel.droppedRules > 0 { info(LF("connect.dropped_rules", tunnel.droppedRules)) }
      try await vpn.connect(tunnel)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      UINotificationFeedbackGenerator().notificationOccurred(.error)
      show(error)
    }
  }

  // MARK: Settings

  func updateSettings(_ patch: [String: Any], reconnectHint: Bool = false) async {
    do {
      state = try await Core.call("updateSettings", patch)
      if reconnectHint && vpn.isConnected { info(L("settings.reconnect_hint")) }
    } catch { show(error) }
  }

  func resetAll() async {
    await vpn.disconnect()
    do { state = try await Core.call("resetAll") } catch { show(error) }
    latency = [:]
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
  }
}
