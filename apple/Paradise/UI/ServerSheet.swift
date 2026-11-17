import NetworkExtension
import SwiftUI
import UIKit

/// The bottom panel with servers, routes and favorites. Drag it down to leave only the galaxy.
struct ServerSheet: View {
  enum Detent: Equatable { case hidden, peek, full }
  enum Section: String, CaseIterable, Identifiable {
    case servers, routes, favorites
    var id: String { rawValue }
  }
  enum Region: String, CaseIterable, Identifiable {
    case all, europe, asia, americas, other
    var id: String { rawValue }
  }

  static let peekHeight: CGFloat = 330
  static let handleHeight: CGFloat = 64

  @Binding var detent: Detent
  @Binding var filterCC: String?
  var height: CGFloat
  var bottomInset: CGFloat

  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @State private var section: Section = .servers
  @State private var region: Region = .all
  @State private var query = ""
  @State private var sortFastest = false
  @GestureState private var dragY: CGFloat = 0

  private var fullHeight: CGFloat { max(Self.peekHeight + 60, height * 0.66) }

  private func visible(_ d: Detent) -> CGFloat {
    switch d {
    case .hidden: return Self.handleHeight + bottomInset
    case .peek: return Self.peekHeight + bottomInset
    case .full: return fullHeight + bottomInset
    }
  }

  var body: some View {
    let total = fullHeight + bottomInset
    let shown = visible(detent)
    let offset = max(0, min(total - visible(.hidden), total - shown + dragY))
    VStack(spacing: 0) {
      handle
      if detent != .hidden || dragY < -10 {
        content
          .transition(.opacity)
      }
      Spacer(minLength: 0)
    }
    .frame(height: total, alignment: .top)
    .frame(maxWidth: .infinity)
    .background(
      UnevenTop(radius: 26)
        .fill(.ultraThinMaterial)
        .overlay(UnevenTop(radius: 26).fill(Theme.space.opacity(0.55)))
        .overlay(UnevenTop(radius: 26).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: -4)
    )
    .offset(y: offset)
    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: detent)
    .onChange(of: filterCC) { cc in
      if cc != nil { section = .servers; query = "" }
    }
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 4)
      .updating($dragY) { value, state, _ in state = value.translation.height }
      .onEnded { value in
        let predicted = value.predictedEndTranslation.height
        let current = visible(detent) - value.translation.height - (predicted - value.translation.height) * 0.3
        let candidates: [Detent] = [.hidden, .peek, .full]
        let next = candidates.min { abs(visible($0) - current) < abs(visible($1) - current) } ?? .peek
        if next != detent { Haptics.selection() }
        detent = next
      }
  }

  private var handle: some View {
    VStack(spacing: 8) {
      Capsule().fill(Color.white.opacity(0.35)).frame(width: 40, height: 5).padding(.top, 8)
      if detent == .hidden {
        HStack(spacing: 6) {
          Image(systemName: "chevron.up").font(.caption.weight(.bold))
          Text(LF("sheet.servers_count", model.state.servers.count)).font(Theme.label(.subheadline))
        }
        .foregroundStyle(.white.opacity(0.85))
      } else {
        sectionPicker.padding(.horizontal, 16)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: Self.handleHeight - 8, alignment: .top)
    .contentShape(Rectangle())
    .gesture(dragGesture)
    .onTapGesture {
      if detent == .hidden {
        Haptics.selection()
        detent = .peek
      }
    }
    .accessibilityAction(named: Text(L("sheet.a11y.toggle"))) {
      detent = detent == .hidden ? .peek : .hidden
    }
  }

  private var sectionPicker: some View {
    HStack(spacing: 4) {
      ForEach(Section.allCases) { s in
        Button {
          Haptics.selection()
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { section = s }
        } label: {
          Text(L("sheet.\(s.rawValue)"))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(section == s ? Color.white : Theme.dim)
            .background {
              if section == s {
                Capsule().fill(Color.white.opacity(0.12))
                  .overlay(Capsule().strokeBorder(Theme.glow.opacity(0.5), lineWidth: 1))
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(section == s ? .isSelected : [])
      }
    }
    .padding(3)
    .background(Color.white.opacity(0.05), in: Capsule())
  }

  @ViewBuilder
  private var content: some View {
    switch section {
    case .servers: serversList
    case .routes: RoutesPanel()
    case .favorites: favoritesList
    }
  }

  // MARK: Servers

  private var regionsPresent: [Region] {
    var set = Set<Region>()
    for s in model.state.servers { set.insert(Self.region(of: s)) }
    return Region.allCases.filter { $0 == .all || set.contains($0) }
  }

  static func region(of s: CoreServer) -> Region {
    switch s.region {
    case "europe": return .europe
    case "asia": return .asia
    case "americas": return .americas
    default: return .other
    }
  }

  private var filtered: [CoreServer] {
    var list = model.state.servers
    if let cc = filterCC { list = list.filter { ($0.cc ?? "") == cc } }
    if region != .all { list = list.filter { Self.region(of: $0) == region } }
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if !q.isEmpty {
      list = list.filter {
        $0.name.lowercased().contains(q) || Format.country($0.cc).lowercased().contains(q) || ($0.city ?? "").lowercased().contains(q)
          || ($0.cc ?? "").lowercased() == q || $0.protocol.lowercased().contains(q)
      }
    }
    if sortFastest {
      list.sort { (model.latency[$0.id]?.value ?? Int64.max) < (model.latency[$1.id]?.value ?? Int64.max) }
    }
    return list
  }

  private var serversList: some View {
    VStack(spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
        TextField(L("sheet.search"), text: $query)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .foregroundStyle(.white)
        if !query.isEmpty {
          Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim) }
            .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .padding(.horizontal, 16)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          if let cc = filterCC {
            chip(title: "\(Format.flag(cc)) \(Format.country(cc))", selected: true, icon: "xmark") { filterCC = nil }
          }
          ForEach(regionsPresent) { r in
            chip(title: L("region.\(r.rawValue)"), selected: region == r) {
              Haptics.selection()
              region = r
            }
          }
          chip(title: L("sheet.fastest"), selected: sortFastest, icon: "bolt.fill") {
            Haptics.selection()
            sortFastest.toggle()
            if sortFastest && !model.state.servers.contains(where: { model.latency[$0.id] != nil }) {
              model.probe(model.state.servers)
            }
          }
        }
        .padding(.horizontal, 16)
      }

      if model.state.servers.isEmpty {
        emptyText(L("sheet.empty"))
      } else if filtered.isEmpty {
        emptyText(L("servers.no_results"))
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(filtered) { server in
              ServerRow(server: server)
              if server.id != filtered.last?.id {
                Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 56)
              }
            }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 24 + bottomInset)
        }
        .refreshable {
          await model.refreshAll()
          model.probe(model.state.servers)
        }
      }
    }
    .padding(.top, 6)
  }

  private func chip(title: String, selected: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let icon = icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
        Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
      }
      .padding(.horizontal, 12)
      .frame(height: 30)
      .foregroundStyle(selected ? Color.black.opacity(0.85) : .white)
      .background {
        if selected {
          Capsule().fill(LinearGradient(colors: [Theme.glowCool, Theme.glow], startPoint: .leading, endPoint: .trailing))
        } else {
          Capsule().fill(Color.white.opacity(0.07))
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func emptyText(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(Theme.dim)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.top, 28)
      .padding(.horizontal, 24)
  }

  // MARK: Favorites

  private var favoritesList: some View {
    let favorites = model.state.servers.filter(\.favorite)
    return Group {
      if favorites.isEmpty {
        emptyText(L("sheet.favorites_empty"))
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(favorites) { server in
              ServerRow(server: server)
              Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 56)
            }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 24 + bottomInset)
        }
      }
    }
    .padding(.top, 8)
  }
}

/// A rounded rectangle with only the top corners rounded.
struct UnevenTop: Shape {
  var radius: CGFloat

  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    p.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    p.closeSubpath()
    return p
  }
}

struct ServerRow: View {
  var server: CoreServer
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  private var selected: Bool { model.state.selected == server.id }
  private var connected: Bool { vpn.isConnected && vpn.connectedServerID == server.id }

  private var badges: [String] {
    var out = [server.protocol == "hysteria2" ? "HY2" : server.protocol.uppercased()]
    if server.security == "reality" { out.append("REALITY") } else if server.security == "tls" { out.append("TLS") }
    if server.network != "tcp" && server.network != "udp" { out.append(server.network.uppercased()) }
    if server.fullProfile { out.append(L("badge.profile")) }
    if server.fragment == true { out.append(L("badge.fragment")) }
    return out
  }

  var body: some View {
    HStack(spacing: 10) {
      Button { Task { await model.toggleFavorite(server) } } label: {
        Image(systemName: server.favorite ? "star.fill" : "star")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(server.favorite ? Theme.fair : Theme.dim)
          .frame(width: 30, height: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(server.favorite ? L("servers.unfavorite") : L("servers.favorite"))

      Text(Format.flag(server.cc)).font(.system(size: 22))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(server.name)
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .foregroundStyle(.white)
          .lineLimit(1)
        HStack(spacing: 4) {
          Text([Format.country(server.cc), server.city ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
          ForEach(badges.prefix(3), id: \.self) { b in
            Text(b)
              .font(.system(size: 8.5, weight: .bold, design: .rounded))
              .foregroundStyle(Theme.glowCool)
              .padding(.horizontal, 4)
              .padding(.vertical, 1.5)
              .background(Theme.glowCool.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }
      }
      Spacer(minLength: 4)
      latency
      Image(systemName: connected ? "checkmark.circle.fill" : (selected ? "largecircle.fill.circle" : "circle"))
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(connected ? Theme.good : (selected ? Theme.glow : Theme.dim.opacity(0.6)))
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .onTapGesture { Task { await model.select(server) } }
    .contextMenu {
      Button { Task { await model.connect(to: server) } } label: { Label(L("servers.connect"), systemImage: "bolt.fill") }
      Button { model.probe([server]) } label: { Label(L("servers.test_one"), systemImage: "speedometer") }
      Button { Task { await model.toggleFavorite(server) } } label: {
        Label(server.favorite ? L("servers.unfavorite") : L("servers.favorite"), systemImage: server.favorite ? "star.slash" : "star")
      }
      if let desc = server.desc, !desc.isEmpty { Text(desc) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder
  private var latency: some View {
    switch model.latency[server.id] {
    case .testing:
      ProgressView().controlSize(.mini).tint(.white)
    case .ms(let ms):
      HStack(spacing: 4) {
        Text(Format.ms(ms))
          .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(Theme.latencyColor(ms))
        SignalBars(bars: Theme.bars(ms), color: Theme.latencyColor(ms))
      }
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.poor)
        .accessibilityLabel(L("latency.failed"))
    case nil:
      EmptyView()
    }
  }
}

/// Routing modes and configs shown in the "Routes" section.
struct RoutesPanel: View {
  @EnvironmentObject private var model: AppModel

  private struct Mode: Identifiable {
    let id: String
    let icon: String
  }

  private let modes = [Mode(id: "all", icon: "globe"), Mode(id: "config", icon: "list.bullet.indent"),
                       Mode(id: "profile", icon: "shippingbox"), Mode(id: "direct", icon: "arrow.right")]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(modes) { mode in
          let enabled = mode.id != "profile" || model.state.selectedServer?.fullProfile == true
          Button { Task { await model.setMode(mode.id) } } label: {
            HStack(spacing: 12) {
              Image(systemName: mode.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.glowCool)
                .frame(width: 34, height: 34)
                .background(Theme.glowCool.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              VStack(alignment: .leading, spacing: 2) {
                Text(L("mode.\(mode.id)")).font(Theme.label(.subheadline)).foregroundStyle(.white)
                Text(mode.id == "config" ? (model.state.activeConfig.map { LF("routes.config_detail", $0.name, $0.rules) } ?? "") : L("mode.\(mode.id).detail"))
                  .font(.caption).foregroundStyle(Theme.dim).lineLimit(2)
              }
              Spacer()
              Image(systemName: model.state.settings.mode == mode.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(model.state.settings.mode == mode.id ? Theme.glow : Theme.dim)
            }
            .padding(10)
            .background(Color.white.opacity(model.state.settings.mode == mode.id ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(!enabled)
          .opacity(enabled ? 1 : 0.4)
        }
        if model.state.configs.count > 1 {
          Text(L("routes.configs")).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).padding(.top, 6)
          ForEach(model.state.configs) { c in
            Button { Task { await model.activateConfig(c.id) } } label: {
              HStack {
                Text(c.name).font(.subheadline).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text(LF("configs.rules", c.rules)).font(.caption).foregroundStyle(Theme.dim)
                Image(systemName: "checkmark").foregroundStyle(Theme.glow).frame(width: 18).opacity(c.active ? 1 : 0)
              }
              .padding(.horizontal, 12)
              .frame(minHeight: 40)
              .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
          }
        }
        Button { model.tab = .config } label: {
          Label(L("routes.edit"), systemImage: "square.and.pencil").font(Theme.label(.subheadline))
        }
        .buttonStyle(GlowButtonStyle(prominent: false))
        .padding(.top, 4)
      }
      .padding(.horizontal, 16)
      .padding(.top, 10)
      .padding(.bottom, 40)
    }
  }
}
