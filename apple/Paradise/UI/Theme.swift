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

  // Galaxy palette (dark, used across the redesigned screens)
  static let space = Color(UIColor(hex: 0x05060D))
  static let spaceRaised = Color(UIColor(hex: 0x0D0F1C))
  static let glow = Color(UIColor(hex: 0x8C7BFF))
  static let glowWarm = Color(UIColor(hex: 0xFFB36B))
  static let glowCool = Color(UIColor(hex: 0x63D3FF))
  static let good = Color(UIColor(hex: 0x4BE3A0))
  static let fair = Color(UIColor(hex: 0xF5C451))
  static let poor = Color(UIColor(hex: 0xFF6B7A))
  static let dim = Color(UIColor(hex: 0x8A90A8))
  static let line = Color.white.opacity(0.08)

  /// Latency color: green under 150 ms, yellow under 400 ms, red above.
  static func latencyColor(_ ms: Int64?) -> Color {
    guard let ms = ms else { return dim }
    if ms < 150 { return good }
    if ms < 400 { return fair }
    return poor
  }

  /// Signal bars (0…4) for a latency value.
  static func bars(_ ms: Int64?) -> Int {
    guard let ms = ms else { return 0 }
    if ms < 120 { return 4 }
    if ms < 250 { return 3 }
    if ms < 500 { return 2 }
    return 1
  }

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

struct SignalBars: View {
  var bars: Int
  var color: Color

  var body: some View {
    HStack(alignment: .bottom, spacing: 1.5) {
      ForEach(0..<4, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1)
          .fill(i < bars ? color : Color.white.opacity(0.18))
          .frame(width: 2.5, height: CGFloat(4 + i * 2.5))
      }
    }
    .accessibilityHidden(true)
  }
}

/// Glass card used on the dark screens.
struct GlassCard<Content: View>: View {
  var padding: CGFloat = 14
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
  }
}

struct BannerView: View {
  let banner: AppModel.Banner
  var dismiss: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
        .foregroundStyle(banner.isError ? Theme.danger : Theme.good)
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
