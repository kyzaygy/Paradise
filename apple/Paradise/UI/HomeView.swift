import NetworkExtension
import SwiftUI
import UIKit

struct HomeView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  init() {}

  var body: some View {
    ZStack(alignment: .top) {
      Theme.canvas.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 22) {
          header
          if !model.online { offlineNotice }
          if model.loading {
            ProgressView().padding(.top, 120)
          } else if model.storageBroken {
            storageNotice
          } else if model.state.servers.isEmpty {
            emptyState
          } else {
            connection
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
      }
      .refreshable { await model.refreshAll() }
      if let banner = model.banner {
        BannerView(banner: banner) { model.banner = nil }
          .padding(.top, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
          .task(id: banner.id) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if model.banner?.id == banner.id { withAnimation { model.banner = nil } }
          }
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.banner)
  }

  private var header: some View {
    HStack {
      Button { model.sheet = .add } label: {
        Image(systemName: "plus").font(.title3.weight(.semibold))
          .frame(width: 44, height: 44)
          .background(Theme.surface, in: Circle())
      }
      .accessibilityLabel(L("home.add"))
      Spacer()
      Text("Paradise").font(Theme.title(.title3)).accessibilityAddTraits(.isHeader)
        .onLongPressGesture(minimumDuration: 0.8) { model.sheet = .diagnostics }
      Spacer()
      Button { model.sheet = .settings } label: {
        Image(systemName: "gearshape").font(.title3.weight(.semibold))
          .frame(width: 44, height: 44)
          .background(Theme.surface, in: Circle())
      }
      .accessibilityLabel(L("home.settings"))
    }
    .foregroundStyle(.primary)
    .padding(.top, 8)
  }

  private var offlineNotice: some View {
    Label(L("home.offline"), systemImage: "wifi.slash")
      .font(.subheadline.weight(.medium))
      .foregroundStyle(Theme.warning)
      .frame(maxWidth: .infinity)
      .padding(12)
      .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var storageNotice: some View {
    Card {
      VStack(alignment: .leading, spacing: 12) {
        Text(L("storage.title")).font(Theme.label(.headline))
        Text(L("storage.body")).font(.subheadline).foregroundStyle(Theme.muted)
        if let e = Core.openError as? CoreError {
          Text("\(e.code) \(e.detail ?? "")").font(Theme.mono).foregroundStyle(Theme.muted)
        }
        Button { model.sheet = .diagnostics } label: { Text(L("diag.title")) }
          .buttonStyle(SecondaryButtonStyle())
        Button(role: .destructive) { Task { await model.eraseAndRestart() } } label: {
          Text(L("storage.reset"))
        }
        .buttonStyle(SecondaryButtonStyle())
      }
    }
    .padding(.top, 40)
  }

  private var emptyState: some View {
    VStack(spacing: 18) {
      ConnectOrb(status: .disconnected, enabled: false) { model.sheet = .add }
        .padding(.top, 24)
      VStack(spacing: 8) {
        Text(L("empty.title")).font(Theme.title(.title2)).multilineTextAlignment(.center)
        Text(L("empty.body")).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
      }
      Button { Task { await pasteFromClipboard() } } label: {
        Label(L("empty.paste"), systemImage: "doc.on.clipboard")
      }
      .buttonStyle(PrimaryButtonStyle())
      Button { model.sheet = .add } label: {
        Label(L("empty.other"), systemImage: "qrcode.viewfinder")
      }
      .buttonStyle(SecondaryButtonStyle())
    }
  }

  private func pasteFromClipboard() async {
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      model.info(L("add.clipboard_empty"))
      return
    }
    _ = await model.importInput(text)
  }

  private var connection: some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        ConnectOrb(status: vpn.status, enabled: true) { Task { await model.toggleConnection() } }
          .disabled(vpn.busy && vpn.status != .connecting)
        Text(ConnectOrb.statusText(vpn.status))
          .font(Theme.title(.title3))
          .foregroundStyle(vpn.isConnected ? Theme.accent : .primary)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(timerText(now: context.date))
            .font(.system(.subheadline, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.muted)
        }
      }
      .padding(.top, 8)

      serverCard
      modePicker
      transferRow
    }
  }

  private func timerText(now: Date) -> String {
    if let date = vpn.connectedDate, vpn.isConnected { return Format.duration(since: date, now: now) }
    if vpn.isConnected { return " " }
    return L("home.tap_to_connect")
  }

  private var serverCard: some View {
    Button { model.sheet = .servers } label: {
      Card {
        HStack(spacing: 14) {
          Image(systemName: "globe.europe.africa.fill")
            .font(.title2)
            .foregroundStyle(Theme.accent)
            .frame(width: 44, height: 44)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          VStack(alignment: .leading, spacing: 3) {
            Text(model.state.selectedServer?.name ?? L("home.choose_server"))
              .font(Theme.label(.headline))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Text(model.state.selectedServer?.detail ?? "")
              .font(.caption)
              .foregroundStyle(Theme.muted)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          if let id = model.state.selectedServer?.id { LatencyBadge(value: model.latency[id]) }
          Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityHint(L("home.a11y.servers"))
  }

  private var modePicker: some View {
    Menu {
      Picker(L("settings.mode"), selection: Binding(
        get: { model.state.settings.mode },
        set: { value in Task { await model.updateSettings(["mode": value], reconnectHint: true) } }
      )) {
        Text(L("mode.all")).tag("all")
        Text(L("mode.profile")).tag("profile")
      }
    } label: {
      HStack {
        Image(systemName: model.state.settings.mode == "all" ? "arrow.triangle.branch" : "list.bullet.indent")
          .foregroundStyle(Theme.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text(L("settings.mode")).font(.caption).foregroundStyle(Theme.muted)
          Text(model.state.settings.mode == "all" ? L("mode.all") : L("mode.profile"))
            .font(Theme.label(.subheadline)).foregroundStyle(.primary)
        }
        Spacer()
        Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Theme.muted)
      }
      .padding(16)
      .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
  }

  private var transferRow: some View {
    HStack(spacing: 12) {
      Button { model.sheet = .export } label: {
        Label(L("transfer.share"), systemImage: "square.and.arrow.up")
      }
      Button { model.sheet = .add } label: {
        Label(L("transfer.receive"), systemImage: "square.and.arrow.down")
      }
    }
    .buttonStyle(SecondaryButtonStyle())
  }
}
