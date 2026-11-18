import NetworkExtension
import SwiftUI
import UIKit

/// The bottom panel of the home screen: Servers / Routes / Favorites with search, region filters
/// and the server table. Every x/y below is a reference pixel relative to the panel's top-left
/// corner (the panel starts at x = 12, y = 746 in the mock).
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
  @EnvironmentObject private var vpn: VPNController
  @State private var section: Section = Demo.initialSection
  @State private var region: Region = .all
  @State private var query = Demo.initialQuery
  @State private var searching = Demo.scenario == .search
  @State private var pingDescending = false
  @State private var showRouteInfo = false
  @FocusState private var searchFocused: Bool

  init(detent: Binding<Detent>, countryFilter: Binding<String?>, layout: HomeLayout, panelTop: CGFloat) {
    _detent = detent
    _countryFilter = countryFilter
    self.layout = layout
    self.panelTop = panelTop
  }

  private var s: RefScale { layout.s }
  /// Height available for the table (above the action bar).
  private var listBottom: CGFloat { layout.bottom(DS.Geo.actionBarTop) - panelTop - s(6) }

  var body: some View {
    ZStack(alignment: .topLeading) {
      PanelShape(top: s(DS.Geo.panelRadius), bottom: s(DS.Geo.panelBottomRadius))
        .fill(DS.panel)
      PanelShape(top: s(DS.Geo.panelRadius), bottom: s(DS.Geo.panelBottomRadius))
        .stroke(DS.panelBorder, lineWidth: 1)
      Capsule().fill(DS.handle)
        .frame(width: s(38), height: s(4))
        .frame(maxWidth: .infinity)
        .offset(y: s(9))
        .accessibilityHidden(true)
      tabsRow
      Rectangle().fill(DS.separator).frame(width: s(576), height: 1).offset(x: s(19), y: s(65))
      switch section {
      case .servers:
        regionRow.offset(y: s(80))
        table(servers: filtered, top: 121)
      case .favorites:
        table(servers: favorites, top: 80)
      case .routes:
        RoutesList(s: s, height: max(0, listBottom - s(76)))
          .offset(y: s(76))
      }
    }
    .clipped()
  }

  // MARK: Tabs and search

  private var tabsRow: some View {
    ZStack(alignment: .topLeading) {
      if searching {
        HStack(spacing: s(10)) {
          Image(systemName: "magnifyingglass").font(.system(size: s(14))).foregroundStyle(DS.textLabel)
          TextField(L("sheet.search"), text: $query)
            .font(s.font(13))
            .foregroundStyle(DS.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFocused)
            .submitLabel(.search)
            .accessibilityIdentifier("panel.searchField")
        }
        .padding(.horizontal, s(16))
        .frame(width: s(530), height: s(37))
        .background(DS.tabSelected, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.tabSelectedBorder))
        .offset(x: s(19), y: s(22))
      } else {
        HStack(spacing: 0) {
          ForEach(Section.allCases) { item in
            Button {
              guard section != item else { return }
              Haptics.selection()
              withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { section = item }
            } label: {
              HStack(spacing: s(12)) {
                Image(systemName: item.icon).font(.system(size: s(13.5), weight: .regular))
                Text(L("sheet.\(item.rawValue)")).font(s.font(DS.Size.tab, .medium))
              }
              .foregroundStyle(section == item ? DS.textPrimary : DS.textSecondary)
              .padding(.horizontal, s(31))
              .frame(height: s(37))
              .background {
                if section == item {
                  Capsule().fill(DS.tabSelected).overlay(Capsule().strokeBorder(DS.tabSelectedBorder))
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(section == item ? .isSelected : [])
            .accessibilityIdentifier("tab.\(item.rawValue)")
          }
        }
        .offset(x: s(19), y: s(22))
      }
      Button {
        Haptics.selection()
        withAnimation(.easeInOut(duration: 0.2)) {
          searching.toggle()
          if searching {
            section = .servers
            detent = .full
          } else {
            query = ""
          }
        }
        searchFocused = searching
      } label: {
        Image(systemName: searching ? "xmark" : "magnifyingglass")
          .font(.system(size: s(15), weight: .regular))
          .foregroundStyle(DS.textPrimary)
          .frame(width: s(37), height: s(37))
          .background(DS.roundButton, in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .offset(x: s(574.5 - 18.5), y: s(42 - 18.5))
      .accessibilityLabel(searching ? L("common.close") : L("sheet.search"))
      .accessibilityIdentifier("panel.search")
    }
  }

  // MARK: Regions

  private var regionRow: some View {
    ZStack(alignment: .topLeading) {
      if let cc = countryFilter {
        chip(title: Format.country(cc), selected: true, width: nil, icon: "xmark", flag: cc) { countryFilter = nil }
          .accessibilityIdentifier("region.country")
          .offset(x: s(19))
      } else {
        HStack(spacing: s(19)) {
          ForEach(Region.allCases) { r in
            chip(title: L("region.\(r.rawValue)"), selected: region == r, width: r == .americas ? 91 : 86) {
              Haptics.selection()
              region = r
            }
            .accessibilityIdentifier("region.\(r.rawValue)")
          }
        }
        .offset(x: s(19))
      }
      chip(title: L("sheet.fastest"), selected: false, width: 99, icon: "bolt") { selectFastest() }
        .accessibilityIdentifier("region.fastest")
        .offset(x: s(498))
    }
  }

  private func chip(title: String, selected: Bool, width: CGFloat?, icon: String? = nil, flag: String? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: s(10)) {
        if let flag = flag { RoundFlag(cc: flag, diameter: s(16)) }
        if let icon = icon, flag == nil { Image(systemName: icon).font(.system(size: s(12), weight: .regular)) }
        Text(title).font(s.font(DS.Size.chip, selected ? .semibold : .medium)).lineLimit(1)
        if flag != nil, let icon = icon { Image(systemName: icon).font(.system(size: s(10), weight: .semibold)) }
      }
      .foregroundStyle(selected ? DS.textPrimary : DS.textChip)
      .padding(.horizontal, width == nil ? s(14) : 0)
      .frame(width: width.map { s($0) }, height: s(30))
      .background(selected ? DS.chipSelected : DS.chip, in: Capsule())
      .overlay(Capsule().strokeBorder(selected ? DS.chipSelectedBorder : DS.chipBorder, lineWidth: 1))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
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

  private func sorted(_ list: [CoreServer]) -> [CoreServer] {
    let indexed = list.enumerated().map { ($0.offset, $0.element) }
    return indexed.sorted { a, b in
      let pa = model.latency[a.1.id]?.value, pb = model.latency[b.1.id]?.value
      switch (pa, pb) {
      case let (x?, y?): return x == y ? a.0 < b.0 : (pingDescending ? x > y : x < y)
      case (.some, .none): return true
      case (.none, .some): return false
      default: return a.0 < b.0
      }
    }.map(\.1)
  }

  private func table(servers: [CoreServer], top: CGFloat) -> some View {
    let headerHeight: CGFloat = 26
    let rowsTop = top + headerHeight
    return ZStack(alignment: .topLeading) {
      columnHeader.offset(y: s(top))
      Rectangle().fill(DS.separator).frame(width: s(546), height: 1).offset(x: s(28), y: s(rowsTop))
      if servers.isEmpty {
        Text(section == .favorites ? L("sheet.favorites_empty") : (model.state.servers.isEmpty ? L("sheet.empty") : L("servers.no_results")))
          .font(s.font(12.5))
          .foregroundStyle(DS.textSecondary)
          .multilineTextAlignment(.center)
          .frame(width: s(616))
          .accessibilityIdentifier("table.empty")
          .offset(y: s(rowsTop + 30))
      } else {
        ScrollViewReader { proxy in
          ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
              ForEach(servers) { server in
                ServerTableRow(server: server, s: s)
                  .id(server.id)
                if server.id != servers.last?.id {
                  Rectangle().fill(DS.separator).frame(width: s(546), height: 1).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, s(28))
                }
              }
            }
            .padding(.bottom, s(30))
          }
          .refreshable {
            await model.refreshAll()
            model.probe(model.visibleServers)
          }
          .onChange(of: model.scrollTarget) { id in
            guard let id = id else { return }
            withAnimation { proxy.scrollTo(id, anchor: .center) }
          }
        }
        .frame(width: s(616), height: max(0, listBottom - s(rowsTop)))
        .offset(y: s(rowsTop + 1))
      }
    }
    .popover(isPresented: $showRouteInfo) {
      Text(L("route.info")).font(.footnote).padding().frame(width: 260).modifier(PopoverOnPhone())
    }
  }

  private var columnHeader: some View {
    ZStack(alignment: .topLeading) {
      Text(L("table.country")).offset(x: s(69))
      Button { showRouteInfo = true } label: {
        HStack(spacing: s(8)) {
          Text(L("table.route"))
          Image(systemName: "info.circle").font(.system(size: s(11.5)))
        }
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("table.route")
      .offset(x: s(291))
      Button {
        Haptics.selection()
        pingDescending.toggle()
      } label: {
        HStack(spacing: s(6)) {
          Text(L("table.ping"))
          Image(systemName: "arrow.up.arrow.down").font(.system(size: s(11), weight: .medium))
        }
      }
      .buttonStyle(.plain)
      .offset(x: s(479))
      .accessibilityLabel(pingDescending ? L("table.ping_desc") : L("table.ping_asc"))
      .accessibilityIdentifier("table.ping")
    }
    .font(s.font(DS.Size.column))
    .foregroundStyle(DS.textColumn)
    .frame(height: s(20))
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

/// One server row: star | flag | country + city | route chips | ping | radio.
struct ServerTableRow: View {
  let server: CoreServer
  let s: RefScale
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  private var selected: Bool { model.state.selected == server.id }
  private var connected: Bool { vpn.isConnected && vpn.connectedServerID == server.id }

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.clear.frame(width: s(616), height: s(DS.Geo.rowPitch))
      Button { Task { await model.toggleFavorite(server) } } label: {
        Image(systemName: server.favorite ? "star.fill" : "star")
          .font(.system(size: s(14.5), weight: .regular))
          .foregroundStyle(server.favorite ? DS.textPrimary : DS.star)
          .frame(width: s(40), height: s(DS.Geo.rowPitch))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .offset(x: s(20))
      .accessibilityLabel(server.favorite ? L("servers.unfavorite") : L("servers.favorite"))
      RoundFlag(cc: server.cc, diameter: s(28))
        .offset(x: s(82.5 - 14), y: s(23 - 14))
      VStack(alignment: .leading, spacing: s(4)) {
        Text(ServerText.title(server))
          .font(s.font(DS.Size.rowTitle, .semibold))
          .foregroundStyle(DS.textPrimary)
          .lineLimit(1)
        let subtitle = ServerText.subtitle(server)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(s.font(DS.Size.rowSubtitle))
            .foregroundStyle(DS.textSubtitle)
            .lineLimit(1)
        }
      }
      .frame(width: s(165), height: s(DS.Geo.rowPitch), alignment: .leading)
      .offset(x: s(110))
      HStack(spacing: s(17)) {
        let chip = ServerText.chip(server)
        routeChip(chip, width: chip.count <= 3 ? 36 : nil)
        if let second = ServerText.secondChip(server) { routeChip(second, width: nil) }
      }
      .frame(height: s(DS.Geo.rowPitch))
      .offset(x: s(285))
      latency
        .frame(height: s(DS.Geo.rowPitch))
        .offset(x: s(482))
      radio
        .offset(x: s(577.5 - 8.5), y: s(23 - 8.5))
    }
    .frame(width: s(616), height: s(DS.Geo.rowPitch), alignment: .topLeading)
    .contentShape(Rectangle())
    .onTapGesture { Task { await model.select(server) } }
    .contextMenu {
      Button { Task { await model.connect(to: server) } } label: { Label(L("servers.connect"), systemImage: "power") }
      Button { model.probe([server]) } label: { Label(L("servers.test_one"), systemImage: "speedometer") }
      Button { Task { await model.toggleFavorite(server) } } label: {
        Label(server.favorite ? L("servers.unfavorite") : L("servers.favorite"), systemImage: server.favorite ? "star.slash" : "star")
      }
      Text(server.name)
      if let desc = server.desc, !desc.isEmpty { Text(desc) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("row.\(server.cc ?? "none")")
  }

  private func routeChip(_ text: String, width: CGFloat?) -> some View {
    Text(text)
      .font(s.font(DS.Size.route, .medium))
      .foregroundStyle(DS.textRoute)
      .lineLimit(1)
      .padding(.horizontal, width == nil ? s(11) : 0)
      .frame(width: width.map { s($0) }, height: s(20))
      .background(DS.routeChip, in: Capsule())
  }

  @ViewBuilder
  private var latency: some View {
    switch model.latency[server.id] {
    case .testing:
      ProgressView().controlSize(.mini).tint(DS.textSecondary)
    case .ms(let ms):
      Text(Format.ms(ms))
        .font(s.font(DS.Size.ping, .medium))
        .monospacedDigit()
        .foregroundStyle(DS.ping)
    case .failed:
      Text("—").font(s.font(DS.Size.ping)).foregroundStyle(DS.textSubtitle)
        .accessibilityLabel(L("latency.failed"))
    case nil:
      EmptyView()
    }
  }

  private var radio: some View {
    ZStack {
      Circle().strokeBorder(selected || connected ? DS.textPrimary : DS.radio, lineWidth: s(1.6))
      if selected || connected {
        Circle().fill(DS.textPrimary).frame(width: s(8), height: s(8))
      }
    }
    .frame(width: s(17), height: s(17))
  }
}

/// Routing modes and configs.
struct RoutesList: View {
  let s: RefScale
  let height: CGFloat
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView(showsIndicators: false) {
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
          Rectangle().fill(DS.separator).frame(width: s(546), height: 1).padding(.leading, s(28))
        }
        if model.state.configs.count > 1 {
          Text(L("routes.configs")).font(s.font(DS.Size.column)).foregroundStyle(DS.textColumn)
            .padding(.leading, s(28)).padding(.top, s(16)).padding(.bottom, s(4))
          ForEach(model.state.configs) { c in
            Button { Task { await model.activateConfig(c.id) } } label: {
              row(icon: "doc.text", title: c.name, subtitle: LF("configs.rules", c.rules), selected: c.active && model.state.settings.mode == "config")
            }
            .buttonStyle(.plain)
          }
        }
        Button { model.openControlCenter(.config) } label: {
          Label(L("routes.edit"), systemImage: "square.and.pencil")
            .font(s.font(12.5, .medium))
            .foregroundStyle(DS.textPrimary)
            .frame(width: s(560), height: s(40))
            .background(DS.chip, in: RoundedRectangle(cornerRadius: s(12), style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.leading, s(28))
        .padding(.top, s(14))
        .padding(.bottom, s(30))
      }
    }
    .frame(width: s(616), height: height)
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
    HStack(spacing: 0) {
      Image(systemName: icon)
        .font(.system(size: s(13)))
        .foregroundStyle(DS.textPrimary)
        .frame(width: s(28), height: s(28))
        .background(DS.routeChip, in: Circle())
        .padding(.leading, s(68.5))
      VStack(alignment: .leading, spacing: s(4)) {
        Text(title).font(s.font(DS.Size.rowTitle, .semibold)).foregroundStyle(DS.textPrimary).lineLimit(1)
        Text(subtitle).font(s.font(DS.Size.rowSubtitle)).foregroundStyle(DS.textSubtitle).lineLimit(1)
      }
      .padding(.leading, s(13.5))
      Spacer(minLength: s(8))
      ZStack {
        Circle().strokeBorder(selected ? DS.textPrimary : DS.radio, lineWidth: s(1.6))
        if selected { Circle().fill(DS.textPrimary).frame(width: s(8), height: s(8)) }
      }
      .frame(width: s(17), height: s(17))
      .padding(.trailing, s(616 - 586))
    }
    .frame(width: s(616), height: s(DS.Geo.rowPitch))
    .contentShape(Rectangle())
  }
}
