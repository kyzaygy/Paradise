import SwiftUI
import UIKit

/// The color themes of the app. A theme restyles every screen and the space map.
enum AppTheme: String, CaseIterable, Identifiable {
  case graphite, oled, nebula, aurora, solar, light

  var id: String { rawValue }
  var title: String { L("theme.\(rawValue)") }

  /// The theme chosen in Appearance (Graphite until another one is picked).
  static var current: AppTheme { AppTheme(rawValue: AppPrefs.shared.theme) ?? .graphite }

  var palette: Palette {
    switch self {
    case .graphite: return .graphite
    case .oled: return .oled
    case .nebula: return .nebula
    case .aurora: return .aurora
    case .solar: return .solar
    case .light: return .light
    }
  }
}

/// Colors of one theme.
struct Palette {
  let isLight: Bool
  // space
  let spaceTop: Color
  let spaceBottom: Color
  /// Stars, the web of the galaxy and the orbits.
  let ink: UIColor
  /// The core, comets and the data flow to the connected country.
  let glow: UIColor
  let nebula: UIColor
  let nebula2: UIColor
  // surfaces
  let background: Color
  /// Tint over the blur of cards and round buttons.
  let glass: Color
  /// Tint over the blur of the server panel.
  let panel: Color
  /// Chips, route labels and small buttons.
  let raised: Color
  /// The selected tab or chip.
  let selected: Color
  let stroke: Color
  let strokeStrong: Color
  let separator: Color
  // text
  let text: Color
  let text2: Color
  let text3: Color
  // meaning
  /// Good latency and the connected state.
  let accent: Color
  let warn: Color
  let danger: Color
  /// System controls: switches, links, pickers.
  let tint: Color
  let onTint: Color
  let connectFill: Color
  let connectText: Color

  static var current: Palette { AppTheme.current.palette }

  /// Latency in the theme's colors: accent up to 180 ms, amber up to 350 ms, red above.
  func latencyColor(_ ms: Int64) -> Color { ms <= 180 ? accent : (ms <= 350 ? warn : danger) }

  var spaceInk: SpaceInk { SpaceInk(ink: ink, glow: glow, nebula: nebula, nebula2: nebula2, isLight: isLight) }
}

/// The UIKit colors of the space renderer, which draws off the main thread.
struct SpaceInk {
  let ink: UIColor
  let glow: UIColor
  let nebula: UIColor
  let nebula2: UIColor
  let isLight: Bool
}

extension Palette {
  static let graphite = Palette(
    isLight: false,
    spaceTop: Color(hex: 0x101116), spaceBottom: Color(hex: 0x060709),
    ink: UIColor(hex: 0xFFFFFF), glow: UIColor(hex: 0xFFFFFF), nebula: UIColor(hex: 0x7E8BA8), nebula2: UIColor(hex: 0xA3A9B8),
    background: Color(hex: 0x0A0B0D), glass: Color(hex: 0x17181C).opacity(0.6), panel: Color(hex: 0x0E0F12).opacity(0.78),
    raised: Color(hex: 0x1E1F23), selected: Color(hex: 0x303136), stroke: Color.white.opacity(0.1),
    strokeStrong: Color.white.opacity(0.34), separator: Color.white.opacity(0.06),
    text: Color(hex: 0xF5F5F7), text2: Color(hex: 0xB4B6BD), text3: Color(hex: 0x83858D),
    accent: Color(hex: 0x8FD9A8), warn: Color(hex: 0xE9BB66), danger: Color(hex: 0xEE7C74),
    tint: Color(hex: 0xDCDCE4), onTint: Color(hex: 0x111216),
    connectFill: Color(hex: 0xEDEDF3), connectText: Color(hex: 0x0F1014))

  static let oled = Palette(
    isLight: false,
    spaceTop: Color(hex: 0x000000), spaceBottom: Color(hex: 0x000000),
    ink: UIColor(hex: 0xFFFFFF), glow: UIColor(hex: 0xFFFFFF), nebula: UIColor(hex: 0x4B5266), nebula2: UIColor(hex: 0x5E6372),
    background: Color(hex: 0x000000), glass: Color(hex: 0x0C0C0E).opacity(0.72), panel: Color(hex: 0x050506).opacity(0.86),
    raised: Color(hex: 0x141416), selected: Color(hex: 0x26262A), stroke: Color.white.opacity(0.11),
    strokeStrong: Color.white.opacity(0.4), separator: Color.white.opacity(0.07),
    text: Color(hex: 0xFFFFFF), text2: Color(hex: 0xB9B9BF), text3: Color(hex: 0x86868E),
    accent: Color(hex: 0x7EE2A2), warn: Color(hex: 0xF0C060), danger: Color(hex: 0xF27A72),
    tint: Color(hex: 0xFFFFFF), onTint: Color(hex: 0x000000),
    connectFill: Color(hex: 0xFFFFFF), connectText: Color(hex: 0x000000))

  static let nebula = Palette(
    isLight: false,
    spaceTop: Color(hex: 0x15112C), spaceBottom: Color(hex: 0x07060F),
    ink: UIColor(hex: 0xDCD3FF), glow: UIColor(hex: 0xEEE8FF), nebula: UIColor(hex: 0x8B5CF6), nebula2: UIColor(hex: 0x3B82F6),
    background: Color(hex: 0x0B0A16), glass: Color(hex: 0x1A1630).opacity(0.6), panel: Color(hex: 0x110F22).opacity(0.8),
    raised: Color(hex: 0x231F3E), selected: Color(hex: 0x372F60), stroke: Color(hex: 0xC4B5FD).opacity(0.13),
    strokeStrong: Color(hex: 0xC4B5FD).opacity(0.45), separator: Color(hex: 0xC4B5FD).opacity(0.08),
    text: Color(hex: 0xF5F2FF), text2: Color(hex: 0xBBB5DC), text3: Color(hex: 0x8B86AE),
    accent: Color(hex: 0xB9A4FF), warn: Color(hex: 0xF2C46D), danger: Color(hex: 0xF5838B),
    tint: Color(hex: 0xB9A4FF), onTint: Color(hex: 0x15102E),
    connectFill: Color(hex: 0xD6CBFF), connectText: Color(hex: 0x15102E))

  static let aurora = Palette(
    isLight: false,
    spaceTop: Color(hex: 0x0A1D1B), spaceBottom: Color(hex: 0x040A09),
    ink: UIColor(hex: 0xD2FAF1), glow: UIColor(hex: 0xE8FFFA), nebula: UIColor(hex: 0x14B8A6), nebula2: UIColor(hex: 0x22C55E),
    background: Color(hex: 0x061110), glass: Color(hex: 0x10221F).opacity(0.6), panel: Color(hex: 0x0A1716).opacity(0.8),
    raised: Color(hex: 0x14302C), selected: Color(hex: 0x1F4540), stroke: Color(hex: 0x99F6E4).opacity(0.12),
    strokeStrong: Color(hex: 0x99F6E4).opacity(0.42), separator: Color(hex: 0x99F6E4).opacity(0.07),
    text: Color(hex: 0xF0FFFB), text2: Color(hex: 0xA9CCC5), text3: Color(hex: 0x799891),
    accent: Color(hex: 0x5EEAD4), warn: Color(hex: 0xEFC56A), danger: Color(hex: 0xF08A7E),
    tint: Color(hex: 0x5EEAD4), onTint: Color(hex: 0x05201C),
    connectFill: Color(hex: 0xA7F3E4), connectText: Color(hex: 0x05201C))

  static let solar = Palette(
    isLight: false,
    spaceTop: Color(hex: 0x1C130A), spaceBottom: Color(hex: 0x0A0704),
    ink: UIColor(hex: 0xFFEACB), glow: UIColor(hex: 0xFFF4DC), nebula: UIColor(hex: 0xF59E0B), nebula2: UIColor(hex: 0xEF4444),
    background: Color(hex: 0x100B06), glass: Color(hex: 0x241B11).opacity(0.6), panel: Color(hex: 0x1A130B).opacity(0.8),
    raised: Color(hex: 0x2C2115), selected: Color(hex: 0x40311D), stroke: Color(hex: 0xFCD34D).opacity(0.12),
    strokeStrong: Color(hex: 0xFCD34D).opacity(0.42), separator: Color(hex: 0xFCD34D).opacity(0.07),
    text: Color(hex: 0xFFF8EE), text2: Color(hex: 0xD8C6AA), text3: Color(hex: 0xA28E72),
    accent: Color(hex: 0xFBBF24), warn: Color(hex: 0xFB923C), danger: Color(hex: 0xF87171),
    tint: Color(hex: 0xFBBF24), onTint: Color(hex: 0x2A1A03),
    connectFill: Color(hex: 0xFDE3A0), connectText: Color(hex: 0x2A1A03))

  static let light = Palette(
    isLight: true,
    spaceTop: Color(hex: 0xF6F7FA), spaceBottom: Color(hex: 0xE3E7EE),
    ink: UIColor(hex: 0x1F2737), glow: UIColor(hex: 0x52617E), nebula: UIColor(hex: 0x8FA3C8), nebula2: UIColor(hex: 0xB7A6D6),
    background: Color(hex: 0xEFF1F5), glass: Color.white.opacity(0.55), panel: Color.white.opacity(0.72),
    raised: Color(hex: 0xFFFFFF), selected: Color(hex: 0xDFE3EA), stroke: Color.black.opacity(0.08),
    strokeStrong: Color.black.opacity(0.3), separator: Color.black.opacity(0.07),
    text: Color(hex: 0x0E1116), text2: Color(hex: 0x4A505E), text3: Color(hex: 0x7A808E),
    accent: Color(hex: 0x15924A), warn: Color(hex: 0xB7791F), danger: Color(hex: 0xC2413A),
    tint: Color(hex: 0x1F2737), onTint: Color(hex: 0xFFFFFF),
    connectFill: Color(hex: 0x12151B), connectText: Color(hex: 0xFFFFFF))
}

extension Color {
  init(hex: UInt32) {
    self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
  }
}

/// Sizes of the home screen are points on a 393 pt wide iPhone, scaled by `k` on other widths.
struct HomeMetrics {
  let k: CGFloat
  init(width: CGFloat) { k = min(1.12, max(0.88, width / 393)) }
  func callAsFunction(_ value: CGFloat) -> CGFloat { value * k }
  func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * k, weight: weight) }
}

extension View {
  /// Frosted glass: the blur of what is behind, the theme's tint and a hairline that is lighter on top.
  func glass<S: InsettableShape>(_ shape: S, tint: Color? = nil, stroke: Color? = nil) -> some View {
    let p = Palette.current
    let edge = stroke ?? p.stroke
    return background {
      ZStack {
        shape.fill(.ultraThinMaterial)
        shape.fill(tint ?? p.glass)
      }
    }
    .overlay(shape.strokeBorder(LinearGradient(colors: [edge, edge.opacity(0.45)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
  }
}

/// Buttons shrink a little while pressed.
struct PressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

/// Buttons inside cards dim while pressed.
struct DimOnPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.6 : 1)
      .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
  }
}

/// A flat round country flag (flag-icons, square artwork clipped to a circle);
/// the emoji flag for codes without artwork, a globe when the country is unknown.
struct RoundFlag: View {
  let cc: String?
  let diameter: CGFloat

  var body: some View {
    let p = Palette.current
    ZStack {
      Circle().fill(p.raised)
      if let code = cc?.lowercased(), code.count == 2 {
        if let image = UIImage(named: "Flags/\(code)") {
          Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: diameter, height: diameter)
        } else {
          Text(Format.flag(code))
            .font(.system(size: diameter * 1.42))
            .fixedSize()
            .frame(width: diameter, height: diameter)
        }
      } else {
        Image(systemName: "globe")
          .font(.system(size: diameter * 0.62, weight: .regular))
          .foregroundStyle(p.text2)
      }
    }
    .frame(width: diameter, height: diameter)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(p.stroke, lineWidth: 0.5))
    .accessibilityHidden(true)
  }
}

/// The round globe of the header: a sphere in the text color with land in the background color.
struct GlobeLogo: View {
  let diameter: CGFloat

  var body: some View {
    let p = Palette.current
    ZStack {
      Circle().fill(RadialGradient(colors: [p.text, p.text2, p.text3], center: .init(x: 0.38, y: 0.32), startRadius: 0, endRadius: diameter * 0.62))
      // the symbol's outline ring is pushed outside the clip, only the continents remain
      Image(systemName: "globe.europe.africa.fill")
        .resizable()
        .scaledToFit()
        .foregroundStyle(p.background)
        .scaleEffect(1.14)
    }
    .frame(width: diameter, height: diameter)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }
}

extension Haptics {
  static func soft() {
    guard AppPrefs.shared.haptics else { return }
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
  }
}
