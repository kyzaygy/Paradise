import NetworkExtension
import SwiftUI
import UIKit

/// Where the blocks of the home screen go for one screen size. The header and the connection card
/// follow the status bar, the action bar follows the bottom edge, the server panel stands on the
/// action bar and the space between the card and the panel is the map.
struct HomeLayout {
  static let header: CGFloat = 48
  static let status: CGFloat = 72
  static let info: CGFloat = 52
  static let bar: CGFloat = 58
  /// Grabber, tabs, region chips and the column header of the panel.
  static let panelHead: CGFloat = 142
  static let row: CGFloat = 60

  let width: CGFloat
  let height: CGFloat
  let m: HomeMetrics
  let headerTop: CGFloat
  let cardTop: CGFloat
  let mapTop: CGFloat
  let barTop: CGFloat
  /// Server rows visible while the panel is in its standard position.
  let standardRows: Int

  init(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
    let m = HomeMetrics(width: size.width)
    let headerTop = max(safeTop, 20) + m(2)
    let cardTop = headerTop + m(Self.header) + m(6)
    let mapTop = cardTop + m(Self.status + Self.info) + m(6)
    let barTop = size.height - max(safeBottom, m(12)) - m(8) - m(Self.bar)
    // the map keeps at least 210 pt; the panel shows one to three rows
    let free = barTop - m(10) - mapTop - m(Self.panelHead) - m(210)
    self.width = size.width
    self.height = size.height
    self.m = m
    self.headerTop = headerTop
    self.cardTop = cardTop
    self.mapTop = mapTop
    self.barTop = barTop
    self.standardRows = min(3, max(1, Int((free / m(Self.row)).rounded(.down))))
  }

  var cardHeight: CGFloat { m(Self.status + Self.info) }
  /// The panel's content ends here, above the action bar.
  var panelBottom: CGFloat { barTop - m(10) }
  var standardPanelTop: CGFloat { panelBottom - m(Self.panelHead) - m(Self.row) * CGFloat(standardRows) }
  var fullPanelTop: CGFloat { cardTop + cardHeight + m(10) }
  var collapsedPanelTop: CGFloat { panelBottom - m(66) }
  var mapRect: CGRect { CGRect(x: 0, y: mapTop, width: width, height: max(0, standardPanelTop - mapTop)) }

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

  init(layout: HomeLayout) {
    self.layout = layout
  }

  var body: some View {
    let m = layout.m
    let panelTop = min(layout.collapsedPanelTop, max(layout.fullPanelTop, layout.panelTop(detent) + panelDrag))
    let nodes = model.countryNodes
    let showEmptyHint = model.state.servers.isEmpty && !model.loading
    // the space stops while the panel or a sheet covers it, and in the demo (fixed frames for screenshots and tests)
    let moving = prefs.galaxyMotion && (model.demo == nil || Demo.motion) && detent != .full && model.sheet == nil
    return ZStack(alignment: .topLeading) {
      if model.storageBroken {
        Palette.current.background
        storageNotice
          .padding(.horizontal, m(24))
          .frame(width: layout.width)
          .offset(y: layout.mapTop)
      } else {
        SpaceView(size: CGSize(width: layout.width, height: layout.height), mapRect: layout.mapRect, nodes: nodes,
                  highlighted: highlightedCC, connected: vpn.isConnected, moving: moving, interactive: detent != .full,
                  parallax: prefs.parallax && model.demo == nil, m: m,
                  onNode: { node in Task { await model.connect(country: node) } },
                  onNodeList: { node in
                    countryFilter = node.cc
                    detent = .full
                  })
        if showEmptyHint {
          emptyHint(m)
            .frame(width: layout.width)
            .position(x: layout.width / 2, y: layout.mapRect.midY)
        }
      }
      header(m)
        .frame(width: layout.width, height: m(HomeLayout.header))
        .offset(y: layout.headerTop)
      ConnectionCard(m: m, width: layout.width - m(32), onSelect: toggleList)
        .frame(width: layout.width - m(32), height: layout.cardHeight)
        .offset(x: m(16), y: layout.cardTop)
      ServerPanel(detent: $detent, countryFilter: $countryFilter, layout: layout, panelTop: panelTop)
        .frame(width: layout.width - m(16), height: max(0, layout.height - panelTop), alignment: .top)
        .offset(x: m(8), y: panelTop)
        .simultaneousGesture(panelGesture, including: .all)
      ActionBar(m: m)
        .frame(width: layout.width - m(32), height: m(HomeLayout.bar))
        .offset(x: m(16), y: layout.barTop)
      if model.loading {
        ProgressView()
          .tint(Palette.current.text)
          .frame(width: layout.width, height: layout.height)
      }
    }
    .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: detent)
  }

  private var highlightedCC: String? { model.currentServer?.cc }

  /// The connection card opens the full server list and closes it again.
  private func toggleList() {
    Haptics.selection()
    detent = detent == .full ? .standard : .full
  }

  private var panelGesture: some Gesture {
    DragGesture(minimumDistance: 10)
      .updating($panelDrag) { v, state, _ in
        // only vertical drags that start on the grabber or the tabs move the panel
        guard Self.vertical(v), v.startLocation.y < layout.m(62) else { return }
        state = v.translation.height
      }
      .onEnded { v in
        guard Self.vertical(v), v.startLocation.y < layout.m(62) else { return }
        let current = layout.panelTop(detent) + v.translation.height + (v.predictedEndTranslation.height - v.translation.height) * 0.25
        let candidates: [ServerPanel.Detent] = [.full, .standard, .collapsed]
        let next = candidates.min { abs(layout.panelTop($0) - current) < abs(layout.panelTop($1) - current) } ?? .standard
        if next != detent { Haptics.selection() }
        detent = next
      }
  }

  private static func vertical(_ v: DragGesture.Value) -> Bool { abs(v.translation.height) > abs(v.translation.width) }

  // MARK: Header

  private func header(_ m: HomeMetrics) -> some View {
    let p = Palette.current
    return HStack(spacing: m(10)) {
      GlobeLogo(diameter: m(30))
        .onLongPressGesture(minimumDuration: 0.8) { model.sheet = .diagnostics }
      Text("Paradise")
        .font(m.font(22, .semibold))
        .foregroundStyle(p.text)
        .accessibilityAddTraits(.isHeader)
      Text("Pro")
        .font(m.font(11.5, .semibold))
        .foregroundStyle(p.text2)
        .padding(.horizontal, m(8))
        .frame(height: m(22))
        .background(p.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(p.stroke))
        .accessibilityHidden(true)
      Spacer(minLength: m(8))
      Button { model.sheet = .notifications } label: {
        roundIcon("bell", m: m)
          .overlay(alignment: .topTrailing) {
            if model.unseenNotices > 0 {
              Circle().fill(p.accent).frame(width: m(8), height: m(8)).offset(x: -m(9), y: m(9))
            }
          }
      }
      .buttonStyle(PressableStyle())
      .accessibilityLabel(L("notices.title"))
      .accessibilityIdentifier("header.bell")
      moreMenu(m)
    }
    .padding(.horizontal, m(16))
  }

  private func roundIcon(_ name: String, m: HomeMetrics) -> some View {
    Image(systemName: name)
      .font(.system(size: m(17), weight: .medium))
      .foregroundStyle(Palette.current.text)
      .frame(width: m(42), height: m(42))
      .glass(Circle())
      .contentShape(Circle())
  }

  private func moreMenu(_ m: HomeMetrics) -> some View {
    Menu {
      Button { model.sheet = .add } label: { Label(L("home.add"), systemImage: "plus") }
      Button { Task { await pasteFromClipboard() } } label: { Label(L("empty.paste"), systemImage: "doc.on.clipboard") }
      Button { model.sheet = .export } label: { Label(L("transfer.share"), systemImage: "square.and.arrow.up") }
      Divider()
      Button { Task { await model.refreshAll() } } label: { Label(L("home.refresh"), systemImage: "arrow.clockwise") }
      Button { model.probe(model.state.servers) } label: { Label(L("servers.test"), systemImage: "speedometer") }
      Button { model.sheet = .subscriptions } label: { Label(L("home.subscriptions"), systemImage: "tray.full") }
      Divider()
      Menu {
        Picker(L("appearance.theme"), selection: $prefs.theme) {
          ForEach(AppTheme.allCases) { theme in
            Text(theme.title).tag(theme.rawValue)
          }
        }
      } label: {
        Label(L("appearance.theme"), systemImage: "paintpalette")
      }
      Button { model.openControlCenter(.settings) } label: { Label(L("tab.settings"), systemImage: "slider.horizontal.3") }
      Button { model.sheet = .diagnostics } label: { Label(L("diag.title"), systemImage: "stethoscope") }
    } label: {
      roundIcon("ellipsis", m: m)
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

  private func emptyHint(_ m: HomeMetrics) -> some View {
    let p = Palette.current
    let shape = RoundedRectangle(cornerRadius: m(22), style: .continuous)
    return VStack(spacing: m(12)) {
      Image(systemName: "sparkles")
        .font(.system(size: m(24), weight: .medium))
        .foregroundStyle(p.text2)
      Text(L("empty.title"))
        .font(m.font(18, .semibold))
        .foregroundStyle(p.text)
      Text(L("empty.body"))
        .font(m.font(14))
        .foregroundStyle(p.text2)
        .multilineTextAlignment(.center)
      HStack(spacing: m(10)) {
        Button { Task { await pasteFromClipboard() } } label: {
          Label(L("empty.paste"), systemImage: "doc.on.clipboard")
            .font(m.font(14, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: m(46))
            .foregroundStyle(p.connectText)
            .background(p.connectFill, in: RoundedRectangle(cornerRadius: m(14), style: .continuous))
        }
        Button { model.sheet = .add } label: {
          Label(L("empty.other"), systemImage: "qrcode.viewfinder")
            .font(m.font(14, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: m(46))
            .foregroundStyle(p.text)
            .background(p.raised, in: RoundedRectangle(cornerRadius: m(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: m(14), style: .continuous).strokeBorder(p.stroke))
        }
      }
      .buttonStyle(PressableStyle())
    }
    .padding(m(20))
    .glass(shape, frosted: true)
    .padding(.horizontal, m(24))
  }

  private var storageNotice: some View {
    let p = Palette.current
    return VStack(alignment: .leading, spacing: 12) {
      Text(L("storage.title")).font(.headline).foregroundStyle(p.text)
      Text(L("storage.body")).font(.subheadline).foregroundStyle(p.text2)
      if let e = Core.openError as? CoreError {
        Text("\(e.code) \(e.detail ?? "")").font(Theme.mono).foregroundStyle(p.text2)
      }
      Button(L("diag.title")) { model.sheet = .diagnostics }
      Button(L("storage.reset"), role: .destructive) { Task { await model.eraseAndRestart() } }
    }
    .padding(16)
    .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), frosted: true)
  }
}

// MARK: - Connection card

/// The card under the header: the connection state on top; the public IP, its location and the protocol below.
struct ConnectionCard: View {
  let m: HomeMetrics
  let width: CGFloat
  var onSelect: () -> Void
  @EnvironmentObject private var vpn: VPNController

  init(m: HomeMetrics, width: CGFloat, onSelect: @escaping () -> Void) {
    self.m = m
    self.width = width
    self.onSelect = onSelect
  }

  var body: some View {
    let p = Palette.current
    let on = vpn.isConnected
    return VStack(spacing: 0) {
      StatusLine(m: m, onSelect: onSelect)
        .frame(height: m(HomeLayout.status))
      Rectangle()
        .fill(p.separator)
        .frame(height: 1)
        .padding(.horizontal, m(16))
      InfoRow(m: m, width: width)
        .frame(height: m(HomeLayout.info) - 1)
    }
    .glass(RoundedRectangle(cornerRadius: m(22), style: .continuous), stroke: on ? p.accent.opacity(0.5) : p.stroke, frosted: true)
    .animation(.easeInOut(duration: 0.35), value: on)
  }
}

/// State, place and timer; tapping it opens the server list.
struct StatusLine: View {
  let m: HomeMetrics
  var onSelect: () -> Void
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  init(m: HomeMetrics, onSelect: @escaping () -> Void) {
    self.m = m
    self.onSelect = onSelect
  }

  var body: some View {
    // read the model here so the line follows it; only the timer is computed in the timeline
    let p = Palette.current
    let title = self.title
    let line = subtitleParts
    let rates = vpn.isConnected && model.rateDown + model.rateUp > 0
    return Button(action: onSelect) {
      HStack(spacing: m(14)) {
        StatusOrb(phase: phase, m: m)
        VStack(alignment: .leading, spacing: m(3)) {
          Text(title)
            .font(m.font(18, .semibold))
            .foregroundStyle(p.text)
            .lineLimit(1)
            .accessibilityIdentifier("status.title")
          // only the timer ticks; a long place is shortened, the timer stays whole
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let time = line.since.map { Format.duration(since: $0, now: context.date) }
            HStack(spacing: m(5)) {
              if !line.text.isEmpty {
                Text(line.text).lineLimit(1)
              }
              if let time = time {
                Text(line.text.isEmpty ? time : "· \(time)").fixedSize()
              }
            }
            .font(m.font(14).monospacedDigit())
            .foregroundStyle(p.text2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.subtitle(line, now: context.date))
            .accessibilityIdentifier("status.subtitle")
          }
        }
        Spacer(minLength: m(6))
        if rates {
          VStack(alignment: .trailing, spacing: m(2)) {
            Text("↓ \(Format.rate(model.rateDown))")
            Text("↑ \(Format.rate(model.rateUp))")
          }
          .font(m.font(11.5, .medium).monospacedDigit())
          .foregroundStyle(p.text2)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("status.rates")
        }
        Image(systemName: "chevron.right")
          .font(.system(size: m(14), weight: .semibold))
          .foregroundStyle(p.text3)
      }
      .padding(.horizontal, m(16))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(DimOnPressStyle())
    .accessibilityHint(L("home.a11y.servers"))
  }

  private var server: CoreServer? { model.currentServer }

  private var phase: StatusOrb.Phase {
    switch vpn.status {
    case .connected: return .on
    case .connecting, .reasserting, .disconnecting: return .busy
    default: return .off
    }
  }

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

/// The state light of the connection card: grey when off, pulsing amber while connecting, a glowing accent when connected.
struct StatusOrb: View {
  enum Phase: Equatable { case off, busy, on }
  let phase: Phase
  let m: HomeMetrics
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false

  init(phase: Phase, m: HomeMetrics) {
    self.phase = phase
    self.m = m
  }

  private var animates: Bool { phase != .off && !reduceMotion && Demo.scenario == nil }

  var body: some View {
    let p = Palette.current
    let color = phase == .on ? p.accent : (phase == .busy ? p.warn : p.text3)
    return ZStack {
      Circle()
        .fill(color.opacity(phase == .off ? 0.12 : 0.18))
        .frame(width: m(34), height: m(34))
      Circle()
        .stroke(color.opacity(0.7), lineWidth: m(1.5))
        .frame(width: m(14), height: m(14))
        .scaleEffect(pulse ? 2.3 : 1)
        .opacity(pulse || !animates ? 0 : 0.9)
      Circle()
        .fill(color)
        .frame(width: m(12), height: m(12))
        .shadow(color: phase == .on ? color.opacity(0.9) : .clear, radius: m(6))
    }
    .frame(width: m(34), height: m(34))
    .onAppear { restart() }
    .onChange(of: phase) { _ in restart() }
    .accessibilityHidden(true)
  }

  private func restart() {
    var reset = Transaction()
    reset.disablesAnimations = true
    withTransaction(reset) { pulse = false }
    guard animates else { return }
    let duration = phase == .busy ? 1.0 : 2.0
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false)) { pulse = true }
    }
  }
}

// MARK: - Your IP / Location / Protocol

struct InfoRow: View {
  let m: HomeMetrics
  let width: CGFloat
  @EnvironmentObject private var model: AppModel

  init(m: HomeMetrics, width: CGFloat) {
    self.m = m
    self.width = width
  }

  var body: some View {
    let p = Palette.current
    let ipWidth = (width * 0.35).rounded()
    let placeWidth = (width * 0.31).rounded()
    return HStack(spacing: 0) {
      column(L("home.ip"), width: ipWidth) {
        Text(model.publicIP ?? "—")
          .font(m.font(14, .semibold).monospacedDigit())
          .foregroundStyle(p.text)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .accessibilityIdentifier("info.ip")
      }
      divider(p)
      column(L("home.location"), width: placeWidth) {
        HStack(spacing: m(6)) {
          if let cc = model.publicCountry { RoundFlag(cc: cc, diameter: m(16)) }
          // the flag shows the country, so the line has room for the city
          Text(placeText)
            .font(m.font(14, .semibold))
            .foregroundStyle(p.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel(locationText)
            .accessibilityIdentifier("info.location")
        }
      }
      divider(p)
      ProtocolMenu(m: m, width: max(0, width - ipWidth - placeWidth - 2))
    }
    .accessibilityElement(children: .contain)
  }

  private var locationText: String {
    guard let cc = model.publicCountry else { return "—" }
    let country = Format.country(cc)
    if let city = model.publicCity, !city.isEmpty { return "\(country), \(city)" }
    return country
  }

  private var placeText: String {
    guard let cc = model.publicCountry else { return "—" }
    if let city = model.publicCity, !city.isEmpty { return city }
    return Format.country(cc)
  }

  private func column<V: View>(_ label: String, width: CGFloat, @ViewBuilder value: () -> V) -> some View {
    VStack(alignment: .leading, spacing: m(3)) {
      Text(label)
        .font(m.font(11.5, .medium))
        .foregroundStyle(Palette.current.text3)
      value()
    }
    .padding(.horizontal, m(12))
    .frame(width: width, alignment: .leading)
  }

  private func divider(_ p: Palette) -> some View {
    Rectangle().fill(p.separator).frame(width: 1, height: m(28))
  }
}

struct ProtocolMenu: View {
  let m: HomeMetrics
  let width: CGFloat
  @EnvironmentObject private var model: AppModel

  init(m: HomeMetrics, width: CGFloat) {
    self.m = m
    self.width = width
  }

  var body: some View {
    let p = Palette.current
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
      HStack(spacing: m(4)) {
        VStack(alignment: .leading, spacing: m(3)) {
          Text(L("home.protocol"))
            .font(m.font(11.5, .medium))
            .foregroundStyle(p.text3)
          Text(display)
            .font(m.font(14, .semibold))
            .foregroundStyle(p.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: m(11), weight: .semibold))
          .foregroundStyle(p.text3)
      }
      .padding(.leading, m(12))
      .padding(.trailing, m(14))
      .frame(width: width, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityLabel("\(L("home.protocol")): \(display)")
    .accessibilityIdentifier("info.protocol")
  }
}

// MARK: - Action bar

struct ActionBar: View {
  let m: HomeMetrics
  @EnvironmentObject private var model: AppModel

  init(m: HomeMetrics) {
    self.m = m
  }

  var body: some View {
    let p = Palette.current
    let favorite = model.currentServer?.favorite ?? false
    return HStack(spacing: m(12)) {
      square(icon: "slider.horizontal.3", color: p.text) { model.openControlCenter(.settings) }
        .accessibilityLabel(L("tab.settings"))
        .accessibilityIdentifier("action.settings")
      ConnectButton(m: m)
      square(icon: favorite ? "star.fill" : "star", color: favorite ? p.warn : p.text) {
        Task { await model.toggleFavoriteSelected() }
      }
      .disabled(model.currentServer == nil)
      .accessibilityLabel(favorite ? L("servers.unfavorite") : L("servers.favorite"))
      .accessibilityIdentifier("action.favorite")
    }
  }

  private func square(icon: String, color: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: m(19), weight: .medium))
        .foregroundStyle(color)
        .frame(width: m(HomeLayout.bar), height: m(HomeLayout.bar))
        .glass(RoundedRectangle(cornerRadius: m(18), style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
  }
}

/// Connect and Disconnect: a light pill when off, a light sweeping across it while connecting,
/// accent-tinted glass with a glow while connected.
struct ConnectButton: View {
  let m: HomeMetrics
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  init(m: HomeMetrics) {
    self.m = m
  }

  var body: some View {
    let p = Palette.current
    let busy = vpn.status == .connecting || vpn.status == .disconnecting
    let on = vpn.isConnected
    let shape = RoundedRectangle(cornerRadius: m(18), style: .continuous)
    let foreground = on ? p.text : p.connectText
    return Button { Task { await model.toggleConnection() } } label: {
      HStack(spacing: m(10)) {
        if busy {
          ProgressView().tint(foreground)
        } else {
          Image(systemName: "power").font(.system(size: m(18), weight: .semibold))
        }
        Text(title).font(m.font(17, .semibold))
      }
      .foregroundStyle(foreground)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        ZStack {
          if on {
            shape.fill(p.raised.opacity(0.92))
            shape.fill(p.accent.opacity(0.16))
          } else {
            shape.fill(LinearGradient(colors: [p.connectFill, p.connectFill.opacity(0.88)], startPoint: .top, endPoint: .bottom))
          }
          if busy && Demo.scenario == nil {
            Sweep()
              .clipShape(shape)
          }
        }
      }
      .overlay(shape.strokeBorder(on ? p.accent.opacity(0.6) : p.stroke, lineWidth: 1))
      .shadow(color: on ? p.accent.opacity(0.35) : Color.black.opacity(p.isLight ? 0.12 : 0.3), radius: m(on ? 14 : 10), y: m(4))
      .contentShape(shape)
    }
    .buttonStyle(PressableStyle())
    .disabled(vpn.busy && vpn.status != .connecting)
    .accessibilityLabel(title)
    .accessibilityIdentifier("action.connect")
    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: on)
  }

  private var title: String {
    switch vpn.status {
    case .connected, .reasserting: return L("action.disconnect")
    case .connecting: return L("status.connecting")
    case .disconnecting: return L("status.disconnecting")
    default: return L("action.connect")
    }
  }
}

/// A band of light running across a button.
private struct Sweep: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
      GeometryReader { geo in
        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
        let band = geo.size.width * 0.45
        LinearGradient(colors: [.clear, Color.white.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
          .frame(width: band)
          .offset(x: -band + (geo.size.width + band) * CGFloat(phase))
      }
    }
    .allowsHitTesting(false)
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
