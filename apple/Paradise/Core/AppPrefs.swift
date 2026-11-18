import Foundation
import SwiftUI
import UIKit

/// App-only preferences (UI behavior). Network settings live in the Go core.
final class AppPrefs: ObservableObject {
  static let shared = AppPrefs()

  private let defaults = UserDefaults.standard

  @Published var language: String { didSet { defaults.set(language, forKey: "pref.language"); Localization.reload(language) } }
  @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "pref.haptics") } }
  @Published var autorotate: Bool { didSet { defaults.set(autorotate, forKey: "pref.autorotate"); AppDelegate.applyOrientation() } }
  @Published var thirdPartyKeyboard: Bool { didSet { defaults.set(thirdPartyKeyboard, forKey: "pref.keyboard") } }
  @Published var pasteboardDetect: Bool { didSet { defaults.set(pasteboardDetect, forKey: "pref.pasteboard") } }
  @Published var vpnReminder: Bool { didSet { defaults.set(vpnReminder, forKey: "pref.vpnReminder") } }
  @Published var galaxyMotion: Bool { didSet { defaults.set(galaxyMotion, forKey: "pref.galaxyMotion") } }
  @Published var parallax: Bool { didSet { defaults.set(parallax, forKey: "pref.parallax") } }
  @Published var showPing: Bool { didSet { defaults.set(showPing, forKey: "pref.showPing") } }
  @Published var onDemand: Bool { didSet { defaults.set(onDemand, forKey: "pref.onDemand") } }
  @Published var onDemandMode: String { didSet { defaults.set(onDemandMode, forKey: "pref.onDemandMode") } }
  @Published var trustedSSIDs: [String] { didSet { defaults.set(trustedSSIDs, forKey: "pref.trustedSSIDs") } }
  @Published var probeOnLaunch: Bool { didSet { defaults.set(probeOnLaunch, forKey: "pref.probeOnLaunch") } }
  @Published var seenNotices: [String] { didSet { defaults.set(seenNotices, forKey: "pref.seenNotices") } }
  /// "auto" or a protocol family shown on the home screen (Protocol column).
  @Published var protocolFilter: String { didSet { defaults.set(protocolFilter, forKey: "pref.protocolFilter") } }

  private init() {
    let d = UserDefaults.standard
    func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
    language = d.string(forKey: "pref.language") ?? Localization.defaultLanguage
    haptics = bool("pref.haptics", true)
    autorotate = bool("pref.autorotate", false)
    thirdPartyKeyboard = bool("pref.keyboard", true)
    pasteboardDetect = bool("pref.pasteboard", false)
    vpnReminder = bool("pref.vpnReminder", false)
    galaxyMotion = bool("pref.galaxyMotion", true)
    parallax = bool("pref.parallax", true)
    showPing = bool("pref.showPing", true)
    onDemand = bool("pref.onDemand", false)
    onDemandMode = d.string(forKey: "pref.onDemandMode") ?? "always"
    trustedSSIDs = d.stringArray(forKey: "pref.trustedSSIDs") ?? []
    probeOnLaunch = bool("pref.probeOnLaunch", true)
    seenNotices = d.stringArray(forKey: "pref.seenNotices") ?? []
    protocolFilter = d.string(forKey: "pref.protocolFilter") ?? "auto"
  }

  func resetUI() {
    language = Localization.defaultLanguage
    haptics = true
    autorotate = false
    thirdPartyKeyboard = true
    pasteboardDetect = false
    vpnReminder = false
    galaxyMotion = true
    parallax = true
    showPing = true
    probeOnLaunch = true
    protocolFilter = "auto"
  }
}

/// Haptic feedback that respects the preference.
enum Haptics {
  static func tap() {
    guard AppPrefs.shared.haptics else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  static func success() {
    guard AppPrefs.shared.haptics else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  static func error() {
    guard AppPrefs.shared.haptics else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.error)
  }

  static func selection() {
    guard AppPrefs.shared.haptics else { return }
    UISelectionFeedbackGenerator().selectionChanged()
  }
}

/// In-app language override: "system", "ru" or "en". English is the default (the design is in English).
enum Localization {
  static let defaultLanguage = "en"
  private static var bundle: Bundle = load(UserDefaults.standard.string(forKey: "pref.language") ?? defaultLanguage)

  private static func load(_ language: String) -> Bundle {
    guard language != "system",
          let path = Bundle.main.path(forResource: language, ofType: "lproj"),
          let b = Bundle(path: path) else { return Bundle.main }
    return b
  }

  static func reload(_ language: String) { bundle = load(language) }

  static func string(_ key: String) -> String {
    bundle.localizedString(forKey: key, value: nil, table: nil)
  }

  static var locale: Locale {
    let lang = UserDefaults.standard.string(forKey: "pref.language") ?? defaultLanguage
    return lang == "system" ? Locale.current : Locale(identifier: lang)
  }
}
