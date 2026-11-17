import Network
import NetworkExtension
import SwiftUI
import UIKit

/// Temporary test bench: self-test of every subsystem, subscription download checks,
/// a live VPN check, lag detection and a log console. Nothing is sent anywhere.
struct DiagnosticsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @Environment(\.dismiss) private var dismiss

  struct Row: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var state: State
    var ms: Int64 = 0
    var detail: String = ""
    enum State { case ok, warn, fail, running }
  }

  @State private var rows: [Row] = []
  @State private var running = false
  @State private var fetchResults: [String: Row] = [:]
  @State private var fetching: Set<String> = []
  @State private var vpnRows: [Row] = []
  @State private var vpnTesting = false
  @State private var copied = false

  init() {}

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button { Task { await runAll() } } label: {
            HStack {
              Label(L("diag.run"), systemImage: "checklist")
              Spacer()
              if running { ProgressView() }
            }
          }
          .disabled(running)
          ForEach(rows) { RowView(row: $0) }
        } header: {
          Text(L("diag.selftest"))
        } footer: {
          Text(L("diag.selftest_footer"))
        }

        Section(L("diag.subscriptions")) {
          let remote = model.state.subscriptions.filter(\.remote)
          if remote.isEmpty { Text(L("diag.no_subscriptions")).foregroundStyle(Theme.muted) }
          ForEach(remote) { sub in
            Button { Task { await testFetch(sub) } } label: {
              HStack {
                Text(sub.displayName).lineLimit(1)
                Spacer()
                if fetching.contains(sub.id) { ProgressView() } else { Image(systemName: "arrow.down.circle") }
              }
            }
            if let row = fetchResults[sub.id] { RowView(row: row) }
          }
        }

        Section {
          Button { Task { await testVPN() } } label: {
            HStack {
              Label(L("diag.vpn_test"), systemImage: "network.badge.shield.half.filled")
              Spacer()
              if vpnTesting { ProgressView() }
            }
          }
          .disabled(vpnTesting || model.state.servers.isEmpty)
          ForEach(vpnRows) { RowView(row: $0) }
        } header: {
          Text("VPN")
        } footer: {
          Text(L("diag.vpn_footer"))
        }

        Section {
          NavigationLink { LogConsoleView() } label: { Label(L("diag.console"), systemImage: "terminal") }
          Button { copyReport() } label: {
            Label(copied ? L("common.copied") : L("diag.copy_report"), systemImage: "doc.on.doc")
          }
          if let url = reportFile() {
            ShareLink(item: url) { Label(L("diag.share_report"), systemImage: "square.and.arrow.up") }
          }
        } footer: {
          Text(L("diag.privacy"))
        }
      }
      .navigationTitle(L("diag.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(L("common.done")) { dismiss() } } }
    }
  }

  // MARK: Self-test

  private func runAll() async {
    running = true
    defer { running = false }
    rows = []
    AppLog.info("diag", "self-test started")

    rows.append(Row(name: "App", state: .ok, detail: Self.deviceLine()))
    rows.append(Row(name: "Storage key", state: Keychain.mode == .keychain ? .ok : .warn,
                    detail: Keychain.mode == .keychain ? "Keychain" : "file fallback (Keychain: \(Keychain.describe(Keychain.lastStatus)))"))
    if Core.isOpen {
      rows.append(Row(name: "Core", state: .ok, detail: "open, Xray \(Core.xrayVersion)"))
    } else {
      let reason = (Core.openError as? LocalizedError)?.errorDescription ?? Core.openError.map { "\($0)" } ?? "not opened"
      rows.append(Row(name: "Core", state: .fail, detail: reason + " [\((Core.openError as? CoreError)?.detail ?? "")]"))
    }

    let ext = Bundle.main.builtInPlugInsURL.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }?
      .first { $0.pathExtension == "appex" }.flatMap { Bundle(url: $0)?.bundleIdentifier }
    rows.append(Row(name: "Tunnel extension", state: ext == nil ? .fail : .ok, detail: ext ?? "PlugIns/PacketTunnel.appex missing"))

    let started = Date()
    let (prefOK, prefDetail) = await vpn.preferencesCheck()
    rows.append(Row(name: "VPN preferences", state: prefOK ? .ok : .fail, ms: ms(since: started), detail: prefDetail))

    rows.append(Row(name: "Network path", state: model.online ? .ok : .fail, detail: model.online ? "online" : "offline"))
    rows.append(await httpCheck(name: "Internet (HTTPS)", url: "https://www.gstatic.com/generate_204"))
    rows.append(Row(name: "Main thread", state: HangDetector.shared.worstMS > 1000 ? .warn : .ok, detail: HangDetector.shared.summary))

    if Core.isOpen {
      do {
        let checks: [CoreCheck] = try await Core.call("selfTest")
        for c in checks {
          rows.append(Row(name: "core · \(c.name)", state: c.ok ? (c.warn == true ? .warn : .ok) : .fail, ms: c.ms, detail: c.detail ?? ""))
        }
      } catch {
        rows.append(Row(name: "core · selfTest", state: .fail, detail: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
      }
    }
    let failed = rows.filter { $0.state == .fail }.count
    AppLog.add(failed > 0 ? "warn" : "info", "diag", "self-test finished: \(rows.count) checks, \(failed) failed")
  }

  private func httpCheck(name: String, url: String) async -> Row {
    let started = Date()
    var request = URLRequest(url: URL(string: url)!)
    request.timeoutInterval = 10
    request.cachePolicy = .reloadIgnoringLocalCacheData
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      let row = Row(name: name, state: code < 400 ? .ok : .fail, ms: ms(since: started),
                    detail: "HTTP \(code)" + (vpn.isConnected ? " via VPN" : " direct"))
      AppLog.info("diag", "\(name): \(row.detail) in \(row.ms) ms")
      return row
    } catch {
      let e = error as NSError
      AppLog.warn("diag", "\(name): \(e.domain) \(e.code)")
      return Row(name: name, state: .fail, ms: ms(since: started), detail: "\(e.domain) \(e.code): \(e.localizedDescription)")
    }
  }

  // MARK: Subscriptions

  private func testFetch(_ sub: CoreSubscription) async {
    fetching.insert(sub.id)
    defer { fetching.remove(sub.id) }
    do {
      let r: FetchTestResult = try await Core.call("testFetch", ["id": sub.id])
      var parts = ["HTTP \(r.report.status)", r.report.bodyKind ?? "?", Format.bytes(Int64(r.report.bytes))]
      if let format = r.format { parts.append(format) }
      parts.append("\(r.servers) servers")
      if let ct = r.report.contentType, !ct.isEmpty { parts.append(ct) }
      if let meta = r.meta, !meta.isEmpty { parts.append("meta: " + meta.joined(separator: ",")) }
      if let error = r.error { parts.append("error: \(error.code) \(error.detail ?? "")") }
      if let warnings = r.warnings, !warnings.isEmpty { parts.append("skipped: " + warnings.prefix(3).joined(separator: "; ")) }
      parts.append("UA: \(r.userAgent)")
      if let trace = r.trace, !trace.isEmpty { parts.append("steps: " + trace.joined(separator: " | ")) }
      fetchResults[sub.id] = Row(name: r.host, state: r.ok ? .ok : .fail, ms: r.report.ms, detail: parts.joined(separator: " · "))
    } catch {
      fetchResults[sub.id] = Row(name: sub.displayName, state: .fail, detail: (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
  }

  // MARK: VPN

  private func testVPN() async {
    vpnTesting = true
    defer { vpnTesting = false }
    vpnRows = []
    let wasConnected = vpn.isConnected
    AppLog.info("diag", "vpn test started (connected=\(wasConnected))")
    if !wasConnected {
      let started = Date()
      await model.connect()
      vpnRows.append(Row(name: "Connect", state: vpn.isConnected ? .ok : .fail, ms: ms(since: started),
                         detail: vpn.isConnected ? (model.state.selectedServer?.name ?? "") : (model.banner?.text ?? VPNController.name(vpn.status))))
      if !vpn.isConnected {
        vpnRows.append(Row(name: "Last disconnect", state: .fail, detail: await vpn.lastDisconnectReason()))
        return
      }
      try? await Task.sleep(nanoseconds: 800_000_000)
    }
    vpnRows.append(await httpCheck(name: "HTTPS through VPN", url: "https://www.gstatic.com/generate_204"))
    vpnRows.append(await httpCheck(name: "Second request", url: "https://www.google.com/generate_204"))
    if let logs = await vpn.tunnelLogs() {
      let errors = logs.entries.filter { $0.level == "error" }.count
      vpnRows.append(Row(name: "Tunnel memory", state: (logs.footprintMB ?? 0) > 42 ? .warn : .ok,
                         detail: String(format: "footprint %.1f MB, Go heap %ld MB, sys %ld MB, goroutines %ld", logs.footprintMB ?? -1, logs.heapMB, logs.sysMB, logs.goroutines)))
      let xrayErrors = logs.xray.split(separator: "\n").filter { !$0.isEmpty }
      vpnRows.append(Row(name: "Tunnel log", state: errors > 0 ? .warn : .ok,
                         detail: "\(logs.entries.count) lines, \(errors) errors; Xray: \(xrayErrors.count) lines" + (xrayErrors.last.map { " · last: \($0.suffix(200))" } ?? "")))
    } else {
      vpnRows.append(Row(name: "Tunnel log", state: .warn, detail: "extension did not answer"))
    }
    if !wasConnected { await vpn.disconnect() }
    AppLog.info("diag", "vpn test finished")
  }

  // MARK: Report

  private func ms(since date: Date) -> Int64 { Int64(Date().timeIntervalSince(date) * 1000) }

  static func deviceLine() -> String {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "Paradise \(v) (\(b)) · iOS \(UIDevice.current.systemVersion) · \(Device.modelIdentifier)"
  }

  private func reportText() -> String {
    var out = ["Paradise diagnostics", Self.deviceLine(), "Generated \(Date())", ""]
    func add(_ title: String, _ list: [Row]) {
      guard !list.isEmpty else { return }
      out.append("== \(title)")
      for r in list { out.append("[\(r.state)] \(r.name) \(r.ms > 0 ? "\(r.ms)ms " : "")\(r.detail)") }
      out.append("")
    }
    add("Self-test", rows)
    add("Subscriptions", Array(fetchResults.values))
    add("VPN", vpnRows)
    out.append("== App log")
    out.append(contentsOf: AppLog.snapshot().suffix(300).map(\.text))
    return Redactor.cleanDocument(out.joined(separator: "\n"))
  }

  private func copyReport() {
    UIPasteboard.general.string = reportText()
    copied = true
  }

  private func reportFile() -> URL? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("paradise-diagnostics.txt")
    try? reportText().write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}

struct CoreCheck: Decodable {
  var name: String
  var ok: Bool
  var warn: Bool?
  var ms: Int64
  var detail: String?
}

struct FetchTestResult: Decodable {
  struct Report: Decodable {
    var status: Int
    var contentType: String?
    var bytes: Int
    var ms: Int64
    var finalHost: String?
    var redirects: Int
    var bodyKind: String?
  }
  var host: String
  var report: Report
  var ok: Bool
  var error: CoreError?
  var format: String?
  var servers: Int
  var warnings: [String]?
  var meta: [String]?
  var userAgent: String
  var trace: [String]?
}

private struct RowView: View {
  let row: DiagnosticsView.Row

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon).foregroundStyle(color).frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(row.name).font(.subheadline.weight(.semibold))
          Spacer()
          if row.ms > 0 { Text("\(row.ms) ms").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted) }
        }
        if !row.detail.isEmpty {
          Text(row.detail).font(.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var icon: String {
    switch row.state {
    case .ok: return "checkmark.circle.fill"
    case .warn: return "exclamationmark.triangle.fill"
    case .fail: return "xmark.octagon.fill"
    case .running: return "clock"
    }
  }

  private var color: Color {
    switch row.state {
    case .ok: return .green
    case .warn: return Theme.warning
    case .fail: return Theme.danger
    case .running: return Theme.muted
    }
  }
}

/// Merged log console: app, core and tunnel.
struct LogConsoleView: View {
  @EnvironmentObject private var vpn: VPNController
  @State private var lines: [LogLine] = []
  @State private var onlyProblems = false
  @State private var source = "all"
  @State private var auto = true
  @State private var copied = false

  init() {}

  private var shown: [LogLine] {
    lines.filter { (!onlyProblems || $0.level != "info") && (source == "all" || $0.source == source) }
  }

  private var sources: [String] { ["all"] + Array(Set(lines.map(\.source))).sorted() }

  var body: some View {
    List {
      Section {
        Toggle(L("diag.only_problems"), isOn: $onlyProblems)
        Picker(L("diag.source"), selection: $source) {
          ForEach(sources, id: \.self) { Text($0).tag($0) }
        }
        Toggle(L("diag.autorefresh"), isOn: $auto)
      }
      Section("\(shown.count)") {
        ForEach(shown.reversed()) { line in
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(LogLine.formatter.string(from: line.time)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
              Text(line.source).font(.caption2.weight(.bold)).foregroundStyle(Theme.muted)
              if line.level != "info" {
                Text(line.level.uppercased()).font(.caption2.weight(.bold))
                  .foregroundStyle(line.level == "error" ? Theme.danger : Theme.warning)
              }
            }
            Text(line.msg).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
        }
      }
    }
    .navigationTitle(L("diag.console"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button { UIPasteboard.general.string = shown.map(\.text).joined(separator: "\n"); copied = true } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .accessibilityLabel(L("common.copy"))
        Button(role: .destructive) {
          AppLog.clear()
          Task {
            let _: [String: Bool]? = try? await Core.call("clearLogs")
            await reload()
          }
        } label: { Image(systemName: "trash") }
        .accessibilityLabel(L("diag.clear"))
      }
    }
    .refreshable { await reload() }
    .task {
      await reload()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if auto { await reload() }
      }
    }
  }

  private func reload() async {
    var all = AppLog.snapshot()
    if Core.isOpen, let core: [CoreLogEntry] = try? await Core.call("logs", ["after": 0]) {
      all += core.map { LogLine(id: "c\($0.id)", time: Date(timeIntervalSince1970: TimeInterval($0.time) / 1000), level: $0.level, source: $0.source, msg: $0.msg) }
    }
    if let tunnel = await vpn.tunnelLogs() {
      all += tunnel.entries.map { LogLine(id: "t\($0.id)", time: Date(timeIntervalSince1970: TimeInterval($0.time) / 1000), level: $0.level, source: "ext·" + $0.source, msg: $0.msg) }
      for (i, line) in tunnel.xray.split(separator: "\n").suffix(80).enumerated() where !line.isEmpty {
        all.append(LogLine(id: "x\(i)-\(line.hashValue)", time: Date(), level: "warn", source: "xray", msg: String(line)))
      }
    }
    lines = all.sorted { $0.time < $1.time }
    copied = false
  }
}

struct CoreLogEntry: Decodable {
  var id: Int64
  var time: Int64
  var level: String
  var source: String
  var msg: String
}
