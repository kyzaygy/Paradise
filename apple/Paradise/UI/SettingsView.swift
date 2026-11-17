import SwiftUI
import UIKit

struct LicensesView: View {
  @Environment(\.dismiss) private var dismiss

  init() {}

  private var text: String {
    guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "txt"),
          let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    return s
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(text).font(Theme.mono).padding().frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(L("settings.licenses"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(L("common.done")) { dismiss() } } }
    }
  }
}
