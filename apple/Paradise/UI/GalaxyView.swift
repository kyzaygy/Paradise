import CoreMotion
import NetworkExtension
import SwiftUI
import UIKit

/// Deterministic random numbers so the galaxy looks the same on every launch.
struct SeededRandom {
  private var state: UInt64
  init(seed: UInt64) { state = seed }

  mutating func next() -> Double {
    state &+= 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    z ^= z >> 31
    return Double(z >> 11) / Double(1 << 53)
  }

  mutating func gaussian() -> Double {
    let u = max(next(), 1e-9), v = next()
    return sqrt(-2 * log(u)) * cos(2 * .pi * v)
  }
}

/// Renders the spiral galaxy texture once (off the main thread).
enum GalaxyTexture {
  static func render(pixels: Int) -> UIImage {
    let size = CGSize(width: pixels, height: pixels)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { context in
      let cg = context.cgContext
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      let maxR = Double(size.width) * 0.48
      var rng = SeededRandom(seed: 0x50A7AD15E)
      cg.setBlendMode(.plusLighter)

      // soft nebula clouds along the arms
      for i in 0..<220 {
        let arm = Double(i % 3)
        let t = pow(rng.next(), 0.7)
        let angle = arm * 2 * .pi / 3 + t * 4.4 + rng.gaussian() * 0.32
        let r = t * maxR * 0.95
        let p = CGPoint(x: c.x + CGFloat(cos(angle) * r), y: c.y + CGFloat(sin(angle) * r))
        let radius = CGFloat(18 + rng.next() * 46) * CGFloat(1 - t * 0.5)
        let hue: (CGFloat, CGFloat, CGFloat) = rng.next() < 0.3 ? (0.95, 0.45, 0.85) : (0.45, 0.42, 1.0)
        let colors = [UIColor(red: hue.0, green: hue.1, blue: hue.2, alpha: 0.10).cgColor, UIColor(red: hue.0, green: hue.1, blue: hue.2, alpha: 0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
          cg.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
        }
      }

      // stars in three logarithmic spiral arms
      for i in 0..<5200 {
        let arm = Double(i % 3)
        let t = pow(rng.next(), 0.85)
        let scatter = rng.gaussian() * (0.42 * (1 - t) + 0.12)
        let angle = arm * 2 * .pi / 3 + t * 4.4 + scatter
        let r = t * maxR + rng.gaussian() * 6
        let p = CGPoint(x: c.x + CGFloat(cos(angle) * r), y: c.y + CGFloat(sin(angle) * r))
        let color: UIColor
        switch t {
        case ..<0.18: color = UIColor(red: 1.0, green: 0.90, blue: 0.75, alpha: 1)
        case ..<0.5: color = rng.next() < 0.2 ? UIColor(red: 1.0, green: 0.55, blue: 0.85, alpha: 1) : UIColor(red: 0.78, green: 0.68, blue: 1.0, alpha: 1)
        default: color = rng.next() < 0.15 ? UIColor(red: 1.0, green: 0.7, blue: 0.9, alpha: 1) : UIColor(red: 0.55, green: 0.75, blue: 1.0, alpha: 1)
        }
        let s = CGFloat(0.6 + rng.next() * rng.next() * 2.6)
        cg.setFillColor(color.withAlphaComponent(CGFloat(0.25 + rng.next() * 0.7)).cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
      }

      // halo of loose stars
      for _ in 0..<900 {
        let angle = rng.next() * 2 * .pi
        let r = sqrt(rng.next()) * maxR * 1.02
        let p = CGPoint(x: c.x + CGFloat(cos(angle) * r), y: c.y + CGFloat(sin(angle) * r))
        let s = CGFloat(0.5 + rng.next() * 1.2)
        cg.setFillColor(UIColor(white: 1, alpha: CGFloat(0.15 + rng.next() * 0.45)).cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
      }

      // bright core
      let core = [UIColor(red: 1, green: 0.97, blue: 0.9, alpha: 0.95).cgColor,
                  UIColor(red: 1, green: 0.8, blue: 0.6, alpha: 0.45).cgColor,
                  UIColor(red: 0.7, green: 0.55, blue: 1, alpha: 0.12).cgColor,
                  UIColor(red: 0.5, green: 0.4, blue: 1, alpha: 0).cgColor] as CFArray
      if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: core, locations: [0, 0.12, 0.45, 1]) {
        cg.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(maxR * 0.42), options: [])
      }
    }
  }
}

/// Device tilt for the parallax effect.
final class MotionParallax: ObservableObject {
  @Published var tilt: CGSize = .zero
  private let manager = CMMotionManager()
  private var running = false

  func start() {
    guard !running, manager.isDeviceMotionAvailable else { return }
    running = true
    manager.deviceMotionUpdateInterval = 1.0 / 30
    manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
      guard let self = self, let m = motion else { return }
      let x = max(-1, min(1, m.attitude.roll / 0.6))
      let y = max(-1, min(1, (m.attitude.pitch - 0.7) / 0.6))
      let next = CGSize(width: self.tilt.width * 0.8 + x * 0.2, height: self.tilt.height * 0.8 + y * 0.2)
      if abs(next.width - self.tilt.width) > 0.002 || abs(next.height - self.tilt.height) > 0.002 {
        self.tilt = next
      }
    }
  }

  func stop() {
    guard running else { return }
    running = false
    manager.stopDeviceMotionUpdates()
    tilt = .zero
  }
}

/// Background stars in three depth layers.
struct StarField {
  struct Star {
    var x: Double
    var y: Double
    var size: Double
    var brightness: Double
    var layer: Int
    var phase: Double
    var speed: Double
  }

  static let stars: [Star] = {
    var rng = SeededRandom(seed: 0xC0FFEE)
    return (0..<180).map { i in
      Star(x: rng.next(), y: rng.next(), size: 0.6 + rng.next() * (i % 3 == 2 ? 1.8 : 1.0), brightness: 0.25 + rng.next() * 0.6,
           layer: i % 3, phase: rng.next() * 2 * .pi, speed: 0.6 + rng.next() * 1.8)
    }
  }()
}

struct GalaxyView: View {
  var nodes: [AppModel.CountryNode]
  var selectedCC: String?
  var connectedCC: String?
  var status: NEVPNStatus
  var busy: Bool
  var showPing: Bool
  var animate: Bool
  var parallaxEnabled: Bool
  var onCore: () -> Void
  var onCountry: (AppModel.CountryNode) -> Void
  var onCountryMenu: (AppModel.CountryNode) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var motion = MotionParallax()
  @State private var texture: UIImage?
  @State private var zoom: CGFloat = 1
  @GestureState private var pinch: CGFloat = 1
  @State private var pan: CGSize = .zero
  @GestureState private var drag: CGSize = .zero
  @State private var rotation: Angle = .zero
  @GestureState private var twist: Angle = .zero
  @State private var startDate = Date()

  private let tilt: CGFloat = 0.6

  private var moving: Bool { animate && !reduceMotion }

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      let radius = min(size.width, size.height * 1.25) * 0.47
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving && status != .connecting)) { context in
        let t = context.date.timeIntervalSince(startDate)
        let spin = moving ? Angle(degrees: t * 2.2) : .zero
        let angle = rotation + twist + spin
        let scale = clampZoom(zoom * pinch)
        let offset = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
        let tiltShift = parallaxEnabled && !reduceMotion ? motion.tilt : .zero
        ZStack {
          stars(size: size, time: t, offset: offset, tilt: tiltShift)
          galaxy(radius: radius, angle: angle, scale: scale, offset: offset)
          coreButton(radius: radius, scale: scale, offset: offset, time: t)
          stems(size: size, radius: radius, angle: angle, scale: scale, offset: offset, tilt: tiltShift)
          ForEach(placed(radius: radius, angle: angle, scale: scale, offset: offset, tilt: tiltShift, size: size)) { p in
            chip(p)
              .position(p.chipPoint)
              .zIndex(p.depth)
          }
        }
        .frame(width: size.width, height: size.height)
      }
      .contentShape(Rectangle())
      .gesture(dragGesture.simultaneously(with: pinchGesture.simultaneously(with: rotateGesture)))
      .onTapGesture(count: 2) {
        Haptics.tap()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
          zoom = 1
          pan = .zero
          rotation = .zero
        }
      }
      .task {
        guard texture == nil else { return }
        let pixels = Int(min(1400, max(700, radius * 2 * UIScreen.main.scale)))
        texture = await Task.detached(priority: .userInitiated) { GalaxyTexture.render(pixels: pixels) }.value
      }
    }
    .onAppear { if parallaxEnabled && !reduceMotion { motion.start() } }
    .onDisappear { motion.stop() }
    .onChange(of: parallaxEnabled) { on in
      if on && !reduceMotion { motion.start() } else { motion.stop() }
    }
  }

  // MARK: Gestures

  private func clampZoom(_ z: CGFloat) -> CGFloat { min(3.2, max(0.55, z)) }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 6)
      .updating($drag) { value, state, _ in state = value.translation }
      .onEnded { value in
        pan.width += value.translation.width
        pan.height += value.translation.height
        let limit: CGFloat = 400
        pan.width = max(-limit, min(limit, pan.width))
        pan.height = max(-limit, min(limit, pan.height))
      }
  }

  private var pinchGesture: some Gesture {
    MagnificationGesture()
      .updating($pinch) { value, state, _ in state = value }
      .onEnded { value in zoom = clampZoom(zoom * value) }
  }

  private var rotateGesture: some Gesture {
    RotationGesture()
      .updating($twist) { value, state, _ in state = value }
      .onEnded { value in rotation += value }
  }

  // MARK: Layers

  private func stars(size: CGSize, time: Double, offset: CGSize, tilt: CGSize) -> some View {
    Canvas { ctx, canvasSize in
      for s in StarField.stars {
        let depth = Double(s.layer + 1) / 3
        let dx = Double(offset.width) * 0.12 * depth + Double(tilt.width) * 10 * depth
        let dy = Double(offset.height) * 0.12 * depth + Double(tilt.height) * 10 * depth
        var x = (s.x * Double(canvasSize.width) + dx).truncatingRemainder(dividingBy: Double(canvasSize.width))
        var y = (s.y * Double(canvasSize.height) + dy).truncatingRemainder(dividingBy: Double(canvasSize.height))
        if x < 0 { x += Double(canvasSize.width) }
        if y < 0 { y += Double(canvasSize.height) }
        let twinkle = moving ? 0.65 + 0.35 * sin(time * s.speed + s.phase) : 1
        let alpha = s.brightness * twinkle
        let rect = CGRect(x: x - s.size / 2, y: y - s.size / 2, width: s.size, height: s.size)
        ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
      }
    }
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func galaxy(radius: CGFloat, angle: Angle, scale: CGFloat, offset: CGSize) -> some View {
    if let texture = texture {
      Image(uiImage: texture)
        .resizable()
        .interpolation(.medium)
        .frame(width: radius * 2.15, height: radius * 2.15)
        .rotationEffect(angle)
        .scaleEffect(x: 1, y: tilt)
        .scaleEffect(scale)
        .offset(offset)
        .allowsHitTesting(false)
        .transition(.opacity)
    } else {
      Circle()
        .fill(RadialGradient(colors: [Theme.glowWarm.opacity(0.5), Theme.glow.opacity(0.15), .clear], center: .center, startRadius: 0, endRadius: radius))
        .frame(width: radius * 2, height: radius * 2)
        .scaleEffect(x: 1, y: tilt)
        .offset(offset)
        .allowsHitTesting(false)
    }
  }

  private var coreColor: Color {
    switch status {
    case .connected, .reasserting: return Theme.good
    case .connecting, .disconnecting: return Theme.glowCool
    default: return Theme.glowWarm
    }
  }

  private func coreButton(radius: CGFloat, scale: CGFloat, offset: CGSize, time: Double) -> some View {
    let pulse: CGFloat = status == .connecting || status == .disconnecting ? CGFloat(0.85 + 0.15 * sin(time * 5)) : 1
    let d = radius * 0.30 * max(0.7, min(1.6, scale))
    return Button(action: onCore) {
      ZStack {
        Circle()
          .fill(RadialGradient(colors: [coreColor.opacity(0.55), coreColor.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: d * 0.9))
          .frame(width: d * 1.8, height: d * 1.8)
          .scaleEffect(pulse)
        Circle()
          .fill(RadialGradient(colors: [.white, coreColor.opacity(0.9), coreColor.opacity(0.2)], center: .center, startRadius: 0, endRadius: d * 0.32))
          .frame(width: d * 0.62, height: d * 0.62)
          .shadow(color: coreColor.opacity(0.9), radius: 18)
        Image(systemName: "power")
          .font(.system(size: d * 0.2, weight: .bold))
          .foregroundStyle(Color.black.opacity(0.55))
      }
      .frame(width: d * 1.2, height: d * 1.2)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(busy && status != .connecting)
    .offset(offset)
    .accessibilityLabel(status == .connected ? L("home.a11y.disconnect") : L("home.a11y.connect"))
  }

  // MARK: Countries

  struct Placed: Identifiable {
    var node: AppModel.CountryNode
    var anchor: CGPoint
    var chipPoint: CGPoint
    var depth: Double
    var scale: CGFloat
    var id: String { node.id }
  }

  /// Positions on the disc, ordered by longitude so neighbours stay neighbours.
  private func discPositions() -> [(AppModel.CountryNode, Double, Double)] {
    let sorted = nodes.sorted { a, b in
      if a.cc.isEmpty != b.cc.isEmpty { return !a.cc.isEmpty }
      return a.lon < b.lon
    }
    let n = max(sorted.count, 1)
    let rings: [Double] = n <= 3 ? [0.72] : (n <= 8 ? [0.62, 0.86] : [0.5, 0.72, 0.92])
    let base = sorted.first.map { ($0.lon + 180) / 360 * 2 * .pi } ?? 0
    return sorted.enumerated().map { i, node in
      let theta = base + Double(i) * 2 * .pi / Double(n) - .pi / 2
      return (node, theta, rings[i % rings.count])
    }
  }

  private func placed(radius: CGFloat, angle: Angle, scale: CGFloat, offset: CGSize, tilt tiltShift: CGSize, size: CGSize) -> [Placed] {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    return discPositions().map { node, theta, ring in
      let a = theta + angle.radians
      let x = cos(a) * ring * Double(radius) * Double(scale)
      let y = sin(a) * ring * Double(radius) * Double(scale) * Double(tilt)
      let depth = (sin(a) + 1) / 2
      let anchor = CGPoint(x: center.x + CGFloat(x) + offset.width, y: center.y + CGFloat(y) + offset.height)
      let chipScale = CGFloat(0.8 + 0.3 * depth) * min(1.25, max(0.85, sqrt(scale)))
      let lift = 30 * chipScale
      let parallax = CGSize(width: tiltShift.width * CGFloat(6 + 12 * depth), height: tiltShift.height * CGFloat(6 + 12 * depth))
      let chip = CGPoint(x: anchor.x + parallax.width, y: anchor.y - lift + parallax.height)
      return Placed(node: node, anchor: anchor, chipPoint: chip, depth: depth, scale: chipScale)
    }
  }

  private func stems(size: CGSize, radius: CGFloat, angle: Angle, scale: CGFloat, offset: CGSize, tilt: CGSize) -> some View {
    let items = placed(radius: radius, angle: angle, scale: scale, offset: offset, tilt: tilt, size: size)
    let highlight = connectedCC ?? selectedCC
    return Canvas { ctx, _ in
      for p in items {
        let active = p.node.cc == highlight
        let color = active ? coreColor : Theme.glowCool
        var line = Path()
        line.move(to: p.anchor)
        line.addLine(to: CGPoint(x: p.chipPoint.x, y: p.chipPoint.y + 12 * p.scale))
        ctx.stroke(line, with: .color(color.opacity(0.25 + 0.35 * p.depth)), lineWidth: 1)
        let dot = CGRect(x: p.anchor.x - 3, y: p.anchor.y - 3, width: 6, height: 6)
        ctx.fill(Path(ellipseIn: dot.insetBy(dx: -4, dy: -4)), with: .color(color.opacity(0.18)))
        ctx.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.9)))
      }
    }
    .allowsHitTesting(false)
  }

  private func chip(_ p: Placed) -> some View {
    let node = p.node
    let active = node.cc == (connectedCC ?? selectedCC)
    let connected = node.cc == connectedCC && (status == .connected || status == .reasserting)
    let accent = connected ? Theme.good : (active ? Theme.glow : Color.white.opacity(0.18))
    return Button { onCountry(node) } label: {
      HStack(spacing: 6) {
        Text(Format.flag(node.cc))
          .font(.system(size: 17))
        VStack(alignment: .leading, spacing: 1) {
          Text(node.cc.isEmpty ? "??" : node.cc)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
          if showPing {
            HStack(spacing: 4) {
              if node.testing && node.best == nil {
                Text("…").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
              } else {
                Text(node.best.map { Format.ms($0) } ?? "—")
                  .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                  .foregroundStyle(Theme.latencyColor(node.best))
              }
              SignalBars(bars: Theme.bars(node.best), color: Theme.latencyColor(node.best))
            }
          }
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(accent, lineWidth: active || connected ? 1.4 : 1))
      .shadow(color: active || connected ? accent.opacity(0.7) : .clear, radius: 10)
    }
    .buttonStyle(.plain)
    .scaleEffect(p.scale)
    .opacity(0.55 + 0.45 * p.depth)
    .contextMenu {
      Button { onCountry(node) } label: { Label(L("galaxy.connect_fastest"), systemImage: "bolt.fill") }
      Button { onCountryMenu(node) } label: { Label(L("galaxy.show_servers"), systemImage: "list.bullet") }
    }
    .accessibilityLabel("\(Format.country(node.cc)), \(node.best.map { Format.ms($0) } ?? "")")
  }
}
