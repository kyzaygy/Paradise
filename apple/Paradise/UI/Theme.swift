import SwiftUI
import UIKit

/// Colors of the screens outside the home screen. They follow the theme chosen in Appearance (see Palette).
enum Theme {
  static var canvas: Color { Palette.current.background }
  static var surface: Color { Palette.current.raised }
  static var surfaceRaised: Color { Palette.current.selected }
  static var hairline: Color { Palette.current.stroke }
  static var accent: Color { Palette.current.tint }
  static var accentSoft: Color { Palette.current.raised }
  static var onAccent: Color { Palette.current.onTint }
  static var warning: Color { Palette.current.warn }
  static var danger: Color { Palette.current.danger }
  static var muted: Color { Palette.current.text3 }

  static var space: Color { Palette.current.background }
  static var spaceRaised: Color { Palette.current.raised }
  static var glow: Color { Palette.current.text }
  static var glowCool: Color { Palette.current.text2 }
  static var good: Color { Palette.current.accent }
  static var fair: Color { Palette.current.warn }
  static var poor: Color { Palette.current.danger }
  static var dim: Color { Palette.current.text3 }
  static var line: Color { Palette.current.stroke }

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
