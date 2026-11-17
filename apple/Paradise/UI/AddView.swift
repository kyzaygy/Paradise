import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AddView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var scanning = false
  @State private var importingFile = false
  @State private var working = false
  @FocusState private var focused: Bool

  init() {}

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(L("add.hint")).font(.subheadline).foregroundStyle(Theme.muted)
          ZStack(alignment: .topLeading) {
            if text.isEmpty {
              Text(L("add.placeholder")).foregroundStyle(Theme.muted.opacity(0.7)).padding(.top, 8).padding(.leading, 5)
            }
            TextEditor(text: $text)
              .font(Theme.mono)
              .focused($focused)
              .frame(minHeight: 120, maxHeight: 220)
              .scrollContentBackground(.hidden)
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)
          }
          .padding(10)
          .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))

          HStack(spacing: 10) {
            quickButton(L("add.paste"), "doc.on.clipboard") {
              if let s = UIPasteboard.general.string, !s.isEmpty { text = s } else { model.info(L("add.clipboard_empty")) }
            }
            quickButton(L("add.scan"), "qrcode.viewfinder") { scanning = true }
            quickButton(L("add.file"), "folder") { importingFile = true }
          }

          Button {
            Task { await submit(text) }
          } label: {
            if working { ProgressView().tint(Theme.onAccent) } else { Text(L("add.submit")) }
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)

          Text(L("add.formats")).font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(20)
      }
      .background(Theme.canvas)
      .navigationTitle(L("add.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) { Button(L("common.cancel")) { dismiss() } }
      }
      .sheet(isPresented: $scanning) {
        QRScannerSheet { value in
          scanning = false
          Task { await submit(value) }
        }
      }
      .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data, .text, .json], allowsMultipleSelection: false) { result in
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), data.count < 12 << 20, let s = String(data: data, encoding: .utf8) {
          Task { await submit(s) }
        } else {
          model.show(CoreError(code: "unsupported_format", detail: nil))
        }
      }
    }
  }

  private func quickButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: icon).font(.title3)
        Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, minHeight: 64)
      .foregroundStyle(Theme.accent)
      .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private func submit(_ value: String) async {
    working = true
    defer { working = false }
    let wasTransfer = (try? await Core.call("classify", ["text": value], as: Classification.self))?.kind == "transfer"
    if wasTransfer {
      dismiss()
      try? await Task.sleep(nanoseconds: 350_000_000)
      model.sheet = .preview(value)
      return
    }
    if await model.importInput(value) { dismiss() }
  }
}
