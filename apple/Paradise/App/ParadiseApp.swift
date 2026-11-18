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
    ZStack(alignment: .top) {
      DS.background.ignoresSafeArea()
      HomeView()
      if let banner = model.banner {
        BannerView(banner: banner) { model.banner = nil }
          .padding(.top, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
          .task(id: banner.id) {
            try? await Task.sleep(nanoseconds: banner.action == nil ? 5_000_000_000 : 8_000_000_000)
            if model.banner?.id == banner.id { withAnimation { model.banner = nil } }
          }
          .zIndex(10)
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.banner)
    .sheet(item: $model.sheet) { sheet in
      Group {
        switch sheet {
        case .subscriptions: ServersView()
        case .add: AddView()
        case .export: ExportView()
        case .diagnostics: DiagnosticsView()
        case .notifications: NotificationsView()
        case .controlCenter: ControlCenterView()
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
