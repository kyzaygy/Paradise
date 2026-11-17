import SwiftUI

@main
struct ParadiseApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .environmentObject(model.vpn)
        .tint(Theme.accent)
        .task { await model.start() }
        .onOpenURL { url in model.handle(url: url) }
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController

  init() {}

  var body: some View {
    HomeView()
      .sheet(item: $model.sheet) { sheet in
        Group {
          switch sheet {
          case .servers: ServersView()
          case .add: AddView()
          case .export: ExportView()
          case .settings: SettingsView()
          case .diagnostics: DiagnosticsView()
          case .preview(let code): ImportPreviewView(code: code)
          }
        }
        .environmentObject(model)
        .environmentObject(vpn)
      }
  }
}
