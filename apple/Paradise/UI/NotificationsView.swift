import SwiftUI

struct NotificationsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  init() {}

  var body: some View {
    NavigationStack {
      Group {
        if model.notices.isEmpty {
          VStack(spacing: 10) {
            Image(systemName: "bell.slash").font(.largeTitle).foregroundStyle(Theme.dim)
            Text(L("notices.empty")).font(.subheadline).foregroundStyle(Theme.dim)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(model.notices) { notice in
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 8) {
                Image(systemName: icon(notice.kind)).foregroundStyle(color(notice.kind))
                Text(notice.title).font(Theme.label(.subheadline))
              }
              Text(notice.body).font(.subheadline).foregroundStyle(.secondary)
              if let link = notice.link, let url = URL(string: link) {
                Button(L("notices.open")) { openURL(url) }
                  .font(.footnote.weight(.semibold))
              }
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.spaceRaised)
          }
          .scrollContentBackground(.hidden)
        }
      }
      .background(Theme.space.ignoresSafeArea())
      .navigationTitle(L("notices.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(L("common.done")) { dismiss() } } }
    }
    .onAppear { model.markNoticesSeen() }
  }

  private func icon(_ kind: AppModel.Notice.Kind) -> String {
    switch kind {
    case .announce: return "megaphone.fill"
    case .expiry: return "calendar.badge.exclamationmark"
    case .traffic: return "chart.pie.fill"
    case .error: return "exclamationmark.triangle.fill"
    case .geo: return "globe"
    }
  }

  private func color(_ kind: AppModel.Notice.Kind) -> Color {
    switch kind {
    case .announce: return Theme.glowCool
    case .expiry, .traffic: return Theme.fair
    case .error: return Theme.poor
    case .geo: return Theme.glow
    }
  }
}
