import CoreLocation
import NetworkExtension
import SwiftUI
import UIKit
import UserNotifications

struct SettingsTab: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @EnvironmentObject private var prefs: AppPrefs
  @StateObject private var location = LocationPermission()
  @State private var notifications: UNAuthorizationStatus = .notDetermined
  @State private var confirmReset = false

  init() {}

  var body: some View {
    NavigationStack {
      Form {
        Section {
          NavigationLink { LanguageView() } label: {
            row(L("settings.language_title"), icon: "globe", value: languageName)
          }
        }

        Section(L("settings.advanced")) {
          Picker(selection: setting(\.testMethod, "testMethod")) {
            Text("TCP").tag("tcp")
            Text(L("settings.test_proxy")).tag("proxy")
          } label: {
            Label(L("settings.test_method"), systemImage: "speedometer")
          }
          unavailable(L("settings.widget"), icon: "square.grid.2x2")
          NavigationLink { ShortcutsInfoView() } label: { Label(L("settings.shortcuts"), systemImage: "square.stack.3d.up") }
          Button { model.sheet = .diagnostics } label: { Label(L("diag.title"), systemImage: "stethoscope") }
          NavigationLink { AppearanceView() } label: { Label(L("settings.appearance"), systemImage: "paintpalette") }
        }

        Section(L("settings.tunnel_section")) {
          NavigationLink { OnDemandView() } label: {
            row(L("settings.on_demand"), icon: "bolt.badge.automatic", value: prefs.onDemand ? L("common.on") : L("common.off"))
          }
          NavigationLink { TunnelSettingsView() } label: { Label(L("settings.tunnel"), systemImage: "point.3.connected.trianglepath.dotted") }
          NavigationLink { ProxyShareView() } label: {
            row(L("settings.proxy"), icon: "antenna.radiowaves.left.and.right", value: model.state.settings.proxyShare ? "\(model.state.settings.proxyPort)" : L("common.off"))
          }
          NavigationLink { TCPSettingsView() } label: { Label("TCP", systemImage: "arrow.left.arrow.right.square") }
          NavigationLink { UDPSettingsView() } label: { Label("UDP", systemImage: "arrow.up.arrow.down.square") }
          unavailable("Tailscale", icon: "circle.grid.3x3")
        }

        Section {
          Button { location.request() } label: {
            row(L("perm.location"), icon: "location", value: location.statusText)
          }
          Button { Task { await requestNotifications() } } label: {
            row(L("perm.notifications"), icon: "bell.badge", value: notificationText)
          }
          Toggle(isOn: $prefs.pasteboardDetect) { Label(L("perm.pasteboard"), systemImage: "doc.on.clipboard") }
        } header: {
          Text(L("settings.permissions"))
        } footer: {
          Text(L("perm.footer"))
        }

        Section(L("settings.update")) {
          Toggle(isOn: setting(\.autoUpdateConfigs, "autoUpdateConfigs")) { Label(L("update.config"), systemImage: "doc.text") }
          unavailable(L("update.modules"), icon: "puzzlepiece.extension")
          NavigationLink { SubscriptionUpdateView() } label: { Label(L("update.subscription"), systemImage: "arrow.triangle.2.circlepath") }
          NavigationLink { GeoView() } label: { Label(L("update.geo"), systemImage: "globe.europe.africa") }
        }

        Section {
          Toggle(isOn: $prefs.vpnReminder) { Label(L("misc.vpn_reminder"), systemImage: "bell") }
          unavailable(L("misc.moderated_policy"), icon: "checkmark.shield")
          Toggle(isOn: $prefs.autorotate) { Label(L("misc.autorotate"), systemImage: "rotate.right") }
          Toggle(isOn: $prefs.thirdPartyKeyboard) { Label(L("misc.keyboard"), systemImage: "keyboard") }
          Toggle(isOn: setting(\.hideVpnIcon, "hideVpnIcon", hint: true)) {
            VStack(alignment: .leading, spacing: 2) {
              Label(L("misc.exclude_routes"), systemImage: "eye.slash")
              Text("0.0.0.0/31").font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
            }
          }
          Toggle(isOn: setting(\.loopbackRoute, "loopbackRoute", hint: true)) {
            VStack(alignment: .leading, spacing: 2) {
              Label(L("misc.include_routes"), systemImage: "arrow.uturn.left.circle")
              Text("10.7.0.1/32").font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
            }
          }
          Toggle(isOn: $prefs.haptics) { Label(L("misc.haptics"), systemImage: "hand.tap") }
        } header: {
          Text(L("settings.misc"))
        } footer: {
          Text(L("misc.footer"))
        }

        Section {
          Button(role: .destructive) { confirmReset = true } label: { Label(L("settings.reset_title"), systemImage: "arrow.counterclockwise") }
          NavigationLink { AboutView() } label: { Label(L("settings.about"), systemImage: "info.circle") }
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.space.ignoresSafeArea())
      .navigationTitle(L("tab.settings"))
      .confirmationDialog(L("settings.reset_title"), isPresented: $confirmReset, titleVisibility: .visible) {
        Button(L("settings.reset_settings")) { Task { await model.resetSettings() } }
        Button(L("settings.reset"), role: .destructive) { Task { await model.resetAll() } }
      } message: {
        Text(L("settings.reset_message"))
      }
      .task { await refreshNotificationStatus() }
    }
  }

  private var languageName: String {
    switch prefs.language {
    case "ru": return "Русский"
    case "en": return "English"
    default: return L("language.system")
    }
  }

  private var notificationText: String {
    switch notifications {
    case .authorized, .provisional, .ephemeral: return L("perm.allowed")
    case .denied: return L("perm.denied")
    default: return L("perm.not_asked")
    }
  }

  private func refreshNotificationStatus() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    notifications = settings.authorizationStatus
  }

  private func requestNotifications() async {
    if notifications == .denied {
      if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
      return
    }
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    await refreshNotificationStatus()
  }

  private func row(_ title: String, icon: String, value: String) -> some View {
    HStack {
      Label(title, systemImage: icon).foregroundStyle(.primary)
      Spacer()
      Text(value).foregroundStyle(.secondary).lineLimit(1)
    }
  }

  private func unavailable(_ title: String, icon: String) -> some View {
    HStack {
      Label(title, systemImage: icon)
      Spacer()
      Text(L("common.unavailable")).font(.caption).foregroundStyle(.secondary)
    }
    .foregroundStyle(.secondary)
  }

  private func setting<T>(_ path: WritableKeyPath<CoreSettings, T>, _ key: String, hint: Bool = false) -> Binding<T> {
    Binding(
      get: { model.state.settings[keyPath: path] },
      set: { value in Task { await model.updateSettings([key: value], reconnectHint: hint) } }
    )
  }
}

/// Settings binding helper shared by the subviews.
struct SettingBinding {
  static func make<T>(_ model: AppModel, _ path: WritableKeyPath<CoreSettings, T>, _ key: String, hint: Bool = true) -> Binding<T> {
    Binding(
      get: { model.state.settings[keyPath: path] },
      set: { value in Task { await model.updateSettings([key: value], reconnectHint: hint) } }
    )
  }
}

final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  @Published var status: CLAuthorizationStatus

  override init() {
    status = manager.authorizationStatus
    super.init()
    manager.delegate = self
  }

  func request() {
    if status == .denied || status == .restricted {
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      return
    }
    manager.requestWhenInUseAuthorization()
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    DispatchQueue.main.async { self.status = manager.authorizationStatus }
  }

  var statusText: String {
    switch status {
    case .authorizedAlways, .authorizedWhenInUse: return L("perm.allowed")
    case .denied, .restricted: return L("perm.denied")
    default: return L("perm.not_asked")
    }
  }

  var allowed: Bool { status == .authorizedAlways || status == .authorizedWhenInUse }
}

struct LanguageView: View {
  @EnvironmentObject private var prefs: AppPrefs

  var body: some View {
    Form {
      Picker(L("settings.language_title"), selection: $prefs.language) {
        Text(L("language.system")).tag("system")
        Text("Русский").tag("ru")
        Text("English").tag("en")
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("settings.language_title"))
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct AppearanceView: View {
  @EnvironmentObject private var prefs: AppPrefs

  var body: some View {
    Form {
      Section {
        Toggle(L("appearance.motion"), isOn: $prefs.galaxyMotion)
        Toggle(L("appearance.parallax"), isOn: $prefs.parallax)
        Toggle(L("appearance.ping"), isOn: $prefs.showPing)
        Toggle(L("appearance.probe_launch"), isOn: $prefs.probeOnLaunch)
      } footer: {
        Text(L("appearance.footer"))
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("settings.appearance"))
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct ShortcutsInfoView: View {
  var body: some View {
    Form {
      Section {
        Label(L("shortcuts.connect"), systemImage: "bolt.fill")
        Label(L("shortcuts.disconnect"), systemImage: "bolt.slash.fill")
        Label(L("shortcuts.toggle"), systemImage: "arrow.triangle.2.circlepath")
      } footer: {
        Text(L("shortcuts.footer"))
      }
      Section {
        ForEach(["paradise://connect", "paradise://disconnect", "paradise://toggle"], id: \.self) { link in
          HStack {
            Text(link).font(Theme.mono)
            Spacer()
            Button { UIPasteboard.general.string = link } label: { Image(systemName: "doc.on.doc") }
              .accessibilityLabel(L("common.copy"))
          }
        }
      } header: {
        Text(L("shortcuts.links"))
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("settings.shortcuts"))
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct OnDemandView: View {
  @EnvironmentObject private var prefs: AppPrefs
  @EnvironmentObject private var vpn: VPNController
  @EnvironmentObject private var model: AppModel
  @StateObject private var location = LocationPermission()
  @State private var newSSID = ""

  var body: some View {
    Form {
      Section {
        Toggle(L("ondemand.enable"), isOn: $prefs.onDemand)
        if prefs.onDemand {
          Picker(L("ondemand.when"), selection: $prefs.onDemandMode) {
            Text(L("ondemand.always")).tag("always")
            Text("Wi-Fi").tag("wifi")
            Text(L("ondemand.cellular")).tag("cellular")
          }
        }
      } footer: {
        Text(L("ondemand.footer"))
      }
      if prefs.onDemand {
        Section {
          ForEach(prefs.trustedSSIDs, id: \.self) { ssid in Text(ssid) }
            .onDelete { prefs.trustedSSIDs.remove(atOffsets: $0) }
          HStack {
            TextField(L("ondemand.ssid"), text: $newSSID).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(L("common.add")) {
              let s = newSSID.trimmingCharacters(in: .whitespaces)
              if !s.isEmpty && !prefs.trustedSSIDs.contains(s) { prefs.trustedSSIDs.append(s) }
              newSSID = ""
            }
            .disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
          }
          Button(L("ondemand.current")) { addCurrent() }
        } header: {
          Text(L("ondemand.trusted"))
        } footer: {
          Text(L("ondemand.trusted_footer"))
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("settings.on_demand"))
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: prefs.onDemand) { _ in Task { await vpn.updateOnDemand() } }
    .onChange(of: prefs.onDemandMode) { _ in Task { await vpn.updateOnDemand() } }
    .onChange(of: prefs.trustedSSIDs) { _ in Task { await vpn.updateOnDemand() } }
  }

  private func addCurrent() {
    if !location.allowed {
      location.request()
      return
    }
    NEHotspotNetwork.fetchCurrent { network in
      DispatchQueue.main.async {
        guard let ssid = network?.ssid, !ssid.isEmpty else {
          model.info(L("ondemand.no_ssid"))
          return
        }
        if !prefs.trustedSSIDs.contains(ssid) { prefs.trustedSSIDs.append(ssid) }
      }
    }
  }
}

struct TunnelSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var dnsText = ""
  @State private var mtuText = ""

  var body: some View {
    Form {
      Section {
        Toggle(L("settings.kill_switch"), isOn: SettingBinding.make(model, \.killSwitch, "killSwitch"))
        Toggle(L("tunnel.exclude_local"), isOn: SettingBinding.make(model, \.excludeLocal, "excludeLocal"))
        Toggle(L("tunnel.exclude_apns"), isOn: SettingBinding.make(model, \.excludeApns, "excludeApns"))
      } footer: {
        Text(L("settings.kill_switch_footer"))
      }
      Section {
        Toggle("IPv6", isOn: SettingBinding.make(model, \.ipv6, "ipv6"))
        Toggle(L("tunnel.sniffing"), isOn: SettingBinding.make(model, \.sniffing, "sniffing"))
        HStack {
          Text("MTU")
          Spacer()
          TextField("1500", text: $mtuText)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
            .onSubmit { saveMTU() }
        }
      } footer: {
        Text(L("tunnel.footer"))
      }
      Section {
        TextField("1.1.1.1, 8.8.8.8", text: $dnsText)
          .keyboardType(.numbersAndPunctuation)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onSubmit { saveDNS() }
        Button(L("common.save")) { saveDNS(); saveMTU() }
      } header: {
        Text("DNS")
      } footer: {
        Text(L("tunnel.dns_footer"))
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("settings.tunnel"))
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      dnsText = model.state.settings.dns.joined(separator: ", ")
      mtuText = "\(model.state.settings.mtu)"
    }
  }

  private func saveDNS() {
    let list = dnsText.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    Task {
      await model.updateSettings(["dns": list], reconnectHint: true)
      dnsText = model.state.settings.dns.joined(separator: ", ")
    }
  }

  private func saveMTU() {
    guard let mtu = Int(mtuText) else { mtuText = "\(model.state.settings.mtu)"; return }
    Task {
      await model.updateSettings(["mtu": mtu], reconnectHint: true)
      mtuText = "\(model.state.settings.mtu)"
    }
  }
}

struct ProxyShareView: View {
  @EnvironmentObject private var model: AppModel
  @State private var portText = ""

  var body: some View {
    Form {
      Section {
        Toggle(L("proxy.enable"), isOn: SettingBinding.make(model, \.proxyShare, "proxyShare"))
        HStack {
          Text(L("proxy.port"))
          Spacer()
          TextField("1080", text: $portText)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
            .onSubmit { savePort() }
        }
        Toggle(L("proxy.lan"), isOn: SettingBinding.make(model, \.proxyLan, "proxyLan"))
      } footer: {
        Text(L("proxy.footer"))
      }
      if model.state.settings.proxyShare {
        Section(L("proxy.address")) {
          Text("127.0.0.1:\(model.state.settings.proxyPort)").font(Theme.mono)
          if model.state.settings.proxyLan, let ip = Self.wifiAddress() {
            Text("\(ip):\(model.state.settings.proxyPort)").font(Theme.mono)
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("settings.proxy"))
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { portText = "\(model.state.settings.proxyPort)" }
    .onDisappear { savePort() }
  }

  private func savePort() {
    guard let port = Int(portText), port != model.state.settings.proxyPort else { return }
    Task {
      await model.updateSettings(["proxyPort": port], reconnectHint: true)
      portText = "\(model.state.settings.proxyPort)"
    }
  }

  /// The device address on Wi-Fi (en0), for sharing the proxy on the local network.
  static func wifiAddress() -> String? {
    var result: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
      let iface = p.pointee
      if let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: iface.ifa_name) == "en0" {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
          result = String(cString: host)
        }
      }
      ptr = iface.ifa_next
    }
    return result
  }
}

struct TCPSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var length = ""
  @State private var interval = ""

  var body: some View {
    Form {
      Section {
        Toggle("TCP Fast Open", isOn: SettingBinding.make(model, \.tcpFastOpen, "tcpFastOpen"))
        Picker(L("tcp.keepalive"), selection: SettingBinding.make(model, \.keepAlive, "keepAlive")) {
          Text(L("tcp.keepalive_system")).tag(0)
          Text("15 s").tag(15)
          Text("30 s").tag(30)
          Text("60 s").tag(60)
          Text("120 s").tag(120)
        }
        Toggle(L("tcp.mux"), isOn: SettingBinding.make(model, \.mux, "mux"))
      } footer: {
        Text(L("tcp.footer"))
      }
      Section {
        Toggle(L("tcp.fragment"), isOn: SettingBinding.make(model, \.fragment, "fragment"))
        if model.state.settings.fragment {
          Picker(L("tcp.fragment_packets"), selection: SettingBinding.make(model, \.fragmentPackets, "fragmentPackets")) {
            Text("TLS Hello").tag("tlshello")
            Text("1-3").tag("1-3")
          }
          HStack {
            Text(L("tcp.fragment_length"))
            Spacer()
            TextField("100-200", text: $length).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).frame(width: 110)
          }
          HStack {
            Text(L("tcp.fragment_interval"))
            Spacer()
            TextField("10-20", text: $interval).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).frame(width: 110)
          }
          Button(L("common.save")) {
            Task { await model.updateSettings(["fragmentLength": length, "fragmentInterval": interval], reconnectHint: true) }
          }
        }
      } header: {
        Text(L("tcp.anticensorship"))
      } footer: {
        Text(L("tcp.fragment_footer"))
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle("TCP")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      length = model.state.settings.fragmentLength
      interval = model.state.settings.fragmentInterval
    }
  }
}

struct UDPSettingsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section {
        Toggle(L("udp.relay"), isOn: SettingBinding.make(model, \.udpRelay, "udpRelay"))
        Toggle(L("udp.block_quic"), isOn: SettingBinding.make(model, \.blockQuic, "blockQuic"))
      } footer: {
        Text(L("udp.footer"))
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle("UDP")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct SubscriptionUpdateView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section {
        Toggle(L("settings.auto_refresh"), isOn: SettingBinding.make(model, \.autoRefresh, "autoRefresh", hint: false))
        Picker(L("update.interval"), selection: SettingBinding.make(model, \.refreshHours, "refreshHours", hint: false)) {
          Text(L("update.interval_launch")).tag(0)
          Text(LF("update.hours", 1)).tag(1)
          Text(LF("update.hours", 6)).tag(6)
          Text(LF("update.hours", 12)).tag(12)
          Text(LF("update.hours", 24)).tag(24)
        }
        Button {
          Task { await model.refreshAll() }
        } label: {
          HStack {
            Text(L("update.now"))
            Spacer()
            if model.refreshing { ProgressView() }
          }
        }
        .disabled(model.refreshing)
      } footer: {
        Text(L("update.footer"))
      }
      Section {
        Toggle(L("settings.send_hwid"), isOn: SettingBinding.make(model, \.sendHwid, "sendHwid", hint: false))
        if !model.state.hwid.isEmpty {
          HStack {
            Text(L("settings.hwid"))
            Spacer()
            Text(String(model.state.hwid.prefix(8)) + "…").font(Theme.mono).foregroundStyle(.secondary)
          }
          .contextMenu { Button(L("common.copy")) { UIPasteboard.general.string = model.state.hwid } }
        }
      } footer: {
        Text(L("settings.send_hwid_footer"))
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("update.subscription"))
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct AboutView: View {
  @State private var showLicenses = false

  private var version: String {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(v) (\(b))"
  }

  var body: some View {
    Form {
      Section {
        HStack(spacing: 14) {
          Image("Logo").resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          VStack(alignment: .leading, spacing: 3) {
            Text("Paradise").font(Theme.title(.title3))
            Text(version).font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
      }
      Section {
        LabeledContent(L("settings.version"), value: version)
        LabeledContent("Xray-core", value: Core.isOpen ? Core.xrayVersion : "—")
        Button(L("settings.licenses")) { showLicenses = true }
      } footer: {
        Text(L("settings.privacy"))
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("settings.about"))
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showLicenses) { LicensesView().preferredColorScheme(.dark) }
  }
}
