import SwiftUI
import UniformTypeIdentifiers

struct ConfigTab: View {
  @EnvironmentObject private var model: AppModel
  @State private var showURL = false
  @State private var urlText = ""
  @State private var importing = false
  @State private var path = NavigationPath()
  @State private var working = false

  init() {}

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          ForEach(["all", "config", "profile", "direct"], id: \.self) { mode in
            Button { Task { await model.setMode(mode) } } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(L("mode.\(mode)")).foregroundStyle(.primary)
                  Text(L("mode.\(mode).detail")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.state.settings.mode == mode {
                  Image(systemName: "checkmark").foregroundStyle(Theme.glow)
                }
              }
            }
          }
        } header: {
          Text(L("configs.mode"))
        } footer: {
          Text(L("configs.mode_footer"))
        }

        Section {
          ForEach(model.state.configs) { config in
            NavigationLink(value: config.id) { row(config) }
              .swipeActions(edge: .trailing) {
                if !config.builtin {
                  Button(role: .destructive) { Task { await delete(config) } } label: { Label(L("common.delete"), systemImage: "trash") }
                }
                if config.remote {
                  Button { Task { await update(config) } } label: { Label(L("configs.update"), systemImage: "arrow.clockwise") }
                    .tint(Theme.glow)
                }
              }
              .swipeActions(edge: .leading) {
                if !config.active {
                  Button { Task { await model.activateConfig(config.id) } } label: { Label(L("configs.use"), systemImage: "checkmark") }
                    .tint(Theme.good)
                }
              }
          }
        } header: {
          Text(L("configs.title"))
        } footer: {
          Text(L("configs.footer"))
        }

        Section {
          NavigationLink { GeoView() } label: {
            HStack {
              Label(L("geo.title"), systemImage: "globe.europe.africa")
              Spacer()
              Text(geoSummary).font(.caption).foregroundStyle(.secondary)
            }
          }
        } footer: {
          Text(L("geo.footer"))
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.space.ignoresSafeArea())
      .navigationTitle(L("tab.config"))
      .navigationDestination(for: String.self) { id in ConfigEditorView(id: id) }
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            Button { Task { await create() } } label: { Label(L("configs.new"), systemImage: "doc.badge.plus") }
            Button { urlText = ""; showURL = true } label: { Label(L("configs.from_url"), systemImage: "link") }
            Button { Task { await paste() } } label: { Label(L("configs.from_clipboard"), systemImage: "doc.on.clipboard") }
            Button { importing = true } label: { Label(L("configs.from_file"), systemImage: "folder") }
          } label: {
            if working { ProgressView() } else { Image(systemName: "plus") }
          }
          .accessibilityLabel(L("configs.add"))
        }
      }
      .alert(L("configs.from_url"), isPresented: $showURL) {
        TextField("https://", text: $urlText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        Button(L("common.cancel"), role: .cancel) {}
        Button(L("common.add")) { Task { await addURL() } }
      } message: {
        Text(L("configs.from_url_hint"))
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data], allowsMultipleSelection: false) { result in
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 2 << 20, let text = String(data: data, encoding: .utf8) else {
          model.show(CoreError(code: "unsupported_format", detail: nil))
          return
        }
        let name = url.deletingPathExtension().lastPathComponent
        Task { await save(name: name, text: text) }
      }
      .task { await model.loadGeo() }
    }
  }

  private var geoSummary: String {
    guard let geo = model.geo else { return "" }
    if !geo.ip.present && !geo.site.present { return L("geo.absent") }
    return Format.bytes(geo.ip.bytes + geo.site.bytes)
  }

  private func row(_ c: CoreConfig) -> some View {
    HStack(spacing: 12) {
      Image(systemName: c.provided ? "shippingbox" : (c.remote ? "icloud.and.arrow.down" : "doc.text"))
        .foregroundStyle(Theme.glowCool)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(c.name).lineLimit(1)
        Text([LF("configs.rules", c.rules), c.host ?? "", c.provided ? L("configs.provided") : "", c.lastError.map { CoreError.message(code: $0) } ?? ""]
          .filter { !$0.isEmpty }.joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(c.lastError == nil ? Color.secondary : Theme.poor)
          .lineLimit(1)
      }
      Spacer()
      if c.active {
        Text(model.state.settings.mode == "config" ? L("configs.active") : L("configs.selected"))
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Theme.good.opacity(model.state.settings.mode == "config" ? 0.25 : 0.1), in: Capsule())
          .foregroundStyle(Theme.good)
      }
    }
  }

  private func create() async {
    await save(name: L("configs.new_name"), text: ConfigTemplates.empty)
  }

  private func save(name: String, text: String) async {
    working = true
    defer { working = false }
    do {
      let result: ConfigSaveResult = try await Core.call("saveConfig", ["name": name, "text": text])
      model.state = result.state
      path.append(result.id)
    } catch { model.show(error) }
  }

  private func addURL() async {
    let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { return }
    working = true
    defer { working = false }
    do {
      let result: ConfigSaveResult = try await Core.call("addConfigURL", ["url": url, "name": ""])
      model.state = result.state
      path.append(result.id)
    } catch { model.show(error) }
  }

  private func paste() async {
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      model.info(L("add.clipboard_empty"))
      return
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("happ://routing/") {
      _ = await model.importInput(trimmed)
      return
    }
    if trimmed.lowercased().hasPrefix("https://") && !trimmed.contains("\n") {
      urlText = trimmed
      await addURL()
      return
    }
    await save(name: L("configs.pasted_name"), text: text)
  }

  private func delete(_ c: CoreConfig) async {
    do { model.state = try await Core.call("deleteConfig", ["id": c.id]) } catch { model.show(error) }
  }

  private func update(_ c: CoreConfig) async {
    working = true
    defer { working = false }
    do {
      let result: ConfigSaveResult = try await Core.call("updateConfig", ["id": c.id])
      model.state = result.state
      model.info(L("configs.updated"))
    } catch { model.show(error) }
  }
}

enum ConfigTemplates {
  static let empty = """
  # New config
  [General]
  bypass-system = true
  dns-server = system

  [Rule]
  FINAL,PROXY

  [Host]

  """
}

struct ConfigEditorView: View {
  let id: String
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var detail: ConfigDetail?
  @State private var text = ""
  @State private var name = ""
  @State private var report: ConfigReport?
  @State private var dirty = false
  @State private var saving = false
  @State private var addRule = false
  @State private var confirmDelete = false
  @State private var confirmReset = false

  var body: some View {
    VStack(spacing: 0) {
      if detail == nil {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        TextField(L("configs.name"), text: $name)
          .font(Theme.label(.headline))
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .onChange(of: name) { _ in dirty = true }
        Divider().overlay(Theme.line)
        TextEditor(text: $text)
          .font(.system(size: 13, design: .monospaced))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .scrollContentBackground(.hidden)
          .padding(.horizontal, 10)
          .onChange(of: text) { _ in dirty = true }
        if let report = report {
          ReportView(report: report)
        }
      }
    }
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(detail?.config.name ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button { addRule = true } label: { Image(systemName: "text.badge.plus") }
          .accessibilityLabel(L("rule.add"))
        Menu {
          if detail?.config.active != true || model.state.settings.mode != "config" {
            Button { Task { await save(); await model.activateConfig(id) } } label: { Label(L("configs.use"), systemImage: "checkmark.circle") }
          }
          Button { Task { await check() } } label: { Label(L("configs.check"), systemImage: "checkmark.seal") }
          if detail?.config.remote == true {
            Button { Task { await update() } } label: { Label(L("configs.update"), systemImage: "arrow.clockwise") }
          }
          ShareLink(item: text) { Label(L("configs.share"), systemImage: "square.and.arrow.up") }
          Button { UIPasteboard.general.string = text; model.info(L("common.copied")) } label: { Label(L("common.copy"), systemImage: "doc.on.doc") }
          if detail?.config.builtin == true {
            Button(role: .destructive) { confirmReset = true } label: { Label(L("configs.reset"), systemImage: "arrow.uturn.backward") }
          } else {
            Button(role: .destructive) { confirmDelete = true } label: { Label(L("common.delete"), systemImage: "trash") }
          }
        } label: { Image(systemName: "ellipsis.circle") }
        Button { Task { await save() } } label: {
          if saving { ProgressView() } else { Text(L("common.save")).bold() }
        }
        .disabled(!dirty || saving)
      }
    }
    .sheet(isPresented: $addRule) {
      AddRuleView { line in
        text = ConfigTemplates.insertRule(line, into: text)
        dirty = true
      }
      .preferredColorScheme(Palette.current.isLight ? .light : .dark)
    }
    .confirmationDialog(L("configs.delete_confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
      Button(L("common.delete"), role: .destructive) { Task { await delete() } }
    }
    .confirmationDialog(L("configs.reset_confirm"), isPresented: $confirmReset, titleVisibility: .visible) {
      Button(L("configs.reset"), role: .destructive) { Task { await reset() } }
    }
    .task { await load() }
  }

  private func load() async {
    do {
      let d: ConfigDetail = try await Core.call("getConfig", ["id": id])
      detail = d
      text = d.text
      name = d.config.name
      report = d.report
      try? await Task.sleep(nanoseconds: 50_000_000)
      dirty = false
    } catch { model.show(error) }
  }

  private func save() async {
    guard dirty else { return }
    saving = true
    defer { saving = false }
    do {
      let result: ConfigSaveResult = try await Core.call("saveConfig", ["id": id, "name": name, "text": text])
      model.state = result.state
      report = result.report
      dirty = false
      Haptics.success()
      if model.vpnConnectedWithConfig(id) {
        model.info(L("settings.reconnect_hint"), actionTitle: L("settings.reconnect")) { Task { await model.connect() } }
      }
    } catch { model.show(error) }
  }

  private func check() async {
    do { report = try await Core.call("checkConfig", ["text": text]) } catch { model.show(error) }
  }

  private func update() async {
    saving = true
    defer { saving = false }
    do {
      let result: ConfigSaveResult = try await Core.call("updateConfig", ["id": id])
      model.state = result.state
      await load()
      model.info(L("configs.updated"))
    } catch { model.show(error) }
  }

  private func delete() async {
    do {
      model.state = try await Core.call("deleteConfig", ["id": id])
      dismiss()
    } catch { model.show(error) }
  }

  private func reset() async {
    do {
      model.state = try await Core.call("resetConfig", ["id": id])
      await load()
    } catch { model.show(error) }
  }
}

extension ConfigTemplates {
  /// Inserts a rule line before FINAL inside [Rule], creating the section when needed.
  static func insertRule(_ line: String, into text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    var section = ""
    var ruleStart: Int?
    var ruleEnd: Int?
    for (i, raw) in lines.enumerated() {
      let l = raw.trimmingCharacters(in: .whitespaces)
      if l.hasPrefix("[") && l.hasSuffix("]") {
        if section == "[rule]" { ruleEnd = i }
        section = l.lowercased()
        if section == "[rule]" { ruleStart = i }
        continue
      }
      if section == "[rule]" && (l.uppercased().hasPrefix("FINAL,") || l.uppercased().hasPrefix("MATCH,")) {
        lines.insert(line, at: i)
        return lines.joined(separator: "\n")
      }
    }
    if let start = ruleStart {
      let at = ruleEnd ?? lines.count
      var insertAt = at
      while insertAt > start + 1 && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
      lines.insert(line, at: insertAt)
      return lines.joined(separator: "\n")
    }
    return text + (text.hasSuffix("\n") ? "" : "\n") + "\n[Rule]\n" + line + "\nFINAL,PROXY\n"
  }
}

struct ReportView: View {
  let report: ConfigReport
  @EnvironmentObject private var model: AppModel
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button { withAnimation { expanded.toggle() } } label: {
        HStack(spacing: 8) {
          Image(systemName: report.valid ? (report.warnings.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill") : "xmark.octagon.fill")
            .foregroundStyle(report.valid ? (report.warnings.isEmpty ? Theme.good : Theme.fair) : Theme.poor)
          Text(LF("report.summary", report.stats.rules, report.stats.domains, report.stats.ips))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
          Spacer()
          if !report.warnings.isEmpty {
            Text(LF("report.warnings", report.warnings.count)).font(.caption).foregroundStyle(Theme.fair)
          }
          Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.caption2).foregroundStyle(Theme.dim)
        }
      }
      .buttonStyle(.plain)
      if expanded {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            if let error = report.error { Text(error).font(Theme.mono).foregroundStyle(Theme.poor) }
            if report.dnsHijack { Text(L("report.dns_hijack")).font(.caption).foregroundStyle(Theme.dim) }
            Text(LF("report.final", L("policy.\(report.final)"))).font(.caption).foregroundStyle(Theme.dim)
            if let missing = report.missingGeo, !missing.isEmpty {
              HStack {
                Text(LF("report.missing_geo", missing.joined(separator: ", "))).font(.caption).foregroundStyle(Theme.fair)
                Spacer()
                Button(L("geo.download")) { Task { await model.updateGeo() } }.font(.caption.weight(.semibold))
              }
            }
            ForEach(Array(report.warnings.prefix(80).enumerated()), id: \.offset) { _, w in
              Text("\(L("report.line")) \(w.line): \(L("config.warn.\(w.code)")) \(w.text ?? "")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
            }
            if !report.ignored.isEmpty {
              Text(LF("report.ignored", report.ignored.joined(separator: ", "))).font(.caption).foregroundStyle(Theme.dim)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
      }
    }
    .padding(12)
    .background(.ultraThinMaterial)
  }
}

struct AddRuleView: View {
  var onAdd: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var type = "DOMAIN-SUFFIX"
  @State private var value = ""
  @State private var policy = "PROXY"
  @State private var noResolve = true

  private let types = ["DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD", "IP-CIDR", "IP-CIDR6", "GEOIP", "GEOSITE", "DST-PORT", "RULE-SET", "DOMAIN-SET"]

  private var line: String {
    var l = "\(type),\(value.trimmingCharacters(in: .whitespaces)),\(policy)"
    if (type == "IP-CIDR" || type == "IP-CIDR6" || type == "GEOIP") && noResolve { l += ",no-resolve" }
    return l
  }

  var body: some View {
    NavigationStack {
      Form {
        Picker(L("rule.type"), selection: $type) {
          ForEach(types, id: \.self) { Text($0).tag($0) }
        }
        TextField(placeholder, text: $value)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Picker(L("rule.policy"), selection: $policy) {
          Text("PROXY").tag("PROXY")
          Text("DIRECT").tag("DIRECT")
          Text("REJECT").tag("REJECT")
        }
        .pickerStyle(.segmented)
        if type == "IP-CIDR" || type == "IP-CIDR6" || type == "GEOIP" {
          Toggle("no-resolve", isOn: $noResolve)
        }
        Section {
          Text(line).font(Theme.mono)
        } footer: {
          Text(L("rule.footer"))
        }
      }
      .navigationTitle(L("rule.add"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) { Button(L("common.cancel")) { dismiss() } }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(L("common.add")) {
            onAdd(line)
            dismiss()
          }
          .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }

  private var placeholder: String {
    switch type {
    case "IP-CIDR": return "1.2.3.0/24"
    case "IP-CIDR6": return "2001:db8::/32"
    case "GEOIP": return "RU"
    case "GEOSITE": return "category-ads-all"
    case "DST-PORT": return "443"
    case "RULE-SET", "DOMAIN-SET": return "https://…"
    case "DOMAIN-KEYWORD": return "google"
    case "DOMAIN-WILDCARD": return "*.example.com"
    default: return "example.com"
    }
  }
}
