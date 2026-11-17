import NetworkExtension
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// System share sheet for files produced on demand.
struct ShareSheet: UIViewControllerRepresentable {
  var items: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
  let id = UUID()
  let url: URL
}

enum TempFiles {
  /// Writes text to a uniquely named temporary file for sharing.
  static func write(_ text: String, name: String) -> URL? {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appendingPathComponent(name)
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }
}

struct DataTab: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @State private var shared: SharedFile?
  @State private var importing = false
  @State private var importKind = "backup"
  @State private var confirmDeleteAll = false
  @State private var backupPassword = ""
  @State private var protectBackup = false
  @State private var working = false

  init() {}

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(L("data.backup_password"), isOn: $protectBackup)
          if protectBackup {
            SecureField(L("export.password"), text: $backupPassword)
          }
          Button { Task { await backup() } } label: {
            HStack {
              Label(L("data.backup"), systemImage: "icloud.and.arrow.up")
              Spacer()
              if working { ProgressView() }
            }
          }
          .disabled(working || (protectBackup && backupPassword.count < 4))
          Button { importKind = "backup"; importing = true } label: { Label(L("data.restore"), systemImage: "icloud.and.arrow.down") }
        } header: {
          Text("iCloud")
        } footer: {
          Text(L("data.backup_footer"))
        }

        Section {
          HStack {
            Label("Apple TV", systemImage: "appletv")
            Spacer()
            Text(L("common.unavailable")).font(.caption).foregroundStyle(.secondary)
          }
          Button { model.sheet = .export } label: { Label(L("data.appletv_transfer"), systemImage: "qrcode") }
        } footer: {
          Text(L("data.appletv_footer"))
        }

        Section {
          Toggle(L("data.logs_autodelete"), isOn: setting(\.autoDeleteLogs, "autoDeleteLogs", hint: true))
          Toggle(L("data.logs_connections"), isOn: setting(\.connectionLog, "connectionLog", hint: true))
          Toggle(L("data.logs_dns"), isOn: setting(\.dnsLog, "dnsLog", hint: true))
          Picker(L("data.logs_level"), selection: setting(\.logLevel, "logLevel", hint: true)) {
            ForEach(["none", "error", "warning", "info", "debug"], id: \.self) { Text(L("loglevel.\($0)")).tag($0) }
          }
          NavigationLink { LogViewer(kind: .proxy) } label: { Label(L("data.logs_proxy"), systemImage: "arrow.left.arrow.right") }
          NavigationLink { LogViewer(kind: .dns) } label: { Label("DNS", systemImage: "network") }
          NavigationLink { LogViewer(kind: .core) } label: { Label(L("data.logs_core"), systemImage: "cpu") }
          Button(L("data.logs_clear")) {
            Task {
              _ = await vpn.send("clearLogs")
              let _: [String: Bool]? = try? await Core.call("clearLogs")
              model.info(L("data.logs_cleared"))
            }
          }
        } header: {
          Text(L("data.logs"))
        } footer: {
          Text(L("data.logs_footer"))
        }

        Section {
          Toggle(L("data.overwrite"), isOn: setting(\.overwriteExisting, "overwriteExisting"))
          Toggle(L("data.autorename"), isOn: setting(\.autoRename, "autoRename"))
          Button { importKind = "servers"; importing = true } label: { Label(L("data.import_servers"), systemImage: "square.and.arrow.down") }
          Menu {
            Button(L("data.export_links")) { Task { await exportServers("links") } }
            Button(L("data.export_json")) { Task { await exportServers("json") } }
          } label: {
            Label(L("data.export_servers"), systemImage: "square.and.arrow.up")
          }
          .disabled(model.state.servers.isEmpty)
          Button { model.sheet = .subscriptions } label: { Label(L("home.subscriptions"), systemImage: "tray.full") }
          Button(role: .destructive) { confirmDeleteAll = true } label: { Label(L("data.delete_all"), systemImage: "trash") }
            .disabled(model.state.servers.isEmpty && model.state.subscriptions.isEmpty)
        } header: {
          Text(L("data.servers"))
        } footer: {
          Text(LF("data.servers_footer", model.state.servers.count, model.state.subscriptions.count))
        }

        Section {
          NavigationLink { StatisticsView() } label: { Label(L("data.statistics"), systemImage: "chart.bar") }
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.space.ignoresSafeArea())
      .navigationTitle(L("tab.data"))
      .sheet(item: $shared) { file in ShareSheet(items: [file.url]) }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .json, .data], allowsMultipleSelection: false) { result in
        guard case .success(let urls) = result, let url = urls.first else { return }
        if importKind == "backup" {
          model.handle(url: url)
          return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 8 << 20, let text = String(data: data, encoding: .utf8) else {
          model.show(CoreError(code: "unsupported_format", detail: nil))
          return
        }
        Task { _ = await model.importInput(text) }
      }
      .confirmationDialog(L("data.delete_all_confirm"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
        Button(L("data.delete_all"), role: .destructive) { Task { await model.deleteAllServers() } }
      }
    }
  }

  private func setting<T>(_ path: WritableKeyPath<CoreSettings, T>, _ key: String, hint: Bool = false) -> Binding<T> {
    Binding(
      get: { model.state.settings[keyPath: path] },
      set: { value in Task { await model.updateSettings([key: value], reconnectHint: hint) } }
    )
  }

  private func backup() async {
    working = true
    defer { working = false }
    do {
      var options: [String: Any] = ["includeFavorites": true, "includeSettings": true, "includeIdentity": true, "name": L("data.backup_name")]
      if protectBackup { options["password"] = backupPassword }
      let result = try await model.export(options)
      let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
      if let url = TempFiles.write(result.link, name: "Paradise-backup-\(stamp).paradise") {
        shared = SharedFile(url: url)
      }
    } catch { model.show(error) }
  }

  private func exportServers(_ format: String) async {
    do {
      let result: ExportServersResult = try await Core.call("exportServers", ["format": format])
      if let url = TempFiles.write(result.text, name: result.fileName) {
        shared = SharedFile(url: url)
      }
      if result.skipped > 0 { model.info(LF("data.export_skipped", result.skipped)) }
    } catch { model.show(error) }
  }
}

struct LogViewer: View {
  enum Kind { case proxy, dns, core }
  let kind: Kind
  @EnvironmentObject private var vpn: VPNController
  @EnvironmentObject private var model: AppModel
  @State private var lines: [String] = []
  @State private var filter = ""
  @State private var paused = false

  private var title: String {
    switch kind {
    case .proxy: return L("data.logs_proxy")
    case .dns: return "DNS"
    case .core: return L("data.logs_core")
    }
  }

  private var shown: [String] {
    let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
    return q.isEmpty ? lines : lines.filter { $0.lowercased().contains(q) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Theme.dim)
        TextField(L("logs.filter"), text: $filter).textInputAutocapitalization(.never).autocorrectionDisabled()
      }
      .padding(10)
      .background(Color.white.opacity(0.06))
      if !vpn.isActive && lines.isEmpty {
        Text(L("logs.vpn_off")).font(.subheadline).foregroundStyle(Theme.dim).multilineTextAlignment(.center).padding(30)
        Spacer()
      } else if shown.isEmpty {
        Text(hint).font(.subheadline).foregroundStyle(Theme.dim).multilineTextAlignment(.center).padding(30)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(shown.suffix(600).enumerated()), id: \.offset) { _, line in
              Text(line)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(line.contains("[Warning]") || line.contains("[Error]") ? Theme.fair : Color.white.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(10)
        }
      }
    }
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
          .accessibilityLabel(paused ? L("logs.resume") : L("logs.pause"))
        Button { UIPasteboard.general.string = shown.joined(separator: "\n"); model.info(L("common.copied")) } label: { Image(systemName: "doc.on.doc") }
          .accessibilityLabel(L("common.copy"))
      }
    }
    .task {
      while !Task.isCancelled {
        if !paused { await load() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
  }

  private var hint: String {
    switch kind {
    case .proxy: return model.state.settings.connectionLog ? L("logs.empty") : L("logs.enable_connections")
    case .dns: return model.state.settings.dnsLog ? L("logs.empty") : L("logs.enable_dns")
    case .core: return L("logs.empty")
    }
  }

  private func load() async {
    guard let logs = await vpn.tunnelLogs() else { return }
    let text: String
    switch kind {
    case .proxy: text = logs.access ?? ""
    case .dns: text = logs.xray
    case .core: text = logs.xray
    }
    var out = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    if kind == .dns {
      out = out.filter { $0.contains("DNS") || $0.contains("dns") }
    } else if kind == .core {
      out = logs.entries.map { e in "[\(e.level)] \(e.source): \(e.msg)" } + out
    }
    lines = out
  }
}

struct StatisticsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @State private var confirmReset = false

  var body: some View {
    Form {
      Section(L("stats.session")) {
        LabeledContent(L("stats.download"), value: Format.bytes(Int64(model.traffic?.down ?? 0)))
        LabeledContent(L("stats.upload"), value: Format.bytes(Int64(model.traffic?.up ?? 0)))
        LabeledContent(L("stats.speed"), value: "↓ \(Format.rate(model.rateDown))  ↑ \(Format.rate(model.rateUp))")
        if let since = model.traffic?.since, vpn.isConnected {
          LabeledContent(L("stats.since"), value: Format.date(Int64(since)))
        }
        if let reflected = model.traffic?.reflected, reflected > 0 {
          LabeledContent(L("stats.reflected"), value: "\(reflected)")
        }
      }
      Section {
        let totals = model.traffic.map { AppModel.StoredStats($0) } ?? model.storedTotals
        LabeledContent(L("stats.download"), value: Format.bytes(Int64(totals?.totalDown ?? 0)))
        LabeledContent(L("stats.upload"), value: Format.bytes(Int64(totals?.totalUp ?? 0)))
        Button(L("stats.reset"), role: .destructive) { confirmReset = true }
      } header: {
        Text(L("stats.total"))
      } footer: {
        Text(L("stats.footer"))
      }
      Section(L("stats.subscriptions")) {
        ForEach(model.state.subscriptions.filter { ($0.meta?.total ?? 0) > 0 || ($0.meta?.download ?? 0) > 0 }) { sub in
          let used = (sub.meta?.upload ?? 0) + (sub.meta?.download ?? 0)
          VStack(alignment: .leading, spacing: 6) {
            Text(sub.displayName).font(.subheadline)
            if let total = sub.meta?.total, total > 0 {
              ProgressView(value: min(1, Double(used) / Double(total))).tint(Theme.glow)
              Text("\(Format.bytes(used)) / \(Format.bytes(total))").font(.caption).foregroundStyle(.secondary)
            } else {
              Text(Format.bytes(used)).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("data.statistics"))
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { if vpn.isConnected { model.startStatsPolling() } }
    .confirmationDialog(L("stats.reset_confirm"), isPresented: $confirmReset, titleVisibility: .visible) {
      Button(L("stats.reset"), role: .destructive) { Task { await model.resetStats() } }
    }
  }
}
