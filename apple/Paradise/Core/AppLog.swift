import Foundation
import SwiftUI

/// One log line from the app, the Go core or the tunnel extension.
struct LogLine: Identifiable, Hashable {
  let id: String
  let time: Date
  let level: String
  let source: String
  let msg: String

  var text: String {
    "\(LogLine.formatter.string(from: time)) [\(level.uppercased())] \(source): \(msg)"
  }

  static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()
}

/// In-memory app log (never written to disk, never sent anywhere).
enum AppLog {
  private static let lock = NSLock()
  private static var lines: [LogLine] = []
  private static var counter = 0
  private static let capacity = 600

  static func info(_ source: String, _ msg: String) { add("info", source, msg) }
  static func warn(_ source: String, _ msg: String) { add("warn", source, msg) }
  static func error(_ source: String, _ msg: String) { add("error", source, msg) }

  static func add(_ level: String, _ source: String, _ msg: String) {
    lock.lock()
    counter += 1
    lines.append(LogLine(id: "a\(counter)", time: Date(), level: level, source: source, msg: Redactor.clean(msg)))
    if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    lock.unlock()
  }

  static func snapshot() -> [LogLine] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }

  static func clear() {
    lock.lock()
    lines.removeAll()
    lock.unlock()
  }
}

/// Removes subscription paths, credentials, UUIDs and transfer codes from log text.
enum Redactor {
  private static let url = try? NSRegularExpression(pattern: "(?i)\\b([a-z][a-z0-9+.-]*)://([^\\s/?#\"']+)[^\\s\"']*")
  private static let uuid = try? NSRegularExpression(pattern: "(?i)\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b")
  private static let code = try? NSRegularExpression(pattern: "\\b(PD1|SVOI1)\\.[A-Za-z0-9_\\-+/=]{8,}")

  static func clean(_ input: String) -> String {
    var s = input
    s = replace(code, in: s, with: "$1.<code>")
    if let url = url {
      let ns = s as NSString
      var out = ""
      var last = 0
      for m in url.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        let scheme = ns.substring(with: m.range(at: 1)).lowercased()
        var host = ns.substring(with: m.range(at: 2))
        if let at = host.lastIndex(of: "@") { host = "<cred>@" + host[host.index(after: at)...] }
        if scheme == "http" || scheme == "https" {
          out += m.range.length > m.range(at: 1).length + 3 + m.range(at: 2).length ? "\(scheme)://\(host)/<…>" : "\(scheme)://\(host)"
        } else {
          out += "\(scheme)://<…>"
        }
        last = m.range.location + m.range.length
      }
      out += ns.substring(from: last)
      s = out
    }
    s = replace(uuid, in: s, with: "<uuid>")
    return s.count > 600 ? String(s.prefix(600)) + "…" : s
  }

  private static func replace(_ re: NSRegularExpression?, in s: String, with template: String) -> String {
    guard let re = re else { return s }
    return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
  }
}

/// Detects main-thread stalls ("lags") and writes them to the log.
final class HangDetector {
  static let shared = HangDetector()
  private let queue = DispatchQueue(label: "app.paradise.watchdog", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var waiting = false
  private var sentAt = Date()
  private(set) var worstMS = 0
  private(set) var hangs = 0

  func start() {
    queue.async {
      guard self.timer == nil else { return }
      let t = DispatchSource.makeTimerSource(queue: self.queue)
      t.schedule(deadline: .now() + 2, repeating: 0.25)
      t.setEventHandler { [weak self] in self?.tick() }
      t.resume()
      self.timer = t
    }
  }

  private func tick() {
    guard !waiting else { return }
    waiting = true
    sentAt = Date()
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let lag = Int(Date().timeIntervalSince(self.sentAt) * 1000)
      self.queue.async {
        self.waiting = false
        if lag > 300 {
          self.hangs += 1
          self.worstMS = max(self.worstMS, lag)
          AppLog.add(lag > 1000 ? "error" : "warn", "ui", "main thread blocked for \(lag) ms")
        }
      }
    }
  }

  var summary: String {
    queue.sync { hangs == 0 ? "no stalls > 300 ms" : "\(hangs) stalls, worst \(worstMS) ms" }
  }
}
