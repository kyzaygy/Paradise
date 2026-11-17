import Foundation

/// Localized string by key (Localizable.strings, ru and en).
func L(_ key: String) -> String {
  NSLocalizedString(key, comment: "")
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

  static func relative(_ iso: String?) -> String? {
    guard let iso = iso else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = parser.date(from: iso)
    if date == nil {
      parser.formatOptions = [.withInternetDateTime]
      date = parser.date(from: iso)
    }
    guard let date = date else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  static func duration(since date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
  }
}
