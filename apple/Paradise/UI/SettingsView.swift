import SwiftUI
import UIKit

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @Environment(\.dismiss) private var dismiss
  @State private var confirmReset = false
  @State private var showLicenses = false

  init() {}

  private var version: String {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(v) (\(b))"
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker(L("settings.mode"), selection: binding(\.mode, key: "mode", hint: true)) {
            Text(L("mode.all")).tag("all")
            Text(L("mode.profile")).tag("profile")
          }
        } footer: {
          Text(L("settings.mode_footer"))
        }

        Section {
          Toggle(L("settings.kill_switch"), isOn: binding(\.killSwitch, key: "killSwitch", hint: true))
        } footer: {
          Text(L("settings.kill_switch_footer"))
        }

        Section {
          Toggle(L("settings.auto_refresh"), isOn: binding(\.autoRefresh, key: "autoRefresh"))
          Toggle(L("settings.send_hwid"), isOn: binding(\.sendHwid, key: "sendHwid"))
          if !model.state.hwid.isEmpty {
            HStack {
              Text(L("settings.hwid"))
              Spacer()
              Text(String(model.state.hwid.prefix(8)) + "…").font(Theme.mono).foregroundStyle(Theme.muted)
            }
            .contextMenu {
              Button(L("common.copy")) { UIPasteboard.general.string = model.state.hwid }
            }
          }
        } header: {
          Text(L("settings.subscriptions"))
        } footer: {
          Text(L("settings.send_hwid_footer"))
        }

        Section(L("settings.about")) {
          LabeledContent(L("settings.version"), value: version)
          LabeledContent("Xray-core", value: Core.isOpen ? Core.xrayVersion : "—")
          Button(L("settings.licenses")) { showLicenses = true }
          Button { model.sheet = .diagnostics } label: {
            Label(L("diag.title"), systemImage: "stethoscope")
          }
          Text(L("settings.language")).font(.footnote).foregroundStyle(Theme.muted)
        }

        Section {
          Button(L("settings.reset"), role: .destructive) { confirmReset = true }
        } footer: {
          Text(L("settings.privacy"))
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.canvas)
      .navigationTitle(L("settings.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) { Button(L("common.done")) { dismiss() } }
      }
      .confirmationDialog(L("settings.reset_confirm"), isPresented: $confirmReset, titleVisibility: .visible) {
        Button(L("settings.reset"), role: .destructive) { Task { await model.resetAll() } }
      }
      .sheet(isPresented: $showLicenses) { LicensesView() }
    }
  }

  private func binding<T>(_ path: WritableKeyPath<CoreSettings, T>, key: String, hint: Bool = false) -> Binding<T> {
    Binding(
      get: { model.state.settings[keyPath: path] },
      set: { value in Task { await model.updateSettings([key: value], reconnectHint: hint) } }
    )
  }
}

struct LicensesView: View {
  @Environment(\.dismiss) private var dismiss

  init() {}

  private var text: String {
    guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "txt"),
          let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    return s
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(text).font(Theme.mono).padding().frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(L("settings.licenses"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(L("common.done")) { dismiss() } } }
    }
  }
}
