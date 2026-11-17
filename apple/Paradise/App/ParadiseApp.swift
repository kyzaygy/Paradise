import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    if UIDevice.current.userInterfaceIdiom == .pad { return .all }
    return AppPrefs.shared.autorotate ? .allButUpsideDown : .portrait
  }

  func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
    if extensionPointIdentifier == .keyboard { return AppPrefs.shared.thirdPartyKeyboard }
    return true
  }

  /// Asks the window to re-read the supported orientations after the preference changes.
  nonisolated static func applyOrientation() {
    DispatchQueue.main.async {
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows {
          window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if !AppPrefs.shared.autorotate && UIDevice.current.userInterfaceIdiom != .pad {
          windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
      }
    }
  }
}

@main
struct ParadiseApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()
  @StateObject private var prefs = AppPrefs.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView()
        .id(prefs.language)
        .environmentObject(model)
        .environmentObject(model.vpn)
        .environmentObject(prefs)
        .environment(\.locale, Localization.locale)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .onOpenURL { url in model.handle(url: url) }
    }
    .onChange(of: scenePhase) { phase in
      switch phase {
      case .active: model.becameActive()
      case .background: model.becameInactive()
      default: break
      }
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @EnvironmentObject private var prefs: AppPrefs

  init() {}

  var body: some View {
    GeometryReader { _ in
      ZStack(alignment: .topLeading) {
        Theme.space.ignoresSafeArea()
        Group {
          switch model.tab {
          case .home: HomeView()
          case .config: ConfigTab().padding(.leading, TabRail.width)
          case .data: DataTab().padding(.leading, TabRail.width)
          case .settings: SettingsTab().padding(.leading, TabRail.width)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if !(model.tab == .home && model.railHidden) {
          TabRail()
            .padding(.top, model.tab == .home ? 124 : 64)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
        if let banner = model.banner {
          BannerView(banner: banner) { model.banner = nil }
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: banner.id) {
              try? await Task.sleep(nanoseconds: banner.action == nil ? 5_000_000_000 : 8_000_000_000)
              if model.banner?.id == banner.id { withAnimation { model.banner = nil } }
            }
            .zIndex(10)
        }
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.banner)
    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.railHidden)
    .sheet(item: $model.sheet) { sheet in
      Group {
        switch sheet {
        case .subscriptions: ServersView()
        case .add: AddView()
        case .export: ExportView()
        case .diagnostics: DiagnosticsView()
        case .notifications: NotificationsView()
        case .preview(let code): ImportPreviewView(code: code)
        }
      }
      .environmentObject(model)
      .environmentObject(vpn)
      .environmentObject(prefs)
      .preferredColorScheme(.dark)
    }
  }
}

/// The left rail with the four sections.
struct TabRail: View {
  static let width: CGFloat = 60
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 6) {
      ForEach(AppModel.Tab.allCases) { tab in
        Button {
          guard model.tab != tab else { return }
          Haptics.selection()
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.tab = tab }
        } label: {
          VStack(spacing: 3) {
            Image(systemName: tab.icon)
              .font(.system(size: 17, weight: .semibold))
              .frame(width: 40, height: 34)
              .background {
                if model.tab == tab {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.glow.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.glow.opacity(0.55), lineWidth: 1))
                    .shadow(color: Theme.glow.opacity(0.55), radius: 8)
                }
              }
            Text(tab.title)
              .font(.system(size: 9, weight: .semibold, design: .rounded))
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
          .foregroundStyle(model.tab == tab ? Color.white : Theme.dim)
          .frame(width: 52)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
      }
    }
    .padding(.vertical, 10)
    .frame(width: 56)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    .padding(.leading, 4)
  }
}
