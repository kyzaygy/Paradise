import CoreMotion
import NetworkExtension
import SwiftUI
import UIKit

/// Deterministic random numbers so the map texture is the same on every launch.
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

/// Where countries sit on the map. The eleven slots of the mock are kept exactly; other countries
/// take spare slots between them. Coordinates are reference pixels inside the 640 × 495 map.
enum MapLayout {
  static let slots: [String: CGPoint] = [
    "CA": CGPoint(x: 131, y: 104), "GB": CGPoint(x: 297, y: 130), "DE": CGPoint(x: 464, y: 60),
    "NL": CGPoint(x: 415, y: 186), "FR": CGPoint(x: 218, y: 205), "US": CGPoint(x: 95, y: 242),
    "RU": CGPoint(x: 531, y: 259), "TR": CGPoint(x: 278, y: 355), "BR": CGPoint(x: 122, y: 376),
    "SG": CGPoint(x: 472, y: 374), "AU": CGPoint(x: 336, y: 447),
  ]

  /// Free anchor positions that don't overlap the slots above (ordered left to right).
  static let spare: [CGPoint] = [
    CGPoint(x: 40, y: 160), CGPoint(x: 40, y: 320), CGPoint(x: 150, y: 300), CGPoint(x: 200, y: 450),
    CGPoint(x: 250, y: 40), CGPoint(x: 390, y: 110), CGPoint(x: 480, y: 450), CGPoint(x: 560, y: 150),
    CGPoint(x: 560, y: 420), CGPoint(x: 575, y: 330),
  ]

  static let core = CGPoint(x: 327.5, y: 240)
  static let chipHeight: CGFloat = 42

  /// Anchor positions for the given countries (sorted by longitude for the spare slots).
  static func positions(for countries: [AppModel.CountryNode]) -> [String: CGPoint] {
    var out: [String: CGPoint] = [:]
    var free = spare
    let others = countries.filter { slots[$0.cc] == nil }.sorted { $0.lon < $1.lon }
    for c in countries where slots[c.cc] != nil { out[c.id] = slots[c.cc] }
    for (i, c) in others.enumerated() {
      if !free.isEmpty {
        // keep geography roughly: west countries take the left spare slots
        let target = Double(i) / Double(max(1, others.count - 1)) * Double(free.count - 1)
        let index = min(free.count - 1, max(0, Int(target.rounded())))
        out[c.id] = free.remove(at: index)
      } else {
        let angle = Double(i) * 2.399963
        let r = 150 + Double(i % 4) * 25
        out[c.id] = CGPoint(x: core.x + CGFloat(cos(angle) * r), y: core.y + CGFloat(sin(angle) * r * 0.85))
      }
    }
    return out
  }
}

/// Renders the static part of the map (rings, star field, web, glow) once per size.
enum MapTexture {
  static let hubs: [CGPoint] = [CGPoint(x: 235, y: 297), CGPoint(x: 352, y: 301), CGPoint(x: 377, y: 295),
                                CGPoint(x: 440, y: 65), CGPoint(x: 532, y: 409)]

  /// Long sweeping arcs that don't end at countries (as in the mock).
  static let sweeps: [(CGPoint, CGPoint, CGPoint)] = [
    (CGPoint(x: 292, y: 42), CGPoint(x: 520, y: 40), CGPoint(x: 557, y: 300)),
    (CGPoint(x: 440, y: 65), CGPoint(x: 520, y: 210), CGPoint(x: 377, y: 295)),
    (CGPoint(x: 60, y: 300), CGPoint(x: 95, y: 470), CGPoint(x: 300, y: 470)),
    (CGPoint(x: 190, y: 480), CGPoint(x: 230, y: 380), CGPoint(x: 300, y: 300)),
    (CGPoint(x: 377, y: 295), CGPoint(x: 500, y: 290), CGPoint(x: 560, y: 180)),
    (CGPoint(x: 340, y: 132), CGPoint(x: 400, y: 70), CGPoint(x: 440, y: 65)),
    (CGPoint(x: 352, y: 301), CGPoint(x: 345, y: 380), CGPoint(x: 330, y: 445)),
  ]

  /// The 640 × 495 reference map drawn at `m` points per reference pixel.
  static func render(m: CGFloat, scale: CGFloat) -> UIImage {
    let size = CGSize(width: DS.refWidth * m, height: DS.Geo.mapHeight * m)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      let cg = context.cgContext
      cg.scaleBy(x: m, y: m) // draw in reference pixels
      var rng = SeededRandom(seed: 0x51_6E_A1)
      let center = CGPoint(x: 325, y: 248)
      let core = MapLayout.core
      func white(_ a: Double) -> CGColor { UIColor(white: 1, alpha: CGFloat(a)).cgColor }

      // concentric rings drawn as faint ellipses, brighter dashes and dots
      let radii: [CGFloat] = [273, 240, 205, 170, 136, 102]
      for (index, rx) in radii.enumerated() {
        let ry = rx * 0.875
        let rect = CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)
        cg.setStrokeColor(white(0.035))
        cg.setLineWidth(0.8)
        cg.strokeEllipse(in: rect)
        let dashes = 4 + index
        for _ in 0..<dashes {
          let start = rng.range(0, 2 * .pi)
          let span = rng.range(0.15, 0.9)
          let path = CGMutablePath()
          var first = true
          for k in 0...24 {
            let a = start + span * Double(k) / 24
            let p = CGPoint(x: center.x + rx * CGFloat(cos(a)), y: center.y + ry * CGFloat(sin(a)))
            if first { path.move(to: p); first = false } else { path.addLine(to: p) }
          }
          cg.addPath(path)
          cg.setStrokeColor(white(rng.range(0.07, 0.17)))
          cg.setLineWidth(CGFloat(rng.range(0.6, 1.0)))
          cg.strokePath()
        }
        let dots = Int(rx * 0.7)
        for _ in 0..<dots {
          guard rng.next() > 0.35 else { continue }
          let a = rng.range(0, 2 * .pi)
          let p = CGPoint(x: center.x + rx * CGFloat(cos(a)) + CGFloat(rng.range(-1.2, 1.2)), y: center.y + ry * CGFloat(sin(a)) + CGFloat(rng.range(-1.2, 1.2)))
          let s = CGFloat(rng.range(0.7, 1.6))
          cg.setFillColor(white(rng.range(0.12, 0.45)))
          cg.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
        }
      }

      // star field, denser toward the core
      for _ in 0..<2100 {
        let r = 285 * pow(rng.next(), 1.35)
        let a = rng.range(0, 2 * .pi)
        let p = CGPoint(x: core.x + CGFloat(cos(a) * r), y: core.y + CGFloat(sin(a) * r * 0.88))
        let falloff = max(0.1, 1 - r / 330)
        let s = CGFloat(rng.range(0.6, 1.6))
        cg.setFillColor(white(rng.range(0.12, 0.7) * falloff + 0.05))
        cg.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
      }

      // fine web around the core
      var nodes: [CGPoint] = []
      for _ in 0..<360 {
        let r = 195 * pow(rng.next(), 1.15)
        let a = rng.range(0, 2 * .pi)
        nodes.append(CGPoint(x: core.x + CGFloat(cos(a) * r), y: core.y + CGFloat(sin(a) * r * 0.9)))
      }
      cg.setLineWidth(0.55)
      for (i, p) in nodes.enumerated() {
        var nearest: [(CGFloat, Int)] = []
        for (j, q) in nodes.enumerated() where j != i {
          let d = hypot(p.x - q.x, p.y - q.y)
          if nearest.count < 2 { nearest.append((d, j)); nearest.sort { $0.0 < $1.0 } } else if d < nearest[1].0 { nearest[1] = (d, j); nearest.sort { $0.0 < $1.0 } }
        }
        let dc = hypot(p.x - core.x, p.y - core.y)
        for (d, j) in nearest where d < 60 {
          cg.move(to: p)
          cg.addLine(to: nodes[j])
          cg.setStrokeColor(white(0.04 + 0.16 * Double(max(0, 1 - dc / 190))))
          cg.strokePath()
        }
        let s: CGFloat = rng.next() < 0.2 ? 1.6 : 1.0
        cg.setFillColor(white(0.25 + 0.5 * Double(max(0, 1 - dc / 220))))
        cg.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
      }

      // long sweeping arcs
      for (a, c, b) in sweeps {
        let path = CGMutablePath()
        path.move(to: a)
        path.addQuadCurve(to: b, control: c)
        cg.addPath(path)
        cg.setStrokeColor(white(0.06))
        cg.setLineWidth(3)
        cg.strokePath()
        cg.addPath(path)
        cg.setStrokeColor(white(0.32))
        cg.setLineWidth(0.9)
        cg.strokePath()
      }

      // glow of the core
      let stops: [(CGFloat, Double)] = [(0, 1.0), (0.05, 0.95), (0.1, 0.64), (0.16, 0.4), (0.24, 0.21), (0.38, 0.1), (0.6, 0.045), (0.8, 0.02), (1, 0)]
      let colors = stops.map { white($0.1) } as CFArray
      let locations = stops.map { $0.0 }
      if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
        cg.drawRadialGradient(gradient, startCenter: core, startRadius: 0, endCenter: core, endRadius: 175, options: [])
      }

      // bright hubs with a small flare
      for h in hubs {
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [white(0.5), white(0)] as CFArray, locations: [0, 1]) {
          cg.drawRadialGradient(gradient, startCenter: h, startRadius: 0, endCenter: h, endRadius: 9, options: [])
        }
        cg.setStrokeColor(white(0.22))
        cg.setLineWidth(0.6)
        cg.move(to: CGPoint(x: h.x - 7, y: h.y)); cg.addLine(to: CGPoint(x: h.x + 7, y: h.y))
        cg.move(to: CGPoint(x: h.x, y: h.y - 7)); cg.addLine(to: CGPoint(x: h.x, y: h.y + 7))
        cg.strokePath()
        cg.setFillColor(white(1))
        cg.fillEllipse(in: CGRect(x: h.x - 1.6, y: h.y - 1.6, width: 3.2, height: 3.2))
      }
    }
  }
}

/// Device tilt for a subtle parallax.
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
      let next = CGSize(width: self.tilt.width * 0.85 + x * 0.15, height: self.tilt.height * 0.85 + y * 0.15)
      if abs(next.width - self.tilt.width) > 0.003 || abs(next.height - self.tilt.height) > 0.003 { self.tilt = next }
    }
  }

  func stop() {
    guard running else { return }
    running = false
    manager.stopDeviceMotionUpdates()
    tilt = .zero
  }
}

/// The map: static texture, arcs from the core to each country, anchor dots and country capsules.
/// Pinch to zoom, two-finger rotate, drag to move, double tap to reset.
struct NetworkMapView: View {
  let nodes: [AppModel.CountryNode]
  let highlighted: String?
  let connected: Bool
  let animate: Bool
  let parallax: Bool
  let s: RefScale
  var onNode: (AppModel.CountryNode) -> Void
  var onNodeList: (AppModel.CountryNode) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var motion = MotionParallax()
  @State private var texture: UIImage?
  @State private var textureScale: CGFloat = 0
  @State private var zoom: CGFloat = 1
  @GestureState private var pinch: CGFloat = 1
  @State private var angle: Angle = .zero
  @GestureState private var twist: Angle = .zero
  @State private var pan: CGSize = .zero
  @GestureState private var drag: CGSize = .zero
  @State private var start = Date()

  init(nodes: [AppModel.CountryNode], highlighted: String?, connected: Bool, animate: Bool, parallax: Bool, s: RefScale,
       onNode: @escaping (AppModel.CountryNode) -> Void, onNodeList: @escaping (AppModel.CountryNode) -> Void) {
    self.nodes = nodes
    self.highlighted = highlighted
    self.connected = connected
    self.animate = animate
    self.parallax = parallax
    self.s = s
    self.onNode = onNode
    self.onNodeList = onNodeList
  }

  private var moving: Bool { animate && !reduceMotion }

  var body: some View {
    // read every input here, in body, so that changes reach the deferred GeometryReader content
    let nodes = self.nodes
    let highlighted = self.highlighted
    let connected = self.connected
    let moving = self.moving
    let texture = self.texture
    let positions = MapLayout.positions(for: nodes)
    let z = min(2.6, max(0.7, zoom * pinch))
    let rot = angle + twist
    let offset = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
    let tilt = parallax && !reduceMotion ? motion.tilt : .zero
    return GeometryReader { geo in
      // the map keeps the mock's proportions and shrinks on short screens; country chips keep their size
      let m = max(0.1, min(s.u, geo.size.height / DS.Geo.mapHeight))
      let mapSize = CGSize(width: DS.refWidth * m, height: DS.Geo.mapHeight * m)
      let left = (geo.size.width - mapSize.width) / 2
      let top = (geo.size.height - mapSize.height) / 2
      let core = CGPoint(x: left + MapLayout.core.x * m, y: top + MapLayout.core.y * m)
      let transform: (CGPoint) -> CGPoint = { p in
        let dx = (p.x - core.x) * z, dy = (p.y - core.y) * z
        let c = CGFloat(cos(rot.radians)), sn = CGFloat(sin(rot.radians))
        return CGPoint(x: core.x + dx * c - dy * sn + offset.width, y: core.y + dx * sn + dy * c + offset.height)
      }
      let placed: [PlacedNode] = nodes.compactMap { n in
        guard let p = positions[n.id] else { return nil }
        let base = transform(CGPoint(x: left + p.x * m, y: top + p.y * m))
        return PlacedNode(node: n, point: CGPoint(x: base.x + tilt.width * 5, y: base.y + tilt.height * 5))
      }
      let corePoint = CGPoint(x: core.x + offset.width + tilt.width * 2, y: core.y + offset.height + tilt.height * 2)
      let anchor = UnitPoint(x: MapLayout.core.x / DS.refWidth, y: MapLayout.core.y / DS.Geo.mapHeight)
      ZStack(alignment: .topLeading) {
        if let texture = texture {
          Image(uiImage: texture)
            .resizable()
            .frame(width: mapSize.width, height: mapSize.height)
            .scaleEffect(z, anchor: anchor)
            .rotationEffect(rot, anchor: anchor)
            .offset(x: left + offset.width + tilt.width * 2, y: top + offset.height + tilt.height * 2)
            .allowsHitTesting(false)
        }
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
          let t = context.date.timeIntervalSince(start)
          Canvas { ctx, _ in
            for (i, item) in placed.enumerated() {
              let p = item.point
              let active = item.node.cc == highlighted
              let shimmer = moving ? 0.82 + 0.18 * sin(t * 1.3 + Double(i) * 1.7) : 1
              let mid = CGPoint(x: (p.x + corePoint.x) / 2, y: (p.y + corePoint.y) / 2)
              let dx = corePoint.x - p.x, dy = corePoint.y - p.y
              let bend: CGFloat = (i % 2 == 0 ? 0.2 : -0.2)
              let control = CGPoint(x: mid.x - dy * bend, y: mid.y + dx * bend)
              var arc = Path()
              arc.move(to: p)
              arc.addQuadCurve(to: corePoint, control: control)
              ctx.stroke(arc, with: .color(.white.opacity(0.07 * shimmer)), lineWidth: 3.5 * m)
              ctx.stroke(arc, with: .color(.white.opacity((active ? 0.85 : 0.42) * shimmer)), lineWidth: (active ? 1.5 : 1.0) * m)
            }
          }
          .allowsHitTesting(false)
        }
        ForEach(placed) { item in
          NodeChip(node: item.node, active: item.node.cc == highlighted, connected: connected && item.node.cc == highlighted, s: s,
                   onTap: { onNode(item.node) }, onList: { onNodeList(item.node) })
            .fixedSize()
            .offset(x: item.point.x - s(19), y: item.point.y - s(40))
        }
        // anchor dots sit on the lower edge of each chip, under the flag
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
          let t = context.date.timeIntervalSince(start)
          Canvas { ctx, _ in
            for (i, item) in placed.enumerated() {
              let p = item.point
              let active = item.node.cc == highlighted
              let pulse = moving ? 1 + 0.25 * sin(t * 2.2 + Double(i)) : 1
              let glow = s(7) * CGFloat(pulse)
              ctx.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                       with: .radialGradient(Gradient(colors: [.white.opacity(active ? 0.6 : 0.4), .white.opacity(0)]), center: p, startRadius: 0, endRadius: glow))
              let r = s(active ? 3 : 2.4)
              ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white))
            }
          }
          .allowsHitTesting(false)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
      .contentShape(Rectangle())
      .gesture(dragGesture.simultaneously(with: pinchGesture.simultaneously(with: rotateGesture)))
      .onTapGesture(count: 2) {
        Haptics.soft()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
          zoom = 1
          angle = .zero
          pan = .zero
        }
      }
      .task(id: m) {
        guard textureScale != m else { return }
        let scale = UIScreen.main.scale
        let image = await Task.detached(priority: .userInitiated) { MapTexture.render(m: m, scale: scale) }.value
        self.texture = image
        textureScale = m
      }
    }
    .clipped()
    .onAppear { if parallax && !reduceMotion { motion.start() } }
    .onDisappear { motion.stop() }
    .onChange(of: parallax) { on in if on && !reduceMotion { motion.start() } else { motion.stop() } }
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 8)
      .updating($drag) { v, state, _ in state = v.translation }
      .onEnded { v in
        pan.width = max(-260, min(260, pan.width + v.translation.width))
        pan.height = max(-200, min(200, pan.height + v.translation.height))
      }
  }

  private var pinchGesture: some Gesture {
    MagnificationGesture()
      .updating($pinch) { v, state, _ in state = v }
      .onEnded { v in zoom = min(2.6, max(0.7, zoom * v)) }
  }

  private var rotateGesture: some Gesture {
    RotationGesture()
      .updating($twist) { v, state, _ in state = v }
      .onEnded { v in angle += v }
  }
}

struct PlacedNode: Identifiable {
  let node: AppModel.CountryNode
  let point: CGPoint
  var id: String { node.id }
}

/// A country capsule: round flag, ISO code, best ping.
struct NodeChip: View {
  let node: AppModel.CountryNode
  let active: Bool
  let connected: Bool
  let s: RefScale
  var onTap: () -> Void
  var onList: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .center, spacing: s(10)) {
        RoundFlag(cc: node.cc, diameter: s(21))
        VStack(alignment: .leading, spacing: s(3.5)) {
          Text(node.cc.isEmpty ? "??" : node.cc)
            .refFont(s, DS.Size.nodeCode, .semibold)
            .foregroundStyle(DS.textPrimary)
          Text(pingText)
            .refFont(s, DS.Size.nodeMs, digits: true)
            .foregroundStyle(DS.textNodeMs)
        }
      }
      .padding(.leading, s(9))
      .padding(.trailing, s(13))
      .frame(height: s(MapLayout.chipHeight))
      .background(
        RoundedRectangle(cornerRadius: s(9), style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay(RoundedRectangle(cornerRadius: s(9), style: .continuous).fill(DS.nodeFill))
      )
      .overlay(
        RoundedRectangle(cornerRadius: s(9), style: .continuous)
          .strokeBorder(active ? Color.white.opacity(connected ? 0.7 : 0.4) : DS.nodeBorder, lineWidth: active ? 1.2 : 1)
      )
      .shadow(color: active ? Color.white.opacity(0.18) : .clear, radius: s(10))
    }
    .buttonStyle(.plain)
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
