import SwiftUI
import UIKit

struct ServersView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var vpn: VPNController
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var sort: Sort = .original
  @State private var renaming: CoreSubscription?
  @State private var newName = ""
  @State private var deleting: CoreSubscription?

  enum Sort: String, CaseIterable { case original, latency, name }

  init() {}

  var body: some View {
    NavigationStack {
      List {
        if model.state.servers.isEmpty {
          Text(L("servers.empty")).foregroundStyle(Theme.muted)
        }
        let favorites = filtered(model.state.servers.filter(\.favorite))
        if !favorites.isEmpty {
          Section(L("servers.favorites")) {
            ForEach(favorites) { row($0) }
          }
        }
        ForEach(model.state.subscriptions) { sub in
          let servers = filtered(model.state.servers.filter { $0.subscriptionId == sub.id })
          if !servers.isEmpty || query.isEmpty {
            Section {
              ForEach(servers) { row($0) }
            } header: {
              header(sub)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(Theme.canvas)
      .searchable(text: $query, prompt: L("servers.search"))
      .refreshable { await model.refreshAll() }
      .navigationTitle(L("servers.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button(L("common.done")) { dismiss() }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
          Menu {
            Picker(L("servers.sort"), selection: $sort) {
              Text(L("servers.sort.original")).tag(Sort.original)
              Text(L("servers.sort.latency")).tag(Sort.latency)
              Text(L("servers.sort.name")).tag(Sort.name)
            }
          } label: {
            Image(systemName: "arrow.up.arrow.down")
          }
          .accessibilityLabel(L("servers.sort"))
          Button {
            if model.probing { model.cancelProbes() } else { model.probe(visibleServers) }
          } label: {
            Image(systemName: model.probing ? "stop.circle" : "speedometer")
          }
          .accessibilityLabel(model.probing ? L("servers.probe_stop") : L("servers.probe"))
        }
      }
      .overlay(alignment: .bottom) {
        if model.refreshing {
          ProgressView(L("servers.refreshing"))
            .padding(12)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
        }
      }
      .alert(L("servers.rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
        TextField(L("servers.rename_placeholder"), text: $newName)
        Button(L("common.cancel"), role: .cancel) { renaming = nil }
        Button(L("common.save")) {
          if let sub = renaming { Task { await model.rename(sub, to: newName) } }
          renaming = nil
        }
      }
      .confirmationDialog(L("servers.delete_confirm"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
        Button(L("common.delete"), role: .destructive) {
          if let sub = deleting { Task { await model.delete(sub) } }
          deleting = nil
        }
      }
    }
    .onDisappear { model.cancelProbes() }
  }

  private var visibleServers: [CoreServer] {
    var seen = Set<String>()
    return filtered(model.state.servers).filter { seen.insert($0.id).inserted }
  }

  private func filtered(_ servers: [CoreServer]) -> [CoreServer] {
    var list = servers
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if !q.isEmpty {
      list = list.filter { $0.name.lowercased().contains(q) || $0.address.lowercased().contains(q) || $0.`protocol`.contains(q) }
    }
    switch sort {
    case .original: break
    case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    case .latency: list.sort { rank($0) < rank($1) }
    }
    return list
  }

  private func rank(_ server: CoreServer) -> Int64 {
    switch model.latency[server.id] {
    case .ms(let ms): return ms
    case .testing: return 1_000_000
    case .failed: return 2_000_000
    case nil: return 1_500_000
    }
  }

  private func row(_ server: CoreServer) -> some View {
    Button {
      Task { await model.select(server) }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: model.state.selected == server.id ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(model.state.selected == server.id ? Theme.accent : Theme.muted)
        VStack(alignment: .leading, spacing: 2) {
          Text(server.name).font(.body).foregroundStyle(.primary).lineLimit(1)
          Text(server.detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
        }
        Spacer(minLength: 6)
        LatencyBadge(value: model.latency[server.id])
        if server.favorite {
          Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.warning)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(Theme.surface)
    .swipeActions(edge: .trailing) {
      Button { Task { await model.toggleFavorite(server) } } label: {
        Label(server.favorite ? L("servers.unfavorite") : L("servers.favorite"), systemImage: server.favorite ? "star.slash" : "star")
      }
      .tint(Theme.warning)
    }
    .contextMenu {
      Button { Task { await model.toggleFavorite(server) } } label: {
        Label(server.favorite ? L("servers.unfavorite") : L("servers.favorite"), systemImage: "star")
      }
      Button { model.probe([server]) } label: { Label(L("servers.probe_one"), systemImage: "speedometer") }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(model.state.selected == server.id ? .isSelected : [])
  }

  private func header(_ sub: CoreSubscription) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(sub.displayName).font(Theme.label(.subheadline)).textCase(nil).foregroundStyle(.primary)
        Spacer()
        Menu {
          if sub.remote {
            Button { Task { await model.refresh(sub) } } label: { Label(L("servers.refresh"), systemImage: "arrow.clockwise") }
          }
          Button {
            newName = sub.name
            renaming = sub
          } label: { Label(L("servers.rename"), systemImage: "pencil") }
          if let support = sub.meta?.supportUrl, let url = URL(string: support) {
            Link(destination: url) { Label(L("servers.support"), systemImage: "questionmark.bubble") }
          }
          Button(role: .destructive) { deleting = sub } label: { Label(L("common.delete"), systemImage: "trash") }
        } label: {
          Image(systemName: "ellipsis.circle").font(.body)
        }
        .accessibilityLabel(L("servers.subscription_actions"))
      }
      if let info = subscriptionInfo(sub) {
        Text(info).font(.caption).foregroundStyle(Theme.muted).textCase(nil)
      }
      if let error = sub.lastError {
        Text(CoreError.message(code: error)).font(.caption).foregroundStyle(Theme.danger).textCase(nil)
      }
      if let announce = sub.meta?.announce, !announce.isEmpty {
        Text(announce).font(.caption).foregroundStyle(Theme.muted).textCase(nil).lineLimit(3)
      }
    }
    .padding(.vertical, 4)
  }

  private func subscriptionInfo(_ sub: CoreSubscription) -> String? {
    var parts: [String] = []
    if let host = sub.host { parts.append(host) }
    parts.append(LF("servers.count", sub.count))
    if let meta = sub.meta {
      let used = (meta.upload ?? 0) + (meta.download ?? 0)
      if let total = meta.total, total > 0 {
        parts.append(LF("servers.traffic", Format.bytes(used), Format.bytes(total)))
      } else if used > 0 {
        parts.append(Format.bytes(used))
      }
      if let expire = meta.expire, expire > 0 {
        parts.append(LF("servers.expires", Format.shortDate(expire)))
      }
    }
    if let updated = Format.relative(sub.updatedAt) { parts.append(updated) }
    return parts.joined(separator: " · ")
  }
}
