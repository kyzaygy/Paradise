import CoreMotion
import SwiftUI
import UIKit

/// Deterministic random numbers so the space looks the same on every launch.
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

  mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

/// Places the country capsules on orbits around the core, west to east clockwise from the left.
/// When they don't all fit, the slowest countries are left out (the list still has them).
enum OrbitLayout {
  private static let rings: [CGFloat] = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.42]
  /// Angle offsets tried around the preferred angle: 0, ±0.05, ±0.1 … ±0.6 radians.
  private static let offsets: [Double] = {
    var values: [Double] = [0]
    for step in 1...12 {
      let offset = Double(step) * 0.05
      values.append(offset)
      values.append(-offset)
    }
    return values
  }()

  /// Centers of the capsules inside a box of `size`, by country id.
  static func place(_ nodes: [AppModel.CountryNode], in size: CGSize, chip: CGSize) -> [String: CGPoint] {
    guard size.width > chip.width * 1.5, size.height > chip.height * 1.5 else { return [:] }
    var pool = nodes
    while !pool.isEmpty {
      if let spots = attempt(pool, size: size, chip: chip) { return spots }
      guard let slowest = pool.indices.max(by: { (pool[$0].best ?? Int64.max) < (pool[$1].best ?? Int64.max) }) else { break }
      pool.remove(at: slowest)
    }
    return [:]
  }

  private static func attempt(_ nodes: [AppModel.CountryNode], size: CGSize, chip: CGSize) -> [String: CGPoint]? {
    let ordered = nodes.sorted { $0.lon == $1.lon ? $0.id < $1.id : $0.lon < $1.lon }
    let cx = size.width / 2
    let cy = size.height / 2
    let halfW = chip.width / 2
    let halfH = chip.height / 2
    let rx = cx - halfW - 4
    let ry = cy - halfH - 4
    let minDX = chip.width + 4
    let minDY = chip.height + 4
    let coreDX = halfW + 18
    let coreDY = halfH + 18
    var spots: [String: CGPoint] = [:]
    var taken: [CGPoint] = []
    for (i, node) in ordered.enumerated() {
      let preferred = -Double.pi + Double(i) * 2 * Double.pi / Double(ordered.count)
      let order = i % 2 == 0 ? rings : Array(rings.dropFirst()) + [rings[0]]
      var found: CGPoint?
      search: for k in order {
        for offset in offsets {
          let a = preferred + offset
          let p = CGPoint(x: cx + rx * k * CGFloat(cos(a)), y: cy + ry * k * CGFloat(sin(a)))
          let insideX = p.x >= halfW && p.x <= size.width - halfW
          let insideY = p.y >= halfH && p.y <= size.height - halfH
          let onCore = abs(p.x - cx) < coreDX && abs(p.y - cy) < coreDY
          let clash = taken.contains { abs($0.x - p.x) < minDX && abs($0.y - p.y) < minDY }
          if insideX && insideY && !onCore && !clash {
            found = p
            break search
          }
        }
      }
      guard let spot = found else { return nil }
      taken.append(spot)
      spots[node.id] = spot
    }
    return spots
  }
}

/// Pre-rendered layers of the space: the star field and two discs of the galaxy.
struct SpaceTextures {
  let stars: UIImage
  let far: UIImage
  let near: UIImage
}

/// Draws the still parts of the space once per screen size and theme (off the main thread).
enum SpaceRenderer {
  static func render(size: CGSize, core: CGPoint, radius: CGFloat, ink: SpaceInk, scale: CGFloat) -> SpaceTextures {
    SpaceTextures(
      stars: stars(size: size, core: core, ink: ink, scale: scale),
      far: galaxy(radius: radius, ink: ink, scale: scale, seed: 0x6A1A_F0E1, count: 190, twist: 3.4, reach: 0.24, light: 0.75),
      near: galaxy(radius: radius * 0.6, ink: ink, scale: scale, seed: 0x6A1A_0E42, count: 280, twist: 2.6, reach: 0.15, light: 1))
  }

  private static func renderer(_ size: CGSize, scale: CGFloat) -> UIGraphicsImageRenderer {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format)
  }

  private static func cloud(_ cg: CGContext, at center: CGPoint, radius: CGFloat, color: UIColor, alpha: CGFloat) {
    let colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(alpha * 0.4).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) else { return }
    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
  }

  /// Nebula clouds and a field of small stars over the whole screen.
  static func stars(size: CGSize, core: CGPoint, ink: SpaceInk, scale: CGFloat) -> UIImage {
    renderer(size, scale: scale).image { context in
      let cg = context.cgContext
      var rng = SeededRandom(seed: 0x57A2_5EED)
      let dim: CGFloat = ink.isLight ? 0.55 : 1
      cloud(cg, at: CGPoint(x: core.x - size.width * 0.3, y: core.y - size.height * 0.16), radius: size.width * 0.62, color: ink.nebula, alpha: 0.14 * dim)
      cloud(cg, at: CGPoint(x: core.x + size.width * 0.34, y: core.y + size.height * 0.1), radius: size.width * 0.55, color: ink.nebula2, alpha: 0.1 * dim)
      cloud(cg, at: core, radius: size.width * 0.75, color: ink.nebula, alpha: 0.08 * dim)
      let count = Int(size.width * size.height / 240)
      for _ in 0..<count {
        let x = CGFloat(rng.range(0, Double(size.width)))
        let y = CGFloat(rng.range(0, Double(size.height)))
        let bright = rng.next() < 0.05
        let d = CGFloat(bright ? rng.range(1.3, 2.1) : rng.range(0.5, 1.2))
        let a = CGFloat(bright ? rng.range(0.5, 0.9) : rng.range(0.1, 0.48)) * dim
        cg.setFillColor(ink.ink.withAlphaComponent(a).cgColor)
        cg.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
      }
    }
  }

  /// A disc of the galaxy: three spiral arms of points joined to their nearest neighbours, brighter toward the centre.
  static func galaxy(radius: CGFloat, ink: SpaceInk, scale: CGFloat, seed: UInt64, count: Int, twist: Double, reach: Double, light: Double) -> UIImage {
    let side = radius * 2
    return renderer(CGSize(width: side, height: side), scale: scale).image { context in
      let cg = context.cgContext
      var rng = SeededRandom(seed: seed)
      let center = CGPoint(x: radius, y: radius)
      let r0 = Double(radius)
      let dim = (ink.isLight ? 0.7 : 1) * light
      var points: [CGPoint] = []
      var weight: [Double] = []
      points.reserveCapacity(count)
      weight.reserveCapacity(count)
      for i in 0..<count {
        let t = pow(rng.next(), 0.8)
        let spread = rng.range(-0.04, 0.04)
        let r = r0 * (0.05 + 0.95 * t + spread)
        let a: Double
        if rng.next() < 0.8 {
          let arm = Double(i % 3) * 2 * Double.pi / 3
          let jitter = rng.range(-0.34, 0.34) * (1 - 0.45 * t)
          a = arm + t * twist + jitter
        } else {
          a = rng.range(0, 2 * Double.pi)
        }
        points.append(CGPoint(x: center.x + CGFloat(cos(a) * r), y: center.y + CGFloat(sin(a) * r)))
        weight.append(1 - t)
      }
      // soft haze along the arms
      for (i, p) in points.enumerated() where i % 3 == 0 {
        cloud(cg, at: p, radius: radius * 0.09, color: ink.ink, alpha: CGFloat(0.018 * dim * (0.4 + weight[i])))
      }
      // links to the three nearest neighbours
      let maxLink = CGFloat(reach) * radius
      cg.setLineCap(.round)
      cg.setLineWidth(0.55)
      for i in points.indices {
        var nearest: [(CGFloat, Int)] = []
        for j in points.indices where j != i {
          let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
          guard d < maxLink else { continue }
          if nearest.count < 3 {
            nearest.append((d, j))
            nearest.sort { $0.0 < $1.0 }
          } else if d < nearest[2].0 {
            nearest[2] = (d, j)
            nearest.sort { $0.0 < $1.0 }
          }
        }
        for (_, j) in nearest {
          let w = (weight[i] + weight[j]) / 2
          let alpha = (0.03 + 0.2 * pow(w, 1.5)) * dim
          cg.setStrokeColor(ink.ink.withAlphaComponent(CGFloat(alpha)).cgColor)
          cg.move(to: points[i])
          cg.addLine(to: points[j])
          cg.strokePath()
        }
      }
      // the points, a few of them with a glow
      for (i, p) in points.enumerated() {
        let bright = rng.next() < 0.12
        let d = CGFloat(bright ? rng.range(1.5, 2.6) : rng.range(0.6, 1.4))
        let alpha = min(1, (0.22 + 0.68 * weight[i]) * dim)
        if bright { cloud(cg, at: p, radius: d * 3.4, color: ink.glow, alpha: CGFloat(alpha * 0.45)) }
        cg.setFillColor(ink.ink.withAlphaComponent(CGFloat(alpha)).cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
      }
    }
  }
}

/// Device tilt for a subtle parallax. Not observed: the animation reads it on every frame.
final class MotionParallax {
  private(set) var tilt: CGSize = .zero
  private var manager: CMMotionManager?

  func start() {
    guard manager == nil else { return }
    let manager = CMMotionManager()
    guard manager.isDeviceMotionAvailable else { return }
    self.manager = manager
    manager.deviceMotionUpdateInterval = 1.0 / 30
    manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
      guard let self = self, let attitude = motion?.attitude else { return }
      let x = CGFloat(max(-1, min(1, attitude.roll / 0.6)))
      let y = CGFloat(max(-1, min(1, (attitude.pitch - 0.7) / 0.6)))
      self.tilt = CGSize(width: self.tilt.width * 0.85 + x * 0.15, height: self.tilt.height * 0.85 + y * 0.15)
    }
  }

  func stop() {
    manager?.stopDeviceMotionUpdates()
    manager = nil
    tilt = .zero
  }
}

/// The animated space behind the home screen: a rotating galaxy, comets on orbits, twinkling stars,
/// a breathing core and arcs to the countries, with a data flow to the connected one. On appearing,
/// the view flies out of the core. Country capsules connect on tap and open a menu on a long press.
struct SpaceView: View {
  let size: CGSize
  /// Where the capsules go (screen coordinates); the core is in its center.
  let mapRect: CGRect
  let nodes: [AppModel.CountryNode]
  let highlighted: String?
  let connected: Bool
  let moving: Bool
  /// False while the panel covers the map.
  let interactive: Bool
  let parallax: Bool
  let m: HomeMetrics
  var onNode: (AppModel.CountryNode) -> Void
  var onNodeList: (AppModel.CountryNode) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.displayScale) private var displayScale
  @State private var motion = MotionParallax()
  @State private var textures: SpaceTextures?
  @State private var start = Date()
  @State private var chipsShown = false

  init(size: CGSize, mapRect: CGRect, nodes: [AppModel.CountryNode], highlighted: String?, connected: Bool, moving: Bool,
       interactive: Bool, parallax: Bool, m: HomeMetrics,
       onNode: @escaping (AppModel.CountryNode) -> Void, onNodeList: @escaping (AppModel.CountryNode) -> Void) {
    self.size = size
    self.mapRect = mapRect
    self.nodes = nodes
    self.highlighted = highlighted
    self.connected = connected
    self.moving = moving
    self.interactive = interactive
    self.parallax = parallax
    self.m = m
    self.onNode = onNode
    self.onNodeList = onNodeList
  }

  private var animated: Bool { moving && !reduceMotion }
  private var core: CGPoint { CGPoint(x: mapRect.midX, y: mapRect.midY) }
  /// Radius of the galaxy disc.
  private var radius: CGFloat { min(size.width * 0.64, m(290)) }

  var body: some View {
    let p = Palette.current
    let spots = OrbitLayout.place(nodes, in: mapRect.size, chip: CGSize(width: m(84), height: m(36)))
    let origin = mapRect.origin
    let anchors = spots.mapValues { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
    let shown = nodes.filter { anchors[$0.id] != nil }
    let arcs: [SpaceLayers.Arc] = shown.compactMap { node in anchors[node.id].map { SpaceLayers.Arc(cc: node.cc, point: $0) } }
    let core = self.core
    let radius = self.radius
    let animated = self.animated
    let motion = self.motion
    let highlighted = self.highlighted
    let connected = self.connected
    let startDate = self.start
    let currentTextures = self.textures
    let size = self.size
    let key = "\(Int(size.width))x\(Int(size.height))@\(Int(core.y))|\(AppTheme.current.rawValue)"
    return ZStack(alignment: .topLeading) {
      LinearGradient(colors: [p.spaceTop, p.spaceBottom], startPoint: .top, endPoint: .bottom)
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
        let t = animated ? context.date.timeIntervalSince(startDate) : 9
        SpaceLayers(textures: currentTextures, size: size, core: core, radius: radius, t: t,
                    intro: animated ? Self.ease(min(1, max(0, t / 1.8))) : 1,
                    tilt: parallax && animated ? motion.tilt : .zero, arcs: arcs, highlighted: highlighted, connected: connected)
      }
      ZStack(alignment: .topLeading) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
          if let spot = anchors[node.id] {
            NodeChip(node: node, active: node.cc == highlighted, connected: connected && node.cc == highlighted, m: m,
                     onTap: { onNode(node) }, onList: { onNodeList(node) })
              .scaleEffect(chipsShown ? 1 : 0.55)
              .opacity(chipsShown ? 1 : 0)
              .animation(.spring(response: 0.55, dampingFraction: 0.78).delay(animated ? 0.75 + Double(index) * 0.05 : 0), value: chipsShown)
              .position(spot)
          }
        }
      }
      .frame(width: size.width, height: size.height)
      .allowsHitTesting(interactive)
      .accessibilityHidden(!interactive)
    }
    .frame(width: size.width, height: size.height)
    .clipped()
    .task(id: key) {
      let ink = p.spaceInk
      let scale = min(displayScale, 2)
      let rendered = await Task.detached(priority: .userInitiated) {
        SpaceRenderer.render(size: size, core: core, radius: radius, ink: ink, scale: scale)
      }.value
      self.textures = rendered
    }
    .onAppear {
      start = Date()
      chipsShown = true
      if parallax && !reduceMotion { motion.start() }
    }
    .onDisappear { motion.stop() }
    .onChange(of: parallax) { on in
      if on && !reduceMotion { motion.start() } else { motion.stop() }
    }
  }

  private static func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

/// One frame of the space: the textures turned and zoomed for time `t`, and everything that moves drawn on top.
private struct SpaceLayers: View {
  struct Arc {
    let cc: String
    let point: CGPoint
  }

  /// An ellipse around the core, as a share of the galaxy radius, tilted a little.
  struct Orbit {
    let size: CGFloat
    let tilt: Double
    let alpha: Double
  }

  struct Comet {
    let orbit: Int
    /// Radians per second; negative runs the other way.
    let speed: Double
    let phase: Double
  }

  static let squash: CGFloat = 0.62
  static let orbits: [Orbit] = [
    Orbit(size: 0.48, tilt: -0.12, alpha: 0.09), Orbit(size: 0.66, tilt: 0.06, alpha: 0.08), Orbit(size: 0.84, tilt: -0.05, alpha: 0.07),
    Orbit(size: 1.02, tilt: 0.15, alpha: 0.06), Orbit(size: 1.22, tilt: -0.08, alpha: 0.05),
  ]
  static let comets: [Comet] = [
    Comet(orbit: 0, speed: 0.55, phase: 0.3), Comet(orbit: 1, speed: -0.38, phase: 2.1), Comet(orbit: 1, speed: -0.38, phase: 5.0),
    Comet(orbit: 2, speed: 0.3, phase: 1.2), Comet(orbit: 2, speed: 0.3, phase: 4.4), Comet(orbit: 3, speed: -0.24, phase: 3.9),
    Comet(orbit: 3, speed: -0.24, phase: 0.6), Comet(orbit: 4, speed: 0.18, phase: 2.8),
  ]

  let textures: SpaceTextures?
  let size: CGSize
  let core: CGPoint
  let radius: CGFloat
  let t: Double
  let intro: Double
  let tilt: CGSize
  let arcs: [Arc]
  let highlighted: String?
  let connected: Bool

  /// The fly-out at the start: everything begins zoomed into the core.
  private var zoom: CGFloat { CGFloat(1 + (1 - intro) * 1.5) }

  var body: some View {
    let p = Palette.current
    let blend: BlendMode = p.isLight ? .normal : .plusLighter
    return ZStack(alignment: .topLeading) {
      if let textures = textures {
        Image(uiImage: textures.stars)
          .resizable()
          .frame(width: size.width, height: size.height)
          .offset(x: tilt.width * 3, y: tilt.height * 3)
          .opacity(min(1, intro * 1.6))
        disc(textures.far, side: radius * 2, degrees: t * 1.4, opacity: min(1, intro * 1.4) * 0.95, shift: 6)
          .blendMode(blend)
        disc(textures.near, side: radius * 1.2, degrees: t * 3.2, opacity: min(1, intro * 1.4), shift: 9)
          .blendMode(blend)
      }
      Canvas { context, _ in
        draw(&context, palette: p)
      }
      .blendMode(blend)
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func disc(_ image: UIImage, side: CGFloat, degrees: Double, opacity: Double, shift: CGFloat) -> some View {
    Image(uiImage: image)
      .resizable()
      .frame(width: side, height: side)
      .rotationEffect(.degrees(degrees))
      .scaleEffect(x: zoom, y: zoom * Self.squash)
      .opacity(opacity)
      .position(x: core.x + tilt.width * shift, y: core.y + tilt.height * shift)
  }

  private func draw(_ context: inout GraphicsContext, palette p: Palette) {
    let ink = Color(uiColor: p.ink)
    let glow = Color(uiColor: p.glow)
    for orbit in Self.orbits {
      context.stroke(orbitPath(orbit), with: .color(ink.opacity(orbit.alpha * intro)), lineWidth: 0.7)
    }
    for comet in Self.comets {
      drawComet(&context, comet, color: glow)
    }
    drawArcs(&context, ink: ink, flow: p.accent)
    drawTwinkles(&context, ink: ink)
    drawCore(&context, glow: glow, light: p.isLight)
  }

  private func orbitPoint(_ orbit: Orbit, _ angle: Double) -> CGPoint {
    let a = Double(radius * orbit.size * zoom)
    let b = a * Double(Self.squash)
    let x = a * cos(angle)
    let y = b * sin(angle)
    let c = cos(orbit.tilt)
    let s = sin(orbit.tilt)
    return CGPoint(x: core.x + CGFloat(x * c - y * s), y: core.y + CGFloat(x * s + y * c))
  }

  private func orbitPath(_ orbit: Orbit) -> Path {
    var path = Path()
    let steps = 90
    for k in 0...steps {
      let point = orbitPoint(orbit, Double(k) / Double(steps) * 2 * Double.pi)
      if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
  }

  private func drawComet(_ context: inout GraphicsContext, _ comet: Comet, color: Color) {
    let orbit = Self.orbits[comet.orbit]
    let head = comet.phase + comet.speed * t
    let back: Double = comet.speed >= 0 ? -0.03 : 0.03
    var previous = orbitPoint(orbit, head)
    let segments = 14
    for k in 1...segments {
      let point = orbitPoint(orbit, head + back * Double(k))
      var segment = Path()
      segment.move(to: previous)
      segment.addLine(to: point)
      let f = 1 - Double(k) / Double(segments)
      context.stroke(segment, with: .color(color.opacity(0.6 * f * f * intro)), style: StrokeStyle(lineWidth: CGFloat(0.4 + 1.6 * f), lineCap: .round))
      previous = point
    }
    let h = orbitPoint(orbit, head)
    let r: CGFloat = 7
    context.fill(Path(ellipseIn: CGRect(x: h.x - r, y: h.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [color.opacity(0.8 * intro), color.opacity(0)]), center: h, startRadius: 0, endRadius: r))
    context.fill(Path(ellipseIn: CGRect(x: h.x - 1.4, y: h.y - 1.4, width: 2.8, height: 2.8)), with: .color(color.opacity(intro)))
  }

  private func drawArcs(_ context: inout GraphicsContext, ink: Color, flow: Color) {
    for (i, arc) in arcs.enumerated() {
      let a = arc.point
      let active = arc.cc == highlighted
      let mid = CGPoint(x: (a.x + core.x) / 2, y: (a.y + core.y) / 2)
      let dx = core.x - a.x
      let dy = core.y - a.y
      let bend: CGFloat = i % 2 == 0 ? 0.2 : -0.2
      let control = CGPoint(x: mid.x - dy * bend, y: mid.y + dx * bend)
      var path = Path()
      path.move(to: a)
      path.addQuadCurve(to: core, control: control)
      let shimmer = 0.8 + 0.2 * sin(t * 1.3 + Double(i) * 1.7)
      let base = (active ? 0.85 : 0.3) * shimmer * intro
      context.stroke(path, with: .color(ink.opacity((active ? 0.1 : 0.04) * intro)), lineWidth: active ? 4 : 3)
      let fade = Gradient(colors: [ink.opacity(base), ink.opacity(base * 0.35), ink.opacity(0.02)])
      context.stroke(path, with: .linearGradient(fade, startPoint: a, endPoint: core), lineWidth: active ? 1.5 : 0.9)
      guard active && connected else { continue }
      // traffic leaves the core for the connected country
      for j in 0..<3 {
        let s = CGFloat((t * 0.45 + Double(j) / 3).truncatingRemainder(dividingBy: 1))
        let point = quad(core, control, a, s)
        let r: CGFloat = 5
        context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [flow.opacity(0.9 * intro), flow.opacity(0)]), center: point, startRadius: 0, endRadius: r))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 1.3, y: point.y - 1.3, width: 2.6, height: 2.6)), with: .color(flow.opacity(intro)))
      }
    }
  }

  /// A point of the quadratic curve p0 → p1 bent toward c.
  private func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ s: CGFloat) -> CGPoint {
    let u = 1 - s
    let w0 = u * u
    let w1 = 2 * u * s
    let w2 = s * s
    let x = w0 * p0.x + w1 * c.x + w2 * p1.x
    let y = w0 * p0.y + w1 * c.y + w2 * p1.y
    return CGPoint(x: x, y: y)
  }

  private func drawTwinkles(_ context: inout GraphicsContext, ink: Color) {
    var rng = SeededRandom(seed: 0x71E2A)
    for _ in 0..<34 {
      let x = CGFloat(rng.next()) * size.width
      let y = CGFloat(rng.next()) * size.height
      let speed = rng.range(0.6, 1.8)
      let phase = rng.range(0, 6.28)
      let wave = max(0, sin(t * speed + phase))
      let alpha = (0.15 + 0.85 * pow(wave, 6)) * intro
      let r = CGFloat(0.7 + 1.1 * wave)
      context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(alpha)))
      guard wave > 0.92 else { continue }
      var flare = Path()
      flare.move(to: CGPoint(x: x - 5, y: y))
      flare.addLine(to: CGPoint(x: x + 5, y: y))
      flare.move(to: CGPoint(x: x, y: y - 5))
      flare.addLine(to: CGPoint(x: x, y: y + 5))
      context.stroke(flare, with: .color(ink.opacity(alpha * 0.5)), lineWidth: 0.6)
    }
  }

  private func drawCore(_ context: inout GraphicsContext, glow: Color, light: Bool) {
    let breathe = CGFloat(1 + 0.04 * sin(t * 1.1))
    let r = radius * 0.55 * breathe * CGFloat(1 + (1 - intro) * 2.2)
    let k = light ? 0.35 : 1.0
    let stops: [Gradient.Stop] = [
      .init(color: glow.opacity(k), location: 0),
      .init(color: glow.opacity(0.85 * k), location: 0.035),
      .init(color: glow.opacity(0.45 * k), location: 0.09),
      .init(color: glow.opacity(0.2 * k), location: 0.18),
      .init(color: glow.opacity(0.08 * k), location: 0.34),
      .init(color: glow.opacity(0.025 * k), location: 0.6),
      .init(color: glow.opacity(0), location: 1),
    ]
    context.fill(Path(ellipseIn: CGRect(x: core.x - r, y: core.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(stops: stops), center: core, startRadius: 0, endRadius: r))
  }
}

/// A country on the map: flag, code and the best ping of its servers.
struct NodeChip: View {
  let node: AppModel.CountryNode
  let active: Bool
  let connected: Bool
  let m: HomeMetrics
  var onTap: () -> Void
  var onList: () -> Void

  var body: some View {
    let p = Palette.current
    let shape = RoundedRectangle(cornerRadius: m(12), style: .continuous)
    return Button(action: onTap) {
      HStack(spacing: m(7)) {
        RoundFlag(cc: node.cc, diameter: m(20))
        VStack(alignment: .leading, spacing: m(1)) {
          Text(node.cc.isEmpty ? "??" : node.cc)
            .font(m.font(13, .semibold))
            .foregroundStyle(p.text)
          Text(pingText)
            .font(m.font(10.5, .medium).monospacedDigit())
            .foregroundStyle(node.best.map { p.latencyColor($0) } ?? p.text3)
        }
      }
      .padding(.leading, m(8))
      .padding(.trailing, m(11))
      .frame(height: m(36))
      .glass(shape, tint: active ? p.selected.opacity(0.75) : p.glass, stroke: active ? p.strokeStrong : p.stroke)
      .shadow(color: connected ? p.accent.opacity(0.5) : .clear, radius: m(10))
      .scaleEffect(active ? 1.06 : 1)
      .animation(.spring(response: 0.35, dampingFraction: 0.7), value: active)
      .contentShape(shape)
    }
    .buttonStyle(PressableStyle())
    .contextMenu {
      Button(action: onTap) { Label(L("galaxy.connect_fastest"), systemImage: "bolt") }
      Button(action: onList) { Label(L("galaxy.show_servers"), systemImage: "list.bullet") }
    }
    .accessibilityLabel("\(Format.country(node.cc)), \(pingText)")
    .accessibilityAddTraits(active ? .isSelected : [])
    .accessibilityIdentifier("node.\(node.id)")
  }

  private var pingText: String {
    if let best = node.best { return Format.ms(best) }
    return node.testing ? "…" : "— ms"
  }
}
