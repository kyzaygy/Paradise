import NetworkExtension
import SwiftUI
import UIKit

struct HomeView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @EnvironmentObject private var prefs: AppPrefs
  @State private var sheet: ServerSheet.Detent = .peek
  @State private var sheetFilterCC: String?

  init() {}

  private var connectedCC: String? {
    guard vpn.isConnected else { return nil }
    return model.state.servers.first { $0.id == vpn.connectedServerID }?.cc
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .top) {
        backdrop
        if model.loading {
          ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.storageBroken {
          storageNotice.padding(.top, 120).padding(.horizontal, 20).padding(.leading, TabRail.width)
        } else {
          GalaxyView(
            nodes: model.countryNodes,
            selectedCC: model.state.selectedServer?.cc,
            connectedCC: connectedCC,
            status: vpn.status,
            busy: vpn.busy,
            showPing: prefs.showPing,
            animate: prefs.galaxyMotion,
            parallaxEnabled: prefs.parallax,
            onCore: { Task { await model.toggleConnection() } },
            onCountry: { node in Task { await model.connect(country: node) } },
            onCountryMenu: { node in
              sheetFilterCC = node.cc
              withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { sheet = .full }
            }
          )
          .padding(.top, 120)
          .padding(.bottom, sheet == .hidden ? 70 : (sheet == .peek ? ServerSheet.peekHeight - 40 : geo.size.height * 0.45))
          .animation(.spring(response: 0.45, dampingFraction: 0.9), value: sheet)
          .onChange(of: sheet) { value in model.railHidden = value == .full }
          .onDisappear { model.railHidden = false }
          if model.state.servers.isEmpty { emptyOverlay.padding(.top, geo.size.height * 0.28) }
          statusLine
            .padding(.top, 118)
        }
        VStack(spacing: 12) {
          header
          infoRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        if !model.loading && !model.storageBroken {
          ServerSheet(detent: $sheet, filterCC: $sheetFilterCC, height: geo.size.height, bottomInset: geo.safeAreaInsets.bottom)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
      }
    }
  }

  private var backdrop: some View {
    ZStack {
      Theme.space
      RadialGradient(colors: [Theme.glow.opacity(0.18), .clear], center: .init(x: 0.5, y: 0.42), startRadius: 10, endRadius: 420)
      RadialGradient(colors: [Theme.glowCool.opacity(0.08), .clear], center: .init(x: 0.85, y: 0.15), startRadius: 0, endRadius: 260)
    }
    .ignoresSafeArea()
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      Image("Logo")
        .resizable()
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .onLongPressGesture(minimumDuration: 0.8) { model.sheet = .diagnostics }
        .accessibilityHidden(true)
      Text("Paradise")
        .font(.system(size: 22, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)
      Text("Pro")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .foregroundStyle(Color.black.opacity(0.8))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(LinearGradient(colors: [Theme.glowWarm, Color(UIColor(hex: 0xFFD98F))], startPoint: .leading, endPoint: .trailing), in: Capsule())
        .accessibilityHidden(true)
      Spacer()
      Button { model.sheet = .notifications } label: {
        Image(systemName: "bell")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 40, height: 40)
          .background(.ultraThinMaterial, in: Circle())
          .overlay(alignment: .topTrailing) {
            if model.unseenNotices > 0 {
              Circle().fill(Theme.poor).frame(width: 9, height: 9).offset(x: -6, y: 6)
            }
          }
      }
      .accessibilityLabel(L("notices.title"))
      Menu {
        Button { model.sheet = .add } label: { Label(L("home.add"), systemImage: "plus") }
        Button { Task { await pasteFromClipboard() } } label: { Label(L("empty.paste"), systemImage: "doc.on.clipboard") }
        Button { model.sheet = .export } label: { Label(L("transfer.share"), systemImage: "square.and.arrow.up") }
        Divider()
        Button { Task { await model.refreshAll() } } label: { Label(L("home.refresh"), systemImage: "arrow.clockwise") }
        Button { model.probe(model.state.servers) } label: { Label(L("servers.test"), systemImage: "speedometer") }
        Button { model.sheet = .subscriptions } label: { Label(L("home.subscriptions"), systemImage: "tray.full") }
        Divider()
        Button { model.sheet = .diagnostics } label: { Label(L("diag.title"), systemImage: "stethoscope") }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 40, height: 40)
          .background(.ultraThinMaterial, in: Circle())
      }
      .accessibilityLabel(L("home.more"))
    }
  }

  private func pasteFromClipboard() async {
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      model.info(L("add.clipboard_empty"))
      return
    }
    _ = await model.importInput(text)
  }

  // MARK: Info row

  private var protocolText: String {
    guard let s = model.state.selectedServer else { return "—" }
    var parts = [s.protocol == "hysteria2" ? "HY2" : s.protocol.uppercased()]
    if s.security == "reality" { parts.append("Reality") } else if s.network != "tcp" { parts.append(s.network.uppercased()) }
    return parts.joined(separator: " · ")
  }

  private var infoRow: some View {
    HStack(spacing: 0) {
      infoCell(title: L("home.ip"), value: model.publicIP ?? "—", icon: "network")
      divider
      infoCell(title: L("home.location"), value: model.publicCountry.map { "\(Format.flag($0)) \(Format.country($0))" } ?? "—", icon: "location.fill")
      divider
      infoCell(title: L("home.protocol"), value: protocolText, icon: "shield.lefthalf.filled")
    }
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
  }

  private var divider: some View {
    Rectangle().fill(Theme.line).frame(width: 1, height: 28)
  }

  private func infoCell(title: String, value: String, icon: String) -> some View {
    VStack(spacing: 3) {
      HStack(spacing: 4) {
        Image(systemName: icon).font(.system(size: 9, weight: .bold))
        Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
      }
      .foregroundStyle(Theme.dim)
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
  }

  // MARK: Status

  private var statusLine: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 8) {
        Circle().fill(statusColor).frame(width: 7, height: 7).shadow(color: statusColor, radius: 4)
        Text(statusText(now: context.date))
          .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(.white)
        if vpn.isConnected, model.rateDown + model.rateUp > 0 {
          Text("↓ \(Format.rate(model.rateDown))  ↑ \(Format.rate(model.rateUp))")
            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.dim)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.ultraThinMaterial, in: Capsule())
    }
    .accessibilityElement(children: .combine)
  }

  private var statusColor: Color {
    switch vpn.status {
    case .connected, .reasserting: return Theme.good
    case .connecting, .disconnecting: return Theme.glowCool
    default: return Theme.dim
    }
  }

  private func statusText(now: Date) -> String {
    switch vpn.status {
    case .connected, .reasserting:
      let name = model.state.servers.first { $0.id == vpn.connectedServerID }?.name ?? ""
      let time = vpn.connectedDate.map { Format.duration(since: $0, now: now) } ?? ""
      return [L("status.connected"), time, name].filter { !$0.isEmpty }.joined(separator: " · ")
    case .connecting: return L("status.connecting")
    case .disconnecting: return L("status.disconnecting")
    default: return model.state.servers.isEmpty ? L("home.no_servers") : L("home.tap_star")
    }
  }

  private var emptyOverlay: some View {
    VStack(spacing: 12) {
      Text(L("empty.title")).font(Theme.title(.title3)).foregroundStyle(.white).multilineTextAlignment(.center)
      Text(L("empty.body")).font(.subheadline).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
      HStack(spacing: 10) {
        Button { Task { await pasteFromClipboard() } } label: { Label(L("empty.paste"), systemImage: "doc.on.clipboard") }
          .buttonStyle(GlowButtonStyle())
        Button { model.sheet = .add } label: { Label(L("empty.other"), systemImage: "qrcode.viewfinder") }
          .buttonStyle(GlowButtonStyle(prominent: false))
      }
    }
    .padding(18)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .padding(.horizontal, 24)
    .padding(.leading, TabRail.width)
  }

  private var storageNotice: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 12) {
        Text(L("storage.title")).font(Theme.label(.headline)).foregroundStyle(.white)
        Text(L("storage.body")).font(.subheadline).foregroundStyle(Theme.dim)
        if let e = Core.openError as? CoreError {
          Text("\(e.code) \(e.detail ?? "")").font(Theme.mono).foregroundStyle(Theme.dim)
        }
        Button { model.sheet = .diagnostics } label: { Text(L("diag.title")) }
          .buttonStyle(GlowButtonStyle(prominent: false))
        Button(role: .destructive) { Task { await model.eraseAndRestart() } } label: { Text(L("storage.reset")) }
          .buttonStyle(GlowButtonStyle(prominent: false))
      }
    }
  }
}

struct GlowButtonStyle: ButtonStyle {
  var prominent = true
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.label(.subheadline))
      .padding(.horizontal, 14)
      .frame(minHeight: 44)
      .frame(maxWidth: .infinity)
      .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white)
      .background {
        if prominent {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Theme.glowCool, Theme.glow], startPoint: .leading, endPoint: .trailing))
        } else {
          RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08))
        }
      }
      .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
  }
}
