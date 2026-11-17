import Foundation

/// Localized string by key (Localizable.strings, ru and en).
func L(_ key: String) -> String {
  Localization.string(key)
}

/// Localized format string.
func LF(_ key: String, _ args: CVarArg...) -> String {
  String(format: L(key), arguments: args)
}

enum Format {
  static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
  }

  static func date(_ unix: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
  }

  static func shortDate(_ unix: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
  }

  static func country(_ cc: String?) -> String {
    guard let cc = cc, !cc.isEmpty else { return L("country.unknown") }
    return Localization.locale.localizedString(forRegionCode: cc) ?? cc
  }

  static func flag(_ cc: String?) -> String {
    guard let cc = cc?.uppercased(), cc.count == 2 else { return "🌐" }
    var out = ""
    for scalar in cc.unicodeScalars {
      guard let s = UnicodeScalar(127397 + scalar.value) else { return "🌐" }
      out.unicodeScalars.append(s)
    }
    return out
  }

  static func ms(_ value: Int64) -> String { LF("latency.ms", value) }

  static func rate(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
  }

  static func parseDate(_ iso: String?) -> Date? {
    guard let iso = iso else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    if let d = parser.date(from: iso) { return d }
    // Go writes nanoseconds; drop the fraction
    if let dot = iso.firstIndex(of: "."), let end = iso[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
      return parser.date(from: String(iso[..<dot]) + String(iso[end...]))
    }
    return nil
  }

  static func relative(_ iso: String?) -> String? {
    guard let date = parseDate(iso) else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.locale = Localization.locale
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  static func duration(since date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
  }
}
