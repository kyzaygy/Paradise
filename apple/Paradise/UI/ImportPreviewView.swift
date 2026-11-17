import SwiftUI

/// Shows what a transfer code contains before anything is imported.
struct ImportPreviewView: View {
  let code: String
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  @State private var preview: TransferPreview?
  @State private var error: CoreError?
  @State private var password = ""
  @State private var unlocking = false
  @State private var importing = false
  @State private var replace = false
  @State private var applySettings = true
  @State private var applyIdentity = false
  @State private var confirmReplace = false

  init(code: String) {
    self.code = code
  }

  var body: some View {
    NavigationStack {
      Group {
        if let preview = preview, !preview.locked {
          content(preview)
        } else if preview?.locked == true {
          locked
        } else if let error = error {
          failure(error)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(Theme.canvas)
      .navigationTitle(L("preview.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) { Button(L("common.cancel")) { dismiss() } }
      }
    }
    .task { await load(password: "") }
  }

  private func load(password: String) async {
    do {
      let p = try await model.preview(code: code, password: password)
      preview = p
      error = nil
    } catch let e as CoreError {
      if e.code == "transfer_password_wrong" && preview?.locked == true {
        self.error = e
      } else {
        preview = nil
        self.error = e
      }
    } catch {
      preview = nil
      self.error = CoreError(code: "internal", detail: nil)
    }
  }

  private var locked: some View {
    Form {
      Section {
        Label(L("preview.locked"), systemImage: "lock.fill").font(Theme.label(.headline))
        if let exp = preview?.expiresAt, exp > 0 {
          Text(LF("preview.expires", Format.date(exp))).font(.footnote).foregroundStyle(Theme.muted)
        }
        SecureField(L("preview.password"), text: $password)
          .textContentType(.password)
          .submitLabel(.go)
          .onSubmit { Task { await unlock() } }
        if let error = error {
          Text(error.errorDescription ?? "").font(.footnote).foregroundStyle(Theme.danger)
        }
      }
      Section {
        Button { Task { await unlock() } } label: {
          if unlocking { ProgressView().tint(Theme.onAccent) } else { Text(L("preview.unlock")) }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(password.isEmpty || unlocking)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      }
    }
    .scrollContentBackground(.hidden)
  }

  private func unlock() async {
    unlocking = true
    defer { unlocking = false }
    await load(password: password)
  }

  private func failure(_ error: CoreError) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.danger)
      Text(error.errorDescription ?? "").font(.headline).multilineTextAlignment(.center)
      Text(L("preview.failure_hint")).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
      Button(L("common.close")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).frame(maxWidth: 240)
    }
    .padding(30)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func content(_ p: TransferPreview) -> some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text(p.name?.isEmpty == false ? p.name! : L("preview.unnamed")).font(Theme.title(.title3))
          Text(LF("preview.counts", p.counts.subscriptions, p.counts.servers, p.counts.favorites))
            .font(.subheadline).foregroundStyle(Theme.muted)
          HStack(spacing: 10) {
            tag(p.format == "svoi1" ? "SVOI" : "Paradise", "shippingbox")
            if p.encrypted { tag(L("preview.encrypted"), "lock.fill") }
            if let exp = p.expiresAt, exp > 0 { tag(LF("preview.until", Format.shortDate(exp)), "clock") }
          }
        }
        .padding(.vertical, 4)
      }

      Section(L("preview.sources")) {
        ForEach(Array(p.sources.enumerated()), id: \.offset) { _, s in
          HStack {
            Image(systemName: s.remote ? "link" : "server.rack").foregroundStyle(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
              Text(s.name.isEmpty ? (s.host ?? L("subscription.local")) : s.name).lineLimit(1)
              Text(s.remote ? (s.host ?? "") : LF("servers.count", s.servers)).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            if s.duplicate {
              Text(L("preview.duplicate")).font(.caption.weight(.semibold)).foregroundStyle(Theme.warning)
            }
          }
        }
        if p.skipped > 0 {
          Label(LF("preview.skipped", p.skipped), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning)
        }
      }

      Section {
        Picker(L("preview.strategy"), selection: $replace) {
          Text(L("preview.merge")).tag(false)
          Text(L("preview.replace")).tag(true)
        }
        .pickerStyle(.segmented)
        if p.hasSettings { Toggle(L("preview.apply_settings"), isOn: $applySettings) }
        if p.hasIdentity { Toggle(L("preview.apply_identity"), isOn: $applyIdentity) }
      } footer: {
        Text(replace ? L("preview.replace_footer") : (p.duplicates > 0 ? LF("preview.merge_footer_dups", p.duplicates) : L("preview.merge_footer")))
      }

      Section {
        Button {
          if replace { confirmReplace = true } else { Task { await doImport() } }
        } label: {
          if importing { ProgressView().tint(Theme.onAccent) } else { Text(L("preview.import")) }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(importing)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      }
    }
    .scrollContentBackground(.hidden)
    .confirmationDialog(L("preview.replace_confirm"), isPresented: $confirmReplace, titleVisibility: .visible) {
      Button(L("preview.replace"), role: .destructive) { Task { await doImport() } }
    }
  }

  private func tag(_ text: String, _ icon: String) -> some View {
    Label(text, systemImage: icon)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(Theme.accentSoft, in: Capsule())
      .foregroundStyle(Theme.accent)
  }

  private func doImport() async {
    importing = true
    defer { importing = false }
    do {
      try await model.importTransfer(code: code, password: password, replace: replace,
                                     applySettings: applySettings && (preview?.hasSettings ?? false),
                                     applyIdentity: applyIdentity && (preview?.hasIdentity ?? false))
      dismiss()
    } catch {
      model.show(error)
    }
  }
}
