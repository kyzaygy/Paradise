import SwiftUI
import UIKit

/// "Frost" visual language: graphite surfaces, one silver accent, rounded type (matches the app icon).
enum Theme {
  static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(UIColor { trait in
      UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
    })
  }

  static let canvas = dynamic(light: 0xEDEFF2, dark: 0x0F1115)
  static let surface = dynamic(light: 0xFFFFFF, dark: 0x191C22)
  static let surfaceRaised = dynamic(light: 0xE2E5EA, dark: 0x23272F)
  static let hairline = dynamic(light: 0xD3D8DE, dark: 0x2B3039)
  static let accent = dynamic(light: 0x3A414E, dark: 0xE3E7EE)
  static let accentSoft = dynamic(light: 0xE0E3E8, dark: 0x262A32)
  static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x14171C)
  static let warning = dynamic(light: 0xA86A12, dark: 0xF0B44C)
  static let danger = dynamic(light: 0xC23B3B, dark: 0xFF6E6E)
  static let muted = dynamic(light: 0x626A76, dark: 0x8F96A2)

  static func title(_ style: Font.TextStyle = .title2) -> Font { .system(style, design: .rounded).weight(.bold) }
  static func label(_ style: Font.TextStyle = .body) -> Font { .system(style, design: .rounded).weight(.semibold) }
  static let mono = Font.system(.footnote, design: .monospaced)

  static let radius: CGFloat = 20
}

extension UIColor {
  convenience init(hex: UInt32) {
    self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
              blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

struct Card<Content: View>: View {
  var padding: CGFloat = 16
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.label())
      .frame(maxWidth: .infinity, minHeight: 52)
      .foregroundStyle(Theme.onAccent)
      .background(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                  in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.label())
      .frame(maxWidth: .infinity, minHeight: 50)
      .foregroundStyle(Theme.accent)
      .background(Theme.accentSoft.opacity(configuration.isPressed ? 0.7 : 1),
                  in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct LatencyBadge: View {
  var value: AppModel.Latency?

  var body: some View {
    switch value {
    case .testing:
      ProgressView().controlSize(.mini)
    case .ms(let ms):
      Text(LF("latency.ms", ms))
        .font(.system(.caption, design: .rounded).weight(.semibold))
        .foregroundStyle(ms < 300 ? Theme.accent : (ms < 800 ? Theme.warning : Theme.danger))
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(Theme.danger)
        .accessibilityLabel(L("latency.failed"))
    case nil:
      EmptyView()
    }
  }
}

struct BannerView: View {
  let banner: AppModel.Banner
  var dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
        .foregroundStyle(banner.isError ? Theme.danger : Theme.accent)
      Text(banner.text)
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: dismiss) {
        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
      }
      .accessibilityLabel(L("common.close"))
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    .padding(.horizontal)
    .accessibilityElement(children: .combine)
  }
}
