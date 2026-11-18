import NetworkExtension
import SwiftUI
import UIKit

/// The bottom panel of the home screen: Servers / Routes / Favorites with search, region filters
/// and the server list. It stands on the action bar; its content ends above it.
struct ServerPanel: View {
  enum Detent: Equatable { case collapsed, standard, full }
  enum Section: String, CaseIterable, Identifiable {
    case servers, routes, favorites
    var id: String { rawValue }
    var icon: String {
      switch self {
      case .servers: return "server.rack"
      case .routes: return "point.3.connected.trianglepath.dotted"
      case .favorites: return "star"
      }
    }
  }
  enum Region: String, CaseIterable, Identifiable {
    case all, europe, asia, americas
    var id: String { rawValue }
  }

  @Binding var detent: Detent
  @Binding var countryFilter: String?
  let layout: HomeLayout
  let panelTop: CGFloat

  @EnvironmentObject private var model: AppModel
  @State private var section: Section = Demo.initialSection
  @State private var region: Region = .all
  @State private var query = Demo.initialQuery
  @State private var searching = Demo.scenario == .search
  /// Where the panel was before the search opened it, to go back there when the search closes.
  @State private var detentBeforeSearch: Detent?
  @State private var pingOrder: PingOrder = .none
  @State private var showRouteInfo = false
  @FocusState private var searchFocused: Bool
  @Namespace private var tabs

  init(detent: Binding<Detent>, countryFilter: Binding<String?>, layout: HomeLayout, panelTop: CGFloat) {
    _detent = detent
    _countryFilter = countryFilter
    self.layout = layout
    self.panelTop = panelTop
  }

  private var m: HomeMetrics { layout.m }

  var body: some View {
    let p = Palette.current
    let m = self.m
    let shape = PanelShape(top: m(30), bottom: m(46))
    return VStack(alignment: .leading, spacing: 0) {
      Capsule()
        .fill(p.text3.opacity(0.55))
        .frame(width: m(38), height: m(5))
        .frame(maxWidth: .infinity)
        .padding(.top, m(7))
        .padding(.bottom, m(4))
        .accessibilityHidden(true)
      tabsRow
        .frame(height: m(40))
        .padding(.horizontal, m(12))
      switch section {
      case .servers:
        regionRow
          .padding(.top, m(12))
        table(servers: filtered)
      case .favorites:
        table(servers: favorites)
          .padding(.top, m(12))
      case .routes:
        RoutesList(m: m)
          .padding(.top, m(10))
      }
    }
    .frame(height: max(0, layout.panelBottom - panelTop), alignment: .top)
    .clipped()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background {
      ZStack {
        shape.fill(.ultraThinMaterial)
        shape.fill(p.panel)
      }
    }
    .overlay(shape.stroke(p.stroke, lineWidth: 1))
  }

  // MARK: Tabs and search

  private var tabsRow: some View {
    let p = Palette.current
    return HStack(spacing: m(8)) {
      if searching {
        HStack(spacing: m(8)) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: m(15), weight: .medium))
            .foregroundStyle(p.text3)
          TextField(L("sheet.search"), text: $query)
            .font(m.font(15))
            .foregroundStyle(p.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFocused)
            .submitLabel(.search)
            .accessibilityIdentifier("panel.searchField")
          if !query.isEmpty {
            Button { query = "" } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: m(15)))
                .foregroundStyle(p.text3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("common.clear"))
          }
        }
        .padding(.horizontal, m(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(p.stroke))
      } else {
        HStack(spacing: m(2)) {
          ForEach(Section.allCases) { item in
            tabButton(item)
          }
        }
        .padding(m(3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.raised.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(p.stroke))
      }
      Button(action: toggleSearch) {
        Image(systemName: searching ? "xmark" : "magnifyingglass")
          .font(.system(size: m(16), weight: .semibold))
          .foregroundStyle(p.text)
          .frame(width: m(40), height: m(40))
          .background(p.raised, in: Circle())
          .overlay(Circle().strokeBorder(p.stroke))
          .contentShape(Circle())
      }
      .buttonStyle(PressableStyle())
      .accessibilityLabel(searching ? L("common.close") : L("sheet.search"))
      .accessibilityIdentifier("panel.search")
    }
  }

  private func tabButton(_ item: Section) -> some View {
    let p = Palette.current
    let on = section == item
    return Button {
      guard section != item else { return }
      Haptics.selection()
      withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { section = item }
    } label: {
      HStack(spacing: m(6)) {
        Image(systemName: item.icon)
          .font(.system(size: m(12.5), weight: .semibold))
        Text(L("sheet.\(item.rawValue)"))
          .font(m.font(13.5, .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .foregroundStyle(on ? p.text : p.text3)
      .padding(.horizontal, m(8))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        if on {
          Capsule()
            .fill(p.selected)
            .overlay(Capsule().strokeBorder(p.stroke))
            .matchedGeometryEffect(id: "tab", in: tabs)
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(on ? .isSelected : [])
    .accessibilityIdentifier("tab.\(item.rawValue)")
  }

  private func toggleSearch() {
    Haptics.selection()
    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
      searching.toggle()
      if searching {
        section = .servers
        detentBeforeSearch = detent
        detent = .full
      } else {
        query = ""
        if let previous = detentBeforeSearch { detent = previous }
        detentBeforeSearch = nil
      }
    }
    searchFocused = searching
  }

  // MARK: Regions

  private var regionRow: some View {
    HStack(spacing: m(8)) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: m(8)) {
          if let cc = countryFilter {
            chip(title: Format.country(cc), selected: true, flag: cc, trailing: "xmark") { countryFilter = nil }
              .accessibilityIdentifier("region.country")
          } else {
            ForEach(Region.allCases) { r in
              chip(title: L("region.\(r.rawValue)"), selected: region == r) {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.2)) { region = r }
              }
              .accessibilityIdentifier("region.\(r.rawValue)")
            }
          }
        }
        .padding(.horizontal, m(12))
      }
      chip(title: L("sheet.fastest"), selected: false, icon: "bolt.fill") { selectFastest() }
        .accessibilityIdentifier("region.fastest")
        .padding(.trailing, m(12))
    }
    .frame(height: m(34))
  }

  private func chip(title: String, selected: Bool, icon: String? = nil, flag: String? = nil, trailing: String? = nil,
                    action: @escaping () -> Void) -> some View {
    let p = Palette.current
    return Button(action: action) {
      HStack(spacing: m(6)) {
        if let flag = flag { RoundFlag(cc: flag, diameter: m(18)) }
        if let icon = icon { Image(systemName: icon).font(.system(size: m(12), weight: .semibold)) }
        Text(title)
          .font(m.font(13.5, selected ? .semibold : .medium))
          .lineLimit(1)
        if let trailing = trailing { Image(systemName: trailing).font(.system(size: m(10), weight: .bold)) }
      }
      .foregroundStyle(selected ? p.text : p.text2)
      .padding(.horizontal, m(13))
      .frame(height: m(34))
      .background(selected ? p.selected : p.raised, in: Capsule())
      .overlay(Capsule().strokeBorder(selected ? p.strokeStrong : p.stroke, lineWidth: 1))
      .contentShape(Capsule())
    }
    .buttonStyle(PressableStyle())
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: Table

  private var filtered: [CoreServer] {
    var list = model.visibleServers
    if let cc = countryFilter { list = list.filter { ($0.cc ?? "") == cc } }
    if region != .all { list = list.filter { $0.region == region.rawValue } }
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if !q.isEmpty {
      list = list.filter { srv in
        [ServerText.title(srv), ServerText.subtitle(srv), srv.name, srv.cc ?? "", srv.city ?? "", Locale(identifier: "en").localizedString(forRegionCode: srv.cc ?? "") ?? ""]
          .contains { $0.lowercased().contains(q) }
      }
    }
    return sorted(list)
  }

  private var favorites: [CoreServer] { sorted(model.visibleServers.filter(\.favorite)) }

  /// List order by default (as the subscription lists them); the Ping header cycles ascending, descending, off.
  enum PingOrder {
    case none, ascending, descending
    var next: PingOrder {
      switch self {
      case .none: return .ascending
      case .ascending: return .descending
      case .descending: return .none
      }
    }
  }

  private func sorted(_ list: [CoreServer]) -> [CoreServer] {
    guard pingOrder != .none else { return list }
    let descending = pingOrder == .descending
    let indexed = list.enumerated().map { ($0.offset, $0.element) }
    return indexed.sorted { a, b in
      let pa = model.latency[a.1.id]?.value, pb = model.latency[b.1.id]?.value
      switch (pa, pb) {
      case let (x?, y?): return x == y ? a.0 < b.0 : (descending ? x > y : x < y)
      case (.some, .none): return true
      case (.none, .some): return false
      default: return a.0 < b.0
      }
    }.map(\.1)
  }

  private func table(servers: [CoreServer]) -> some View {
    let p = Palette.current
    let target = model.scrollTarget
    let store = model
    return VStack(spacing: 0) {
      columnHeader
        .frame(height: m(22))
        .padding(.top, m(10))
      Rectangle()
        .fill(p.separator)
        .frame(height: 1)
        .padding(.horizontal, m(14))
      if servers.isEmpty {
        Text(section == .favorites ? L("sheet.favorites_empty") : (model.state.servers.isEmpty ? L("sheet.empty") : L("servers.no_results")))
          .font(m.font(14))
          .foregroundStyle(p.text2)
          .multilineTextAlignment(.center)
          .padding(.horizontal, m(24))
          .padding(.top, m(22))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .accessibilityIdentifier("table.empty")
      } else {
        ScrollViewReader { proxy in
          ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
              ForEach(servers) { server in
                ServerTableRow(server: server, m: m)
                  .id(server.id)
                if server.id != servers.last?.id {
                  Rectangle()
                    .fill(p.separator)
                    .frame(height: 1)
                    .padding(.leading, m(88))
                    .padding(.trailing, m(14))
                }
              }
            }
            .padding(.bottom, m(24))
          }
          .refreshable {
            await store.refreshAll()
            store.probe(store.visibleServers)
          }
          .onChange(of: target) { id in
            guard let id = id else { return }
            withAnimation { proxy.scrollTo(id, anchor: .center) }
          }
        }
        // the last row fades out above the action bar
        .mask {
          VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: m(16))
          }
        }
      }
    }
    .popover(isPresented: $showRouteInfo) {
      Text(L("route.info")).font(.footnote).padding().frame(width: 260).modifier(PopoverOnPhone())
    }
  }

  private var columnHeader: some View {
    let p = Palette.current
    return HStack(spacing: m(8)) {
      Text(L("table.country"))
      Button { showRouteInfo = true } label: {
        HStack(spacing: m(4)) {
          Text(L("table.route"))
          Image(systemName: "info.circle").font(.system(size: m(11)))
        }
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("table.route")
      Spacer(minLength: m(8))
      Button {
        Haptics.selection()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { pingOrder = pingOrder.next }
      } label: {
        HStack(spacing: m(4)) {
          Text(L("table.ping"))
          Image(systemName: pingIcon).font(.system(size: m(10), weight: .semibold))
        }
        .frame(width: m(100) - m(14), alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(pingLabel)
      .accessibilityIdentifier("table.ping")
    }
    .font(m.font(12, .medium))
    .foregroundStyle(p.text3)
    .padding(.leading, m(88))
    .padding(.trailing, m(14))
  }

  private var pingIcon: String {
    switch pingOrder {
    case .none: return "arrow.up.arrow.down"
    case .ascending: return "arrow.up"
    case .descending: return "arrow.down"
    }
  }

  private var pingLabel: String {
    switch pingOrder {
    case .none: return L("table.ping")
    case .ascending: return L("table.ping_asc")
    case .descending: return L("table.ping_desc")
    }
  }

  private func selectFastest() {
    Haptics.selection()
    var pool = model.visibleServers
    if region != .all { pool = pool.filter { $0.region == region.rawValue } }
    guard let best = model.fastest(in: pool) else {
      model.probe(pool)
      model.info(L("sheet.testing"))
      return
    }
    Task { await model.select(best) }
    model.scrollTarget = best.id
  }
}

/// Keeps a popover a popover on iPhone where the system allows it (iOS 16.4+); earlier it becomes a sheet.
private struct PopoverOnPhone: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 16.4, *) {
      content.presentationCompactAdaptation(.popover)
    } else {
      content
    }
  }
}

/// Panel outline: rounded top corners and large bottom corners that follow the screen.
struct PanelShape: Shape {
  var top: CGFloat
  var bottom: CGFloat

  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
    p.addArc(center: CGPoint(x: rect.minX + top, y: rect.minY + top), radius: top, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
    p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
    p.addArc(center: CGPoint(x: rect.maxX - top, y: rect.minY + top), radius: top, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
    p.addArc(center: CGPoint(x: rect.maxX - bottom, y: rect.maxY - bottom), radius: bottom, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
    p.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
    p.addArc(center: CGPoint(x: rect.minX + bottom, y: rect.maxY - bottom), radius: bottom, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
    p.closeSubpath()
    return p
  }
}

/// One server row: star | flag | country, city and route | ping | radio.
struct ServerTableRow: View {
  let server: CoreServer
  let m: HomeMetrics
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  init(server: CoreServer, m: HomeMetrics) {
    self.server = server
    self.m = m
  }

  private var selected: Bool { model.state.selected == server.id }
  private var connected: Bool { vpn.isConnected && vpn.connectedServerID == server.id }

  var body: some View {
    let p = Palette.current
    let on = selected || connected
    let subtitle = ServerText.subtitle(server)
    return HStack(spacing: 0) {
      Button { Task { await model.toggleFavorite(server) } } label: {
        Image(systemName: server.favorite ? "star.fill" : "star")
          .font(.system(size: m(16), weight: .medium))
          .foregroundStyle(server.favorite ? p.warn : p.text3)
          .frame(width: m(36), height: m(HomeLayout.row))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(server.favorite ? L("servers.unfavorite") : L("servers.favorite"))
      RoundFlag(cc: server.cc, diameter: m(34))
      VStack(alignment: .leading, spacing: m(4)) {
        Text(ServerText.title(server))
          .font(m.font(16, .semibold))
          .foregroundStyle(p.text)
          .lineLimit(1)
        HStack(spacing: m(6)) {
          if !subtitle.isEmpty {
            Text(subtitle)
              .font(m.font(13))
              .foregroundStyle(p.text2)
              .lineLimit(1)
          }
          routeChip(ServerText.chip(server))
          if let second = ServerText.secondChip(server) { routeChip(second) }
        }
      }
      .padding(.leading, m(10))
      .frame(maxWidth: .infinity, alignment: .leading)
      latency
        .frame(width: m(60), alignment: .leading)
      ZStack {
        Circle().strokeBorder(on ? p.accent : p.text3.opacity(0.7), lineWidth: m(1.8))
        if on { Circle().fill(p.accent).frame(width: m(10), height: m(10)) }
      }
      .frame(width: m(22), height: m(22))
    }
    .padding(.leading, m(8))
    .padding(.trailing, m(14))
    .frame(height: m(HomeLayout.row))
    .background(on ? p.selected.opacity(0.4) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { Task { await model.select(server) } }
    .contextMenu {
      Button { Task { await model.connect(to: server) } } label: { Label(L("servers.connect"), systemImage: "power") }
      Button { model.probe([server]) } label: { Label(L("servers.test_one"), systemImage: "speedometer") }
      Button { Task { await model.toggleFavorite(server) } } label: {
        Label(server.favorite ? L("servers.unfavorite") : L("servers.favorite"), systemImage: server.favorite ? "star.slash" : "star")
      }
      Button { UIPasteboard.general.string = server.address } label: { Label(L("servers.copy_address"), systemImage: "doc.on.doc") }
      Text(server.name)
      if let desc = server.desc, !desc.isEmpty { Text(desc) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("row.\(server.cc ?? "none")")
  }

  private func routeChip(_ text: String) -> some View {
    let p = Palette.current
    return Text(text)
      .font(m.font(10.5, .semibold))
      .foregroundStyle(p.text2)
      .lineLimit(1)
      .padding(.horizontal, m(7))
      .frame(height: m(18))
      .background(p.raised, in: Capsule())
      .overlay(Capsule().strokeBorder(p.stroke, lineWidth: 0.5))
      .fixedSize()
  }

  @ViewBuilder
  private var latency: some View {
    let p = Palette.current
    switch model.latency[server.id] {
    case .testing:
      ProgressView().controlSize(.small).tint(p.text3)
    case .ms(let ms):
      Text(Format.ms(ms))
        .font(m.font(15, .semibold).monospacedDigit())
        .foregroundStyle(p.latencyColor(ms))
    case .failed:
      Text("—")
        .font(m.font(15, .medium))
        .foregroundStyle(p.text3)
        .accessibilityLabel(L("latency.failed"))
    case nil:
      EmptyView()
    }
  }
}

/// Routing modes and configs.
struct RoutesList: View {
  let m: HomeMetrics
  @EnvironmentObject private var model: AppModel

  init(m: HomeMetrics) {
    self.m = m
  }

  var body: some View {
    let p = Palette.current
    return ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(["all", "config", "profile", "direct"], id: \.self) { mode in
          let enabled = mode != "profile" || model.state.selectedServer?.fullProfile == true
          Button { Task { await model.setMode(mode) } } label: {
            row(icon: icon(mode), title: L("mode.\(mode)"), subtitle: subtitle(mode), selected: model.state.settings.mode == mode)
          }
          .buttonStyle(.plain)
          .disabled(!enabled)
          .opacity(enabled ? 1 : 0.4)
          .accessibilityIdentifier("route.\(mode)")
          Rectangle()
            .fill(p.separator)
            .frame(height: 1)
            .padding(.leading, m(62))
            .padding(.trailing, m(14))
        }
        if model.state.configs.count > 1 {
          Text(L("routes.configs"))
            .font(m.font(12, .medium))
            .foregroundStyle(p.text3)
            .padding(.leading, m(16))
            .padding(.top, m(16))
            .padding(.bottom, m(4))
          ForEach(model.state.configs) { c in
            Button { Task { await model.activateConfig(c.id) } } label: {
              row(icon: "doc.text", title: c.name, subtitle: LF("configs.rules", c.rules), selected: c.active && model.state.settings.mode == "config")
            }
            .buttonStyle(.plain)
          }
        }
        Button { model.openControlCenter(.config) } label: {
          Label(L("routes.edit"), systemImage: "square.and.pencil")
            .font(m.font(14, .semibold))
            .foregroundStyle(p.text)
            .frame(maxWidth: .infinity)
            .frame(height: m(46))
            .background(p.raised, in: RoundedRectangle(cornerRadius: m(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: m(14), style: .continuous).strokeBorder(p.stroke))
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, m(14))
        .padding(.top, m(14))
        .padding(.bottom, m(28))
      }
    }
  }

  private func icon(_ mode: String) -> String {
    switch mode {
    case "all": return "globe"
    case "config": return "list.bullet.indent"
    case "profile": return "shippingbox"
    default: return "arrow.right"
    }
  }

  private func subtitle(_ mode: String) -> String {
    if mode == "config", let c = model.state.activeConfig { return LF("routes.config_detail", c.name, c.rules) }
    return L("mode.\(mode).detail")
  }

  private func row(icon: String, title: String, subtitle: String, selected: Bool) -> some View {
    let p = Palette.current
    return HStack(spacing: m(12)) {
      Image(systemName: icon)
        .font(.system(size: m(14), weight: .medium))
        .foregroundStyle(p.text)
        .frame(width: m(34), height: m(34))
        .background(p.raised, in: Circle())
        .overlay(Circle().strokeBorder(p.stroke))
      VStack(alignment: .leading, spacing: m(3)) {
        Text(title)
          .font(m.font(15.5, .semibold))
          .foregroundStyle(p.text)
          .lineLimit(1)
        Text(subtitle)
          .font(m.font(12.5))
          .foregroundStyle(p.text2)
          .lineLimit(1)
      }
      Spacer(minLength: m(8))
      ZStack {
        Circle().strokeBorder(selected ? p.accent : p.text3.opacity(0.7), lineWidth: m(1.8))
        if selected { Circle().fill(p.accent).frame(width: m(10), height: m(10)) }
      }
      .frame(width: m(22), height: m(22))
    }
    .padding(.leading, m(16))
    .padding(.trailing, m(14))
    .frame(height: m(HomeLayout.row))
    .contentShape(Rectangle())
  }
}
