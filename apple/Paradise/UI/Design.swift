import SwiftUI
import UIKit

/// Design tokens measured from the reference mock (640 × 1280 px, portrait).
///
/// The mock is drawn at about 1 px = 1 pt of a 640-wide screen, so every size here is in
/// reference pixels and is multiplied by `u = screen width / 640` at runtime. On a 393 pt wide
/// iPhone u ≈ 0.614, which reproduces the mock proportionally. Colors were sampled from the
/// mock; values marked "≈" were estimated from anti-aliased pixels.
enum DS {
  static let refWidth: CGFloat = 640

  // MARK: Colors
  static let background = Color(hex: 0x0B0C0E)
  static let card = Color(hex: 0x131416)
  static let cardBorder = Color.white.opacity(0.08)
  static let panel = Color(hex: 0x0E0F11)
  static let panelBorder = Color.white.opacity(0.09)
  static let tabSelected = Color(hex: 0x26272B)
  static let tabSelectedBorder = Color.white.opacity(0.06)
  static let roundButton = Color(hex: 0x161719)
  static let chip = Color(hex: 0x17181A)
  static let chipBorder = Color.white.opacity(0.04)
  static let chipSelected = Color(hex: 0x36373B)
  static let chipSelectedBorder = Color.white.opacity(0.35) // ≈
  static let routeChip = Color(hex: 0x1A1B1D)
  static let separator = Color.white.opacity(0.045)
  static let squareButton = Color(hex: 0x151618)
  static let squareBorder = Color.white.opacity(0.05)
  static let connectFill = Color(hex: 0xDADAE2)
  static let connectText = Color(hex: 0x121216)
  static let powerRing = Color(hex: 0xE8E9EB)
  static let powerFill = Color(hex: 0x1B1C1E)
  static let infoDivider = Color(hex: 0x2E2F31)
  static let badge = Color(hex: 0x1A1B1E)
  static let nodeFill = Color(hex: 0x111214).opacity(0.86)
  static let nodeBorder = Color.white.opacity(0.08)
  static let handle = Color(hex: 0x76777A)

  static let textPrimary = Color.white
  static let textValue = Color(hex: 0xD4D5D7)
  static let textSecondary = Color(hex: 0xA7A8AC)
  static let textLabel = Color(hex: 0x9D9D9F)
  static let textColumn = Color(hex: 0xB5B6BA)
  static let textSubtitle = Color(hex: 0x95969A)
  static let textChip = Color(hex: 0xE2E3E5)
  static let textRoute = Color(hex: 0xE5E6EA)
  static let textNodeMs = Color(hex: 0xA2A3A7)
  static let textBadge = Color(hex: 0xE6E7EB)
  static let radio = Color(hex: 0x717276)
  static let star = Color(hex: 0x828387)
  static let iconLight = Color(hex: 0xE4E5E7)
  /// The only accent: ping values.
  static let ping = Color(hex: 0x96D0A0) // ≈

  // MARK: Typography (reference px)
  enum Size {
    static let title: CGFloat = 18.5
    static let badge: CGFloat = 11
    static let statusTitle: CGFloat = 17.5
    static let statusSubtitle: CGFloat = 14
    static let infoLabel: CGFloat = 11.2
    static let infoValue: CGFloat = 12.3
    static let tab: CGFloat = 12
    static let chip: CGFloat = 11.5
    static let column: CGFloat = 10.8
    static let rowTitle: CGFloat = 12.3
    static let rowSubtitle: CGFloat = 10.8
    static let route: CGFloat = 10.4
    static let ping: CGFloat = 12.4
    static let nodeCode: CGFloat = 12.6
    static let nodeMs: CGFloat = 9.8
    static let connect: CGFloat = 15.5
  }

  // MARK: Geometry (reference px)
  enum Geo {
    static let refStatusBarBottom: CGFloat = 50 // the mock's status bar ends here
    static let refBottomGap: CGFloat = 69 // from the action bar to the bottom edge
    static let headerCenterY: CGFloat = 83
    static let logoCenterX: CGFloat = 48
    static let logoDiameter: CGFloat = 24
    static let titleX: CGFloat = 77
    static let badgeX: CGFloat = 176
    static let badgeSize = CGSize(width: 37, height: 20)
    static let bellCenterX: CGFloat = 538
    static let menuCenterX: CGFloat = 593
    static let card = CGRect(x: 31, y: 123, width: 578, height: 69)
    static let cardRadius: CGFloat = 15
    static let powerCenter = CGPoint(x: 73.5, y: 158)
    static let powerDiameter: CGFloat = 46
    static let statusTextX: CGFloat = 125
    static let chevronCenterX: CGFloat = 587
    static let infoLabelTop: CGFloat = 208
    static let infoValueTop: CGFloat = 226
    static let infoColumns: [CGFloat] = [48, 248, 474]
    static let infoDividers: [CGFloat] = [202, 427]
    static let infoDividerSpan: ClosedRange<CGFloat> = 210...237
    static let infoFlagDiameter: CGFloat = 16
    static let infoBottom: CGFloat = 250
    static let mapHeight: CGFloat = 495
    static let mapCenter = CGPoint(x: 327.5, y: 240)
    static let panelTop: CGFloat = 746
    static let panelInset: CGFloat = 12
    static let panelRadius: CGFloat = 26
    static let panelBottomRadius: CGFloat = 52
    static let actionBarTop: CGFloat = 1158
    static let actionBarBottom: CGFloat = 1211
    static let rowPitch: CGFloat = 46
    static let listBottom: CGFloat = 1124 // five rows below the column header
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
  }
}

/// Scale context (RefScale): converts reference pixels to points for the current screen width.
struct RefScale {
  let u: CGFloat
  init(width: CGFloat) { u = max(0.45, width / DS.refWidth) }
  func callAsFunction(_ px: CGFloat) -> CGFloat { px * u }
  func font(_ px: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: px * u, weight: weight) }

  /// SF Pro tracking in points at a point size (Apple's tracking table, interpolated).
  static func sfTracking(_ size: CGFloat) -> CGFloat {
    let table: [(CGFloat, CGFloat)] = [(6, 0.24), (7, 0.23), (8, 0.21), (9, 0.17), (10, 0.12), (11, 0.06), (12, 0), (13, -0.08),
                                       (14, -0.15), (15, -0.23), (16, -0.31), (17, -0.43), (18, -0.44), (19, -0.45), (20, -0.45)]
    guard let first = table.first, let last = table.last else { return 0 }
    if size <= first.0 { return first.1 }
    if size >= last.0 { return last.1 }
    for i in 1..<table.count where size <= table[i].0 {
      let (s0, t0) = table[i - 1], (s1, t1) = table[i]
      return t0 + (t1 - t0) * (size - s0) / (s1 - s0)
    }
    return 0
  }

  /// Extra tracking so text set at `px * u` keeps the letter spacing the mock has at `px`
  /// (the system font loosens small sizes, the mock was drawn at the larger size).
  func tracking(_ px: CGFloat) -> CGFloat { Self.sfTracking(px) * u - Self.sfTracking(px * u) }
}

extension View {
  /// Mock typography: the scaled system font with the mock's letter spacing.
  func refFont(_ s: RefScale, _ px: CGFloat, _ weight: Font.Weight = .regular, digits: Bool = false) -> some View {
    let font = s.font(px, weight)
    return self.font(digits ? font.monospacedDigit() : font).tracking(s.tracking(px))
  }
}

/// A flat round country flag (flag-icons, square artwork clipped to a circle);
/// the emoji flag for codes without artwork, a globe when the country is unknown.
struct RoundFlag: View {
  let cc: String?
  let diameter: CGFloat

  var body: some View {
    ZStack {
      Circle().fill(Color.white.opacity(0.10))
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
          .foregroundStyle(DS.textSecondary)
      }
    }
    .frame(width: diameter, height: diameter)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }
}

/// The round monochrome globe used as the logo in the header: a light sphere with dark land.
struct GlobeLogo: View {
  let diameter: CGFloat

  var body: some View {
    ZStack {
      Circle().fill(RadialGradient(colors: [Color(hex: 0xE4E4E6), Color(hex: 0xBDBEC1), Color(hex: 0x8C8D90)],
                                   center: .init(x: 0.38, y: 0.32), startRadius: 0, endRadius: diameter * 0.62))
      // the symbol's outline ring is pushed outside the clip, only the continents remain
      Image(systemName: "globe.europe.africa.fill")
        .resizable()
        .scaledToFit()
        .foregroundStyle(Color(hex: 0x17181A))
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
