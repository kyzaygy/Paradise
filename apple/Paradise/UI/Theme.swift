import SwiftUI
import UIKit

/// Monochrome visual language of the home screen (see DS): near-black surfaces, light-grey accent.
/// Color carries meaning only for latency (green) and for warnings and errors.
enum Theme {
  static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(UIColor { trait in
      UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
    })
  }

  static let canvas = dynamic(light: 0xEDEEF0, dark: 0x0B0C0E)
  static let surface = dynamic(light: 0xFFFFFF, dark: 0x131416)
  static let surfaceRaised = dynamic(light: 0xE3E4E7, dark: 0x1B1C1F)
  static let hairline = dynamic(light: 0xD4D5D9, dark: 0x26272A)
  static let accent = dynamic(light: 0x2A2B30, dark: 0xDADAE2)
  static let accentSoft = dynamic(light: 0xE1E2E6, dark: 0x1D1E21)
  static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x121216)
  static let warning = dynamic(light: 0x9A6A1C, dark: 0xE0B05A)
  static let danger = dynamic(light: 0xB83A3A, dark: 0xE57373)
  static let muted = dynamic(light: 0x5F6066, dark: 0x95969A)

  // Dark palette of the redesigned screens
  static let space = Color(UIColor(hex: 0x0B0C0E))
  static let spaceRaised = Color(UIColor(hex: 0x131416))
  static let glow = Color(UIColor(hex: 0xE4E5E7))
  static let glowCool = Color(UIColor(hex: 0xB5B6BA))
  static let good = Color(UIColor(hex: 0x96D0A0))
  static let fair = Color(UIColor(hex: 0xE0B05A))
  static let poor = Color(UIColor(hex: 0xE57373))
  static let dim = Color(UIColor(hex: 0x8E8F93))
  static let line = Color.white.opacity(0.08)

  static func title(_ style: Font.TextStyle = .title2) -> Font { .system(style).weight(.bold) }
  static func label(_ style: Font.TextStyle = .body) -> Font { .system(style).weight(.semibold) }
  static let mono = Font.system(.footnote, design: .monospaced)

  static let radius: CGFloat = 15
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
        .foregroundStyle(Theme.good)
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
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
        .foregroundStyle(banner.isError ? Theme.danger : Theme.accent)
      Text(banner.text)
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let title = banner.actionTitle, let action = banner.action {
        Button {
          dismiss()
          action()
        } label: {
          Text(title).font(Theme.label(.subheadline)).foregroundStyle(Theme.glow)
        }
        .buttonStyle(.plain)
      }
      Button(action: dismiss) {
        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
      }
      .accessibilityLabel(L("common.close"))
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    .padding(.horizontal)
    .accessibilityElement(children: .contain)
  }
}
