import Darwin
import Foundation
import NetworkExtension

/// Moves packets between NEPacketTunnelFlow and a datagram socket using utun framing
/// (4-byte big-endian address family header). Adapted from SVOI (MIT, SVOI contributors).
///
/// IPv4 packets addressed to a "reflect" address (10.7.0.1 for StikDebug/SideStore) never reach Xray:
/// source and destination are swapped and the packet is written back to the device. Swapping two
/// addresses keeps the IP and TCP/UDP checksums valid.
final class PacketPump {
  struct Counters {
    var up: UInt64 = 0
    var down: UInt64 = 0
    var reflected: UInt64 = 0
  }

  private let flow: NEPacketTunnelFlow
  private let descriptor: Int32
  private let queue = DispatchQueue(label: "app.paradise.packets", qos: .userInitiated)
  private var source: DispatchSourceRead?
  private var active = false
  private var buffer = [UInt8](repeating: 0, count: 65540)
  private let failed: () -> Void
  private let reflect: Set<UInt32>
  private var counters = Counters()

  init(flow: NEPacketTunnelFlow, descriptor: Int32, reflect: [String] = [], failed: @escaping () -> Void) {
    self.flow = flow
    self.descriptor = descriptor
    self.failed = failed
    var set = Set<UInt32>()
    for address in reflect {
      var addr = in_addr()
      if inet_pton(AF_INET, address, &addr) == 1 { set.insert(addr.s_addr) }
    }
    self.reflect = set
  }

  func start() {
    queue.sync {
      active = true
      let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
      reader.setEventHandler { [weak self] in self?.receive() }
      let fd = descriptor
      reader.setCancelHandler { Darwin.close(fd) }
      source = reader
      reader.resume()
      readFromFlow()
    }
  }

  func stop() {
    queue.sync {
      active = false
      source?.cancel()
      source = nil
    }
  }

  /// Traffic counters since the pump started.
  var snapshot: Counters { queue.sync { counters } }

  private func readFromFlow() {
    guard active else { return }
    flow.readPackets { [weak self] packets, families in
      guard let self = self else { return }
      self.queue.async {
        guard self.active else { return }
        var reflected: [Data] = []
        for (packet, family) in zip(packets, families) {
          let af = family.int32Value
          guard !packet.isEmpty, packet.count <= 65535, af == AF_INET || af == AF_INET6 else { continue }
          if af == AF_INET, !self.reflect.isEmpty, let mirrored = self.mirror(packet) {
            reflected.append(mirrored)
            continue
          }
          self.counters.up &+= UInt64(packet.count)
          let sent = Self.send(packet, family: af, descriptor: self.descriptor)
          if sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ENOBUFS {
            self.fail()
            return
          }
        }
        if !reflected.isEmpty {
          self.counters.reflected &+= UInt64(reflected.count)
          _ = self.flow.writePackets(reflected, withProtocols: Array(repeating: NSNumber(value: AF_INET), count: reflected.count))
        }
        self.readFromFlow()
      }
    }
  }

  /// Returns the packet with source and destination swapped when its destination is a reflect address.
  private func mirror(_ packet: Data) -> Data? {
    guard packet.count >= 20 else { return nil }
    let destination: UInt32 = packet.withUnsafeBytes { raw in
      var value: UInt32 = 0
      memcpy(&value, raw.baseAddress!.advanced(by: 16), 4)
      return value
    }
    guard reflect.contains(destination) else { return nil }
    var copy = packet
    copy.withUnsafeMutableBytes { raw in
      let base = raw.baseAddress!
      var src = [UInt8](repeating: 0, count: 4)
      memcpy(&src, base.advanced(by: 12), 4)
      memcpy(base.advanced(by: 12), base.advanced(by: 16), 4)
      memcpy(base.advanced(by: 16), src, 4)
    }
    return copy
  }

  private func receive() {
    guard active else { return }
    var packets: [Data] = []
    var protocols: [NSNumber] = []
    packets.reserveCapacity(64)
    protocols.reserveCapacity(64)
    for _ in 0..<64 {
      let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
      if count < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { break }
        if errno == EINTR { continue }
        fail()
        return
      }
      if count == 0 { fail(); return }
      guard count > 4 else { continue }
      let family = Int32(buffer[3])
      guard family == AF_INET || family == AF_INET6 else { continue }
      packets.append(Data(buffer[4..<count]))
      protocols.append(NSNumber(value: family))
      counters.down &+= UInt64(count - 4)
    }
    if !packets.isEmpty { _ = flow.writePackets(packets, withProtocols: protocols) }
  }

  private func fail() {
    guard active else { return }
    active = false
    source?.cancel()
    source = nil
    failed()
  }

  static func send(_ packet: Data, family: Int32, descriptor: Int32) -> Int {
    var header = UInt32(family).bigEndian
    return withUnsafePointer(to: &header) { prefix in
      packet.withUnsafeBytes { payload in
        var vectors = [
          iovec(iov_base: UnsafeMutableRawPointer(mutating: prefix), iov_len: 4),
          iovec(iov_base: UnsafeMutableRawPointer(mutating: payload.baseAddress), iov_len: payload.count),
        ]
        return vectors.withUnsafeMutableBufferPointer { vector in
          var message = msghdr()
          message.msg_iov = vector.baseAddress
          message.msg_iovlen = 2
          var result: Int
          repeat { result = Darwin.sendmsg(descriptor, &message, 0) } while result < 0 && errno == EINTR
          return result
        }
      }
    }
  }
}
