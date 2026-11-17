import SwiftUI

/// Geo database (geoip.dat / geosite.dat) used by GEOIP and GEOSITE rules.
struct GeoView: View {
  @EnvironmentObject private var model: AppModel
  @State private var source = "loyalsoldier"
  @State private var ipURL = ""
  @State private var siteURL = ""
  @State private var confirmDelete = false

  private static let presets: [String: (String, String)] = [
    "loyalsoldier": ("https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
                     "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"),
    "runet": ("https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat",
              "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"),
  ]

  var body: some View {
    Form {
      Section {
        row(L("geo.ip"), model.geo?.ip)
        row(L("geo.site"), model.geo?.site)
      } footer: {
        Text(L("geo.explain"))
      }

      Section {
        Picker(L("geo.source"), selection: $source) {
          Text("Loyalsoldier").tag("loyalsoldier")
          Text(L("geo.preset_runet")).tag("runet")
          Text(L("geo.custom")).tag("custom")
        }
        if source == "custom" {
          TextField("geoip.dat URL", text: $ipURL)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
          TextField("geosite.dat URL", text: $siteURL)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        }
      } footer: {
        Text(L("geo.source_footer"))
      }

      Section {
        Button {
          let urls = source == "custom" ? (ipURL, siteURL) : (Self.presets[source] ?? ("", ""))
          Task { await model.updateGeo(ipURL: urls.0, siteURL: urls.1) }
        } label: {
          HStack {
            Label(L("geo.download"), systemImage: "arrow.down.circle")
            Spacer()
            if model.refreshing { ProgressView() }
          }
        }
        .disabled(model.refreshing || (source == "custom" && (ipURL.isEmpty || siteURL.isEmpty)))
        if model.geo?.ip.present == true || model.geo?.site.present == true {
          Button(L("geo.delete"), role: .destructive) { confirmDelete = true }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.space.ignoresSafeArea())
    .navigationTitle(L("geo.title"))
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog(L("geo.delete_confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
      Button(L("geo.delete"), role: .destructive) {
        Task {
          model.geo = try? await Core.call("deleteGeo")
          await model.reload()
        }
      }
    }
    .task {
      await model.loadGeo()
      if let geo = model.geo {
        if let match = Self.presets.first(where: { $0.value.0 == geo.ipUrl }) {
          source = match.key
        } else {
          source = "custom"
          ipURL = geo.ipUrl
          siteURL = geo.siteUrl
        }
      }
    }
  }

  private func row(_ title: String, _ file: GeoFileStatus?) -> some View {
    HStack {
      Text(title)
      Spacer()
      if let f = file, f.present {
        VStack(alignment: .trailing, spacing: 2) {
          Text("\(Format.bytes(f.bytes)) · \(LF("geo.codes", f.codes))").font(.caption)
          if let when = Format.relative(f.updatedAt) { Text(when).font(.caption2).foregroundStyle(.secondary) }
        }
      } else {
        Text(L("geo.absent")).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
