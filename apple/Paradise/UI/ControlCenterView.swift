import SwiftUI

/// Opened by the sliders button of the action bar: Settings, routing configs and data.
struct ControlCenterView: View {
  enum Section: String, CaseIterable, Identifiable {
    case settings, config, data
    var id: String { rawValue }
  }

  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var prefs: AppPrefs
  @Environment(\.dismiss) private var dismiss

  init() {}

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Picker(L("tab.settings"), selection: $model.controlSection) {
          ForEach(Section.allCases) { section in
            Text(L("tab.\(section.rawValue)")).tag(section)
          }
        }
        .pickerStyle(.segmented)
        Button { dismiss() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.current.text)
            .frame(width: 32, height: 32)
            .background(Palette.current.raised, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("common.close"))
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 4)
      Group {
        switch model.controlSection {
        case .settings: SettingsTab()
        case .config: ConfigTab()
        case .data: DataTab()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.current.background.ignoresSafeArea())
    // follows a theme picked in Appearance while this sheet is open
    .preferredColorScheme((AppTheme(rawValue: prefs.theme) ?? .graphite).palette.isLight ? .light : .dark)
  }
}
