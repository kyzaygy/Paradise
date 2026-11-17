import NetworkExtension
import SwiftUI

/// The dominant connect control: a lens that fills with the accent when connected.
struct ConnectOrb: View {
  var status: NEVPNStatus
  var enabled: Bool
  var action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var spin = false
  @State private var breathe = false

  init(status: NEVPNStatus, enabled: Bool, action: @escaping () -> Void) {
    self.status = status
    self.enabled = enabled
    self.action = action
  }

  private var connected: Bool { status == .connected || status == .reasserting }
  private var transitioning: Bool { status == .connecting || status == .disconnecting }

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(connected ? Theme.accent.opacity(0.14) : Theme.surfaceRaised.opacity(0.6))
          .scaleEffect(breathe && connected && !reduceMotion ? 1.08 : 1)
        Circle()
          .strokeBorder(connected ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 1.5)
          .padding(18)
        Circle()
          .fill(connected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface))
          .padding(34)
          .shadow(color: connected ? Theme.accent.opacity(0.45) : .black.opacity(0.08), radius: connected ? 28 : 10)
        if transitioning {
          Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .padding(24)
            .rotationEffect(.degrees(spin ? 360 : 0))
        }
        Image(systemName: "power")
          .font(.system(size: 54, weight: .semibold, design: .rounded))
          .foregroundStyle(connected ? Theme.onAccent : (enabled ? Theme.accent : Theme.muted))
      }
      .frame(width: 236, height: 236)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(status == .disconnecting)
    .accessibilityLabel(connected ? L("home.a11y.disconnect") : L("home.a11y.connect"))
    .accessibilityValue(Self.statusText(status))
    .onAppear { animate() }
    .onChange(of: status) { _ in animate() }
  }

  private func animate() {
    guard !reduceMotion else { spin = false; breathe = false; return }
    spin = false
    breathe = false
    if transitioning {
      withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
    }
    if connected {
      withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
    }
  }

  static func statusText(_ status: NEVPNStatus) -> String {
    switch status {
    case .connected: return L("status.connected")
    case .connecting: return L("status.connecting")
    case .disconnecting: return L("status.disconnecting")
    case .reasserting: return L("status.reasserting")
    default: return L("status.disconnected")
    }
  }
}
