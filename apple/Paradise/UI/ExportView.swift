import SwiftUI
import UIKit

/// "Share profile": choose what to include, protect with a password and expiry, then share as QR, link, text or file.
struct ExportView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  enum Scope: String, CaseIterable { case subscriptions, favorites, everything }
  enum Expiry: Int, CaseIterable { case never = 0, hour = 1, day = 24, week = 168 }

  @State private var scope: Scope = .favorites
  @State private var compatible = false
  @State private var ownDevice = false
  @State private var usePassword = false
  @State private var password = ""
  @State private var expiry: Expiry = .day
  @State private var working = false
  @State private var result: ExportResult?
  @State private var fileURL: URL?

  init() {}

  var body: some View {
    NavigationStack {
      Group {
        if let result = result {
          ExportResultView(result: result, fileURL: fileURL) { self.result = nil }
        } else {
          form
        }
      }
      .background(Theme.canvas)
      .navigationTitle(L("export.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button(L("common.done")) { dismiss() } }
      }
    }
  }

  private var form: some View {
    Form {
      Section {
        Picker(L("export.scope"), selection: $scope) {
          Text(L("export.scope.subscriptions")).tag(Scope.subscriptions)
          Text(L("export.scope.favorites")).tag(Scope.favorites)
          Text(L("export.scope.everything")).tag(Scope.everything)
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text(L("export.scope"))
      } footer: {
        Text(LF("export.summary", model.state.subscriptions.count, model.state.servers.count))
      }

      if !compatible {
        Section {
          Toggle(L("export.password"), isOn: $usePassword.animation())
          if usePassword {
            SecureField(L("export.password_placeholder"), text: $password)
              .textContentType(.newPassword)
          }
          Picker(L("export.expiry"), selection: $expiry) {
            Text(L("export.expiry.never")).tag(Expiry.never)
            Text(L("export.expiry.hour")).tag(Expiry.hour)
            Text(L("export.expiry.day")).tag(Expiry.day)
            Text(L("export.expiry.week")).tag(Expiry.week)
          }
        } header: {
          Text(L("export.protection"))
        } footer: {
          Text(usePassword ? L("export.password_footer") : L("export.expiry_footer"))
        }
      }

      Section {
        Toggle(L("export.own_device"), isOn: $ownDevice)
        Toggle(L("export.compatible"), isOn: $compatible.animation())
      } footer: {
        Text(compatible ? L("export.compatible_footer") : L("export.own_device_footer"))
      }

      Section {
        Button {
          Task { await generate() }
        } label: {
          if working { ProgressView().tint(Theme.onAccent) } else { Text(L("export.create")) }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(working || model.state.subscriptions.isEmpty || (usePassword && !compatible && password.count < 4))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      } footer: {
        Label(L("export.secret_warning"), systemImage: "lock.trianglebadge.exclamationmark")
          .font(.footnote)
          .foregroundStyle(Theme.warning)
          .padding(.top, 8)
      }
    }
    .scrollContentBackground(.hidden)
  }

  private func generate() async {
    working = true
    defer { working = false }
    var options: [String: Any] = [
      "format": compatible ? "svoi1" : "pd1",
      "includeFavorites": scope != .subscriptions,
      "includeSettings": scope == .everything,
      "includeIdentity": ownDevice,
    ]
    if !compatible {
      options["password"] = usePassword ? password : ""
      options["expiresInHours"] = expiry.rawValue
    }
    do {
      let r = try await model.export(options)
      fileURL = writeFile(r.code)
      result = r
    } catch {
      model.show(error)
    }
  }

  private func writeFile(_ code: String) -> URL? {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ext = code.hasPrefix("SVOI1.") ? "svoi" : "paradise"
    let url = dir.appendingPathComponent("Paradise-profile.\(ext)")
    do {
      try Data(code.utf8).write(to: url, options: [.atomic, .completeFileProtection])
      return url
    } catch {
      return nil
    }
  }
}

struct ExportResultView: View {
  let result: ExportResult
  let fileURL: URL?
  var back: () -> Void
  @State private var copied = ""

  init(result: ExportResult, fileURL: URL?, back: @escaping () -> Void) {
    self.result = result
    self.fileURL = fileURL
    self.back = back
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        if result.fitsQr, let image = QRCode.image(for: result.link) {
          Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 280)
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityLabel(L("export.qr_a11y"))
        } else {
          Card {
            Label(L("export.qr_too_big"), systemImage: "qrcode").font(.subheadline).foregroundStyle(Theme.muted)
          }
        }

        Card {
          VStack(alignment: .leading, spacing: 6) {
            Text(LF("export.contains", result.counts.subscriptions, result.counts.servers, result.counts.favorites))
              .font(.subheadline)
            if result.encrypted { Label(L("export.encrypted"), systemImage: "lock.fill").font(.caption).foregroundStyle(Theme.accent) }
            if let exp = result.expiresAt, exp > 0 {
              Label(LF("export.expires_at", Format.date(exp)), systemImage: "clock").font(.caption).foregroundStyle(Theme.muted)
            }
            if result.skipped > 0 {
              Label(LF("export.skipped", result.skipped), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
            }
          }
        }

        VStack(spacing: 10) {
          if let url = fileURL {
            ShareLink(item: url, subject: Text("Paradise"), message: Text(L("export.share_message"))) {
              Label(L("export.share_file"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
          }
          HStack(spacing: 10) {
            Button { copy(result.link, tag: "link") } label: {
              Label(copied == "link" ? L("common.copied") : L("export.copy_link"), systemImage: "link")
            }
            Button { copy(result.code, tag: "code") } label: {
              Label(copied == "code" ? L("common.copied") : L("export.copy_code"), systemImage: "doc.on.doc")
            }
          }
          .buttonStyle(SecondaryButtonStyle())
          Button(L("export.again"), action: back).font(.subheadline).padding(.top, 4)
        }

        Label(L("export.secret_warning"), systemImage: "lock.trianglebadge.exclamationmark")
          .font(.footnote)
          .foregroundStyle(Theme.warning)
      }
      .padding(20)
    }
  }

  private func copy(_ text: String, tag: String) {
    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.expirationDate: Date().addingTimeInterval(600), .localOnly: true])
    copied = tag
  }
}
