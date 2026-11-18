import NetworkExtension
import SwiftUI
import UIKit

/// Positions on screen, derived from the mock: the top block follows the status bar,
/// the panel and action bar follow the bottom edge, the map takes what is left.
struct HomeLayout {
  let width: CGFloat
  let height: CGFloat
  let s: RefScale
  let topOffset: CGFloat
  let bottomAnchor: CGFloat

  init(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
    width = size.width
    height = size.height
    s = RefScale(width: size.width)
    topOffset = safeTop - DS.Geo.refStatusBarBottom * s.u
    bottomAnchor = size.height - max(DS.Geo.refBottomGap * s.u, safeBottom + 8)
  }

  /// y of a reference coordinate in the top block
  func top(_ y: CGFloat) -> CGFloat { topOffset + y * s.u }
  /// y of a reference coordinate in the bottom block (anchored to the action bar)
  func bottom(_ y: CGFloat) -> CGFloat { bottomAnchor - (DS.Geo.actionBarBottom - y) * s.u }

  var mapTop: CGFloat { top(DS.Geo.infoBottom) }
  var standardPanelTop: CGFloat { bottom(DS.Geo.panelTop) }
  var collapsedPanelTop: CGFloat { bottom(DS.Geo.actionBarTop) - s(76) }
  var fullPanelTop: CGFloat { top(DS.Geo.infoBottom) + s(6) }

  func panelTop(_ detent: ServerPanel.Detent) -> CGFloat {
    switch detent {
    case .collapsed: return collapsedPanelTop
    case .standard: return standardPanelTop
    case .full: return fullPanelTop
    }
  }
}

/// Measures the screen and lays out the home screen for it.
struct HomeView: View {
  init() {}

  var body: some View {
    GeometryReader { geo in
      let insets = Self.insets(geo.safeAreaInsets)
      // phone proportions; on iPad and in landscape the screen becomes a centered column
      let column = CGSize(width: min(geo.size.width, max(320, geo.size.height * 0.57)), height: geo.size.height)
      HomeScreen(layout: HomeLayout(size: column, safeTop: insets.top, safeBottom: insets.bottom))
        .frame(width: geo.size.width, height: geo.size.height)
    }
    .ignoresSafeArea()
  }

  /// Safe-area insets of the window (they don't change while the keyboard is up), else the reader's.
  static func insets(_ proxy: EdgeInsets) -> (top: CGFloat, bottom: CGFloat) {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    if let window = windows.first(where: \.isKeyWindow) ?? windows.first, window.safeAreaInsets.top > 0 {
      return (window.safeAreaInsets.top, window.safeAreaInsets.bottom)
    }
    return (proxy.top, proxy.bottom)
  }
}

/// The home screen for one layout. It reads the model in its own body, so it follows every change.
struct HomeScreen: View {
  let layout: HomeLayout
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @EnvironmentObject private var prefs: AppPrefs
  @State private var detent: ServerPanel.Detent = Demo.initialDetent
  @GestureState private var panelDrag: CGFloat = 0
  @State private var countryFilter: String?

  var body: some View {
    let s = layout.s
    let panelTop = min(layout.collapsedPanelTop, max(layout.fullPanelTop, layout.panelTop(detent) + panelDrag))
    let nodes = model.countryNodes
    let showEmptyHint = model.state.servers.isEmpty && !model.loading
    ZStack(alignment: .topLeading) {
      DS.background
      if model.storageBroken {
        storageNotice.padding(.horizontal, s(31)).offset(y: layout.top(260))
      } else {
        NetworkMapView(nodes: nodes, highlighted: highlightedCC, connected: vpn.isConnected,
                       animate: prefs.galaxyMotion && model.demo == nil, parallax: prefs.parallax, s: s,
                       onNode: { node in Task { await model.connect(country: node) } },
                       onNodeList: { node in
                         countryFilter = node.cc
                         detent = .full
                       })
          .frame(width: layout.width, height: max(0, layout.standardPanelTop - layout.mapTop))
          .offset(y: layout.mapTop)
        if showEmptyHint {
          emptyHint(s).frame(width: layout.width).offset(y: layout.mapTop + s(150))
        }
      }
      header
      StatusCard(s: s, onSelect: { detent = .full })
        .frame(width: s(DS.Geo.card.width), height: s(DS.Geo.card.height))
        .offset(x: s(DS.Geo.card.minX), y: layout.top(DS.Geo.card.minY))
      InfoRow(s: s)
        .frame(width: layout.width, height: s(44), alignment: .topLeading)
        .offset(y: layout.top(DS.Geo.infoLabelTop - 1))
      ServerPanel(detent: $detent, countryFilter: $countryFilter, layout: layout, panelTop: panelTop)
        .frame(width: layout.width - s(DS.Geo.panelInset * 2), height: max(0, layout.height - panelTop), alignment: .top)
        .offset(x: s(DS.Geo.panelInset), y: panelTop)
        .simultaneousGesture(panelGesture, including: .all)
      ActionBar(s: s)
        .frame(width: layout.width, height: s(DS.Geo.actionBarBottom - DS.Geo.actionBarTop), alignment: .topLeading)
        .offset(y: layout.bottom(DS.Geo.actionBarTop))
      if model.loading {
        ProgressView().tint(.white).frame(width: layout.width, height: layout.height)
      }
    }
    .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    .animation(.spring(response: 0.42, dampingFraction: 0.88), value: detent)
  }

  private var highlightedCC: String? { model.currentServer?.cc }

  private var panelGesture: some Gesture {
    DragGesture(minimumDistance: 10)
      .updating($panelDrag) { v, state, _ in
        // only vertical drags that start on the handle area move the panel
        guard abs(v.translation.height) > abs(v.translation.width), v.startLocation.y < layout.s(70) else { return }
        state = v.translation.height
      }
      .onEnded { v in
        guard abs(v.translation.height) > abs(v.translation.width), v.startLocation.y < layout.s(70) else { return }
        let current = layout.panelTop(detent) + v.translation.height + (v.predictedEndTranslation.height - v.translation.height) * 0.25
        let candidates: [ServerPanel.Detent] = [.full, .standard, .collapsed]
        let next = candidates.min { abs(layout.panelTop($0) - current) < abs(layout.panelTop($1) - current) } ?? .standard
        if next != detent { Haptics.selection() }
        detent = next
      }
  }

  // MARK: Header

  private var header: some View {
    let s = layout.s
    let cy = layout.top(DS.Geo.headerCenterY)
    return ZStack(alignment: .topLeading) {
      GlobeLogo(diameter: s(DS.Geo.logoDiameter))
        .offset(x: s(DS.Geo.logoCenterX - DS.Geo.logoDiameter / 2), y: cy - s(DS.Geo.logoDiameter / 2))
        .onLongPressGesture(minimumDuration: 0.8) { model.sheet = .diagnostics }
      Text("Paradise")
        .refFont(s, DS.Size.title, .semibold)
        .foregroundStyle(DS.textPrimary)
        .fixedSize()
        .frame(height: s(24))
        .offset(x: s(DS.Geo.titleX), y: cy - s(12.5))
        .accessibilityAddTraits(.isHeader)
      Text("Pro")
        .refFont(s, DS.Size.badge, .medium)
        .foregroundStyle(DS.textBadge)
        .frame(width: s(DS.Geo.badgeSize.width), height: s(DS.Geo.badgeSize.height))
        .background(DS.badge, in: Capsule())
        .offset(x: s(DS.Geo.badgeX), y: cy - s(DS.Geo.badgeSize.height / 2))
        .accessibilityHidden(true)
      Button { model.sheet = .notifications } label: {
        ZStack(alignment: .topTrailing) {
          Image(systemName: "bell")
            .font(.system(size: s(19), weight: .regular))
            .foregroundStyle(DS.textPrimary)
          if model.unseenNotices > 0 {
            Circle().fill(DS.textPrimary).frame(width: s(5), height: s(5)).offset(x: s(2), y: s(-1))
          }
        }
        .frame(width: s(40), height: s(40))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .offset(x: s(DS.Geo.bellCenterX - 20), y: cy - s(20.5))
      .accessibilityLabel(L("notices.title"))
      .accessibilityIdentifier("header.bell")
      moreMenu(s)
        .offset(x: s(DS.Geo.menuCenterX - 20), y: cy - s(20))
    }
  }

  private func moreMenu(_ s: RefScale) -> some View {
    Menu {
      Button { model.sheet = .add } label: { Label(L("home.add"), systemImage: "plus") }
      Button { Task { await pasteFromClipboard() } } label: { Label(L("empty.paste"), systemImage: "doc.on.clipboard") }
      Button { model.sheet = .export } label: { Label(L("transfer.share"), systemImage: "square.and.arrow.up") }
      Divider()
      Button { Task { await model.refreshAll() } } label: { Label(L("home.refresh"), systemImage: "arrow.clockwise") }
      Button { model.probe(model.state.servers) } label: { Label(L("servers.test"), systemImage: "speedometer") }
      Button { model.sheet = .subscriptions } label: { Label(L("home.subscriptions"), systemImage: "tray.full") }
      Divider()
      Button { model.openControlCenter(.settings) } label: { Label(L("tab.settings"), systemImage: "slider.horizontal.3") }
      Button { model.sheet = .diagnostics } label: { Label(L("diag.title"), systemImage: "stethoscope") }
    } label: {
      HStack(spacing: s(3.5)) {
        ForEach(0..<3, id: \.self) { _ in
          Circle().stroke(DS.textPrimary.opacity(0.85), lineWidth: s(1.4)).frame(width: s(5), height: s(5))
        }
      }
      .frame(width: s(40), height: s(40))
      .contentShape(Rectangle())
    }
    .accessibilityLabel(L("home.more"))
    .accessibilityIdentifier("header.menu")
  }

  private func pasteFromClipboard() async {
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      model.info(L("add.clipboard_empty"))
      return
    }
    _ = await model.importInput(text)
  }

  private func emptyHint(_ s: RefScale) -> some View {
    VStack(spacing: s(12)) {
      Text(L("empty.title")).refFont(s, 17, .semibold).foregroundStyle(DS.textPrimary)
      Text(L("empty.body")).refFont(s, 13).foregroundStyle(DS.textSecondary).multilineTextAlignment(.center)
      HStack(spacing: s(10)) {
        Button { Task { await pasteFromClipboard() } } label: {
          Label(L("empty.paste"), systemImage: "doc.on.clipboard").refFont(s, 13, .semibold)
            .frame(maxWidth: .infinity, minHeight: s(40))
            .foregroundStyle(DS.connectText)
            .background(DS.connectFill, in: RoundedRectangle(cornerRadius: s(11), style: .continuous))
        }
        Button { model.sheet = .add } label: {
          Label(L("empty.other"), systemImage: "qrcode.viewfinder").refFont(s, 13, .semibold)
            .frame(maxWidth: .infinity, minHeight: s(40))
            .foregroundStyle(DS.textPrimary)
            .background(DS.squareButton, in: RoundedRectangle(cornerRadius: s(11), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: s(11), style: .continuous).strokeBorder(DS.squareBorder))
        }
      }
      .buttonStyle(.plain)
    }
    .padding(s(18))
    .background(DS.card, in: RoundedRectangle(cornerRadius: s(DS.Geo.cardRadius), style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: s(DS.Geo.cardRadius), style: .continuous).strokeBorder(DS.cardBorder))
    .padding(.horizontal, s(60))
  }

  private var storageNotice: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("storage.title")).font(.headline).foregroundStyle(DS.textPrimary)
      Text(L("storage.body")).font(.subheadline).foregroundStyle(DS.textSecondary)
      if let e = Core.openError as? CoreError {
        Text("\(e.code) \(e.detail ?? "")").font(Theme.mono).foregroundStyle(DS.textSecondary)
      }
      Button(L("diag.title")) { model.sheet = .diagnostics }
      Button(L("storage.reset"), role: .destructive) { Task { await model.eraseAndRestart() } }
    }
    .padding(16)
    .background(DS.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

// MARK: - Status card

struct StatusCard: View {
  let s: RefScale
  var onSelect: () -> Void
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  var body: some View {
    // read the model here so the card follows it; only the timer is computed in the timeline
    let title = self.title
    let line = subtitleParts
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: s(DS.Geo.cardRadius), style: .continuous).fill(DS.card)
      RoundedRectangle(cornerRadius: s(DS.Geo.cardRadius), style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1)
      Button(action: onSelect) {
        HStack(spacing: 0) {
          Color.clear.frame(width: s(DS.Geo.statusTextX - DS.Geo.card.minX))
          TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: s(5)) {
              Text(title)
                .refFont(s, DS.Size.statusTitle, .semibold)
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier("status.title")
              Text(Self.subtitle(line, now: context.date))
                .refFont(s, DS.Size.statusSubtitle, digits: true)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("status.subtitle")
            }
          }
          Spacer(minLength: s(8))
          if vpn.isConnected, model.rateDown + model.rateUp > 0 {
            VStack(alignment: .trailing, spacing: s(3)) {
              Text("↓ \(Format.rate(model.rateDown))")
              Text("↑ \(Format.rate(model.rateUp))")
            }
            .refFont(s, 11, digits: true)
            .foregroundStyle(DS.textLabel)
            .padding(.trailing, s(14))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("status.rates")
          }
          Image(systemName: "chevron.right")
            .font(.system(size: s(13), weight: .semibold))
            .foregroundStyle(DS.iconLight)
            .padding(.trailing, s(DS.Geo.card.maxX - DS.Geo.chevronCenterX - 3.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(L("home.a11y.servers"))
      PowerButton(s: s)
        .offset(x: s(DS.Geo.powerCenter.x - DS.Geo.card.minX - DS.Geo.powerDiameter / 2))
    }
    .accessibilityElement(children: .contain)
  }

  private var server: CoreServer? { model.currentServer }

  private var title: String {
    switch vpn.status {
    case .connected: return L("status.connected")
    case .reasserting: return L("status.reasserting")
    case .connecting: return L("status.connecting")
    case .disconnecting: return L("status.disconnecting")
    default: return L("status.disconnected")
    }
  }

  /// The second line without the timer, and the start of the timer while connected.
  private var subtitleParts: (text: String, since: Date?) {
    let place = server.map { ServerText.place($0) } ?? ""
    switch vpn.status {
    case .connected, .reasserting:
      return (place, vpn.connectedDate)
    case .connecting, .disconnecting:
      return (place, nil)
    default:
      if !model.online { return (L("home.offline"), nil) }
      return (server == nil ? L("home.choose_server") : place, nil)
    }
  }

  private static func subtitle(_ line: (text: String, since: Date?), now: Date) -> String {
    guard let since = line.since else { return line.text }
    let time = Format.duration(since: since, now: now)
    return line.text.isEmpty ? time : "\(line.text) · \(time)"
  }
}

struct PowerButton: View {
  let s: RefScale
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  var body: some View {
    Button { Task { await model.toggleConnection() } } label: {
      ZStack {
        Circle().fill(vpn.isConnected ? Color.white.opacity(0.12) : DS.powerFill)
        Circle().strokeBorder(DS.powerRing.opacity(vpn.isConnected ? 1 : 0.55), lineWidth: s(1.6))
        if vpn.status == .connecting || vpn.status == .disconnecting {
          ProgressView().tint(DS.textPrimary).scaleEffect(s.u * 1.1)
        } else {
          Image(systemName: "power")
            .font(.system(size: s(17), weight: .regular))
            .foregroundStyle(DS.textPrimary)
        }
      }
      .frame(width: s(DS.Geo.powerDiameter), height: s(DS.Geo.powerDiameter))
      .shadow(color: vpn.isConnected ? Color.white.opacity(0.35) : .clear, radius: s(10))
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(vpn.busy && vpn.status != .connecting)
    .accessibilityLabel(vpn.isActive ? L("home.a11y.disconnect") : L("home.a11y.connect"))
    .accessibilityIdentifier("action.power")
  }
}

// MARK: - Your IP / Location / Protocol

struct InfoRow: View {
  let s: RefScale
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack(alignment: .topLeading) {
      column(L("home.ip"), x: DS.Geo.infoColumns[0]) {
        Text(model.publicIP ?? "—").refFont(s, DS.Size.infoValue, .medium).foregroundStyle(DS.textValue)
          .lineLimit(1).minimumScaleFactor(0.55)
          .frame(maxWidth: s(DS.Geo.infoDividers[0] - DS.Geo.infoColumns[0] - 10), alignment: .leading)
          .accessibilityIdentifier("info.ip")
      }
      divider(x: DS.Geo.infoDividers[0])
      column(L("home.location"), x: DS.Geo.infoColumns[1] - 1) {
        HStack(spacing: s(8)) {
          if let cc = model.publicCountry { RoundFlag(cc: cc, diameter: s(DS.Geo.infoFlagDiameter)) }
          Text(locationText).refFont(s, DS.Size.infoValue, .medium).foregroundStyle(DS.textValue).lineLimit(1).minimumScaleFactor(0.8)
            .accessibilityIdentifier("info.location")
        }
        .frame(maxWidth: s(DS.Geo.infoDividers[1] - DS.Geo.infoColumns[1] - 8), alignment: .leading)
      }
      divider(x: DS.Geo.infoDividers[1])
      ProtocolMenu(s: s)
        .offset(x: s(DS.Geo.infoColumns[2]))
    }
    .accessibilityElement(children: .contain)
  }

  private var locationText: String {
    guard let cc = model.publicCountry else { return "—" }
    let country = Format.country(cc)
    if let city = model.publicCity, !city.isEmpty { return "\(country), \(city)" }
    return country
  }

  private func column<V: View>(_ label: String, x: CGFloat, @ViewBuilder value: () -> V) -> some View {
    VStack(alignment: .leading, spacing: s(5)) {
      Text(label).refFont(s, DS.Size.infoLabel).foregroundStyle(DS.textLabel)
      value()
    }
    .fixedSize(horizontal: false, vertical: true)
    .offset(x: s(x))
  }

  private func divider(x: CGFloat) -> some View {
    Rectangle().fill(DS.infoDivider)
      .frame(width: 1, height: s(DS.Geo.infoDividerSpan.upperBound - DS.Geo.infoDividerSpan.lowerBound))
      .offset(x: s(x), y: s(DS.Geo.infoDividerSpan.lowerBound - DS.Geo.infoLabelTop + 1))
  }
}

struct ProtocolMenu: View {
  let s: RefScale
  @EnvironmentObject private var model: AppModel

  var body: some View {
    let display = model.protocolDisplay
    let families = model.availableProtocols
    let store = model
    return Menu {
      Picker(L("home.protocol"), selection: Binding(get: { store.protocolFilter }, set: { store.setProtocolFilter($0) })) {
        Text(L("protocol.auto")).tag("auto")
        ForEach(families, id: \.self) { family in
          Text(ServerText.familyName(family)).tag(family)
        }
      }
    } label: {
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: s(5)) {
          Text(L("home.protocol")).refFont(s, DS.Size.infoLabel).foregroundStyle(DS.textLabel)
          Text(display).refFont(s, DS.Size.infoValue, .medium).foregroundStyle(DS.textValue).lineLimit(1)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.down")
          .font(.system(size: s(10), weight: .semibold))
          .foregroundStyle(DS.iconLight)
          .padding(.top, s(8))
          .padding(.trailing, s(DS.refWidth - 600))
      }
      .frame(width: s(DS.refWidth - DS.Geo.infoColumns[2]), alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityLabel("\(L("home.protocol")): \(display)")
    .accessibilityIdentifier("info.protocol")
  }
}

// MARK: - Action bar

struct ActionBar: View {
  let s: RefScale
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  var body: some View {
    ZStack(alignment: .topLeading) {
      square(icon: "slider.horizontal.3", x: 36) { model.openControlCenter(.settings) }
        .accessibilityLabel(L("tab.settings"))
        .accessibilityIdentifier("action.settings")
      Button { Task { await model.toggleConnection() } } label: {
        HStack(spacing: s(15)) {
          if vpn.status == .connecting || vpn.status == .disconnecting {
            ProgressView().tint(DS.connectText).scaleEffect(s.u)
          } else {
            Image(systemName: "power").font(.system(size: s(19), weight: .medium))
          }
          Text(connectTitle).refFont(s, DS.Size.connect, .semibold)
        }
        .foregroundStyle(DS.connectText)
        .frame(width: s(403), height: s(51))
        .background(DS.connectFill, in: RoundedRectangle(cornerRadius: s(12), style: .continuous))
        .contentShape(Rectangle())
      }
      .buttonStyle(PressableStyle())
      .disabled(vpn.busy && vpn.status != .connecting)
      .accessibilityIdentifier("action.connect")
      .offset(x: s(118), y: s(2))
      square(icon: favorite ? "star.fill" : "star", x: 547) {
        Task { await model.toggleFavoriteSelected() }
      }
      .disabled(model.currentServer == nil)
      .accessibilityLabel(favorite ? L("servers.unfavorite") : L("servers.favorite"))
      .accessibilityIdentifier("action.favorite")
    }
  }

  private var favorite: Bool { model.currentServer?.favorite ?? false }

  private var connectTitle: String {
    switch vpn.status {
    case .connected, .reasserting: return L("action.disconnect")
    case .connecting: return L("status.connecting")
    case .disconnecting: return L("status.disconnecting")
    default: return L("action.connect")
    }
  }

  private func square(icon: String, x: CGFloat, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: s(18), weight: .regular))
        .foregroundStyle(DS.iconLight)
        .frame(width: s(56), height: s(53))
        .background(DS.squareButton, in: RoundedRectangle(cornerRadius: s(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: s(12), style: .continuous).strokeBorder(DS.squareBorder, lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
    .offset(x: s(x))
  }
}

struct PressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.75 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

/// Text shown for servers: country and city instead of the provider's raw name.
enum ServerText {
  static func family(_ s: CoreServer) -> String {
    switch s.protocol {
    case "vless": return s.security == "reality" ? "vless-reality" : "vless"
    case "hysteria", "hysteria2": return "hysteria2"
    default: return s.protocol
    }
  }

  static func familyName(_ family: String) -> String {
    switch family {
    case "wireguard": return "WireGuard"
    case "vless-reality": return "VLESS Reality"
    case "vless": return "VLESS"
    case "vmess": return "VMess"
    case "trojan": return "Trojan"
    case "shadowsocks": return "Shadowsocks"
    case "hysteria2": return "Hysteria2"
    case "socks": return "SOCKS5"
    case "http": return "HTTP"
    default: return family.uppercased()
    }
  }

  static func chip(_ s: CoreServer) -> String {
    switch s.protocol {
    case "wireguard": return "WG"
    case "hysteria", "hysteria2": return "HY2"
    case "shadowsocks": return "SS"
    case "vmess": return "VMess"
    case "trojan": return "Trojan"
    case "socks": return "SOCKS"
    default: return s.protocol.uppercased()
    }
  }

  /// Second route chip: published link speed, otherwise the transport.
  static func secondChip(_ s: CoreServer) -> String? {
    if let b = s.bandwidth, !b.isEmpty { return b }
    if s.protocol == "hysteria" || s.protocol == "hysteria2" { return "QUIC" }
    switch s.security {
    case "reality": return "Reality"
    case "tls": return s.network == "tcp" ? "TLS" : s.network.uppercased()
    default: return s.network == "tcp" || s.network == "udp" ? nil : s.network.uppercased()
    }
  }

  static func title(_ s: CoreServer) -> String {
    if let cc = s.cc, !cc.isEmpty { return Format.country(cc) }
    return s.name
  }

  static func subtitle(_ s: CoreServer) -> String {
    if let city = s.city, !city.isEmpty { return city }
    // without a country the title is already the provider's name
    if (s.cc ?? "").isEmpty { return s.address }
    if let label = s.label, !label.isEmpty { return label }
    return ""
  }

  static func place(_ s: CoreServer) -> String {
    let sub = subtitle(s)
    return sub.isEmpty ? title(s) : "\(title(s)), \(sub)"
  }
}
