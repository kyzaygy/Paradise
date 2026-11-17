import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Renders text as a QR code image.
enum QRCode {
  static func image(for text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = text.utf8.count > 1200 ? "L" : "M"
    guard let output = filter.outputImage else { return nil }
    let scale = max(1, 900 / output.extent.width)
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cg)
  }
}

/// Full-screen camera scanner sheet.
struct QRScannerSheet: View {
  var onCode: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var denied = false

  init(onCode: @escaping (String) -> Void) {
    self.onCode = onCode
  }

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        if denied {
          VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.white)
            Text(L("scan.denied")).foregroundStyle(.white).multilineTextAlignment(.center)
            Button(L("scan.open_settings")) {
              if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(SecondaryButtonStyle())
            .frame(maxWidth: 260)
          }
          .padding(30)
        } else {
          QRScannerView(onCode: onCode).ignoresSafeArea()
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Theme.accent, lineWidth: 3)
            .frame(width: 250, height: 250)
            .accessibilityHidden(true)
          VStack {
            Spacer()
            Text(L("scan.hint")).font(.subheadline).foregroundStyle(.white).padding(.bottom, 40)
          }
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(L("common.cancel")) { dismiss() }.tint(.white)
        }
      }
      .task {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: denied = false
        case .notDetermined: denied = !(await AVCaptureDevice.requestAccess(for: .video))
        default: denied = true
        }
      }
    }
  }
}

struct QRScannerView: UIViewControllerRepresentable {
  var onCode: (String) -> Void

  func makeUIViewController(context: Context) -> ScannerController {
    let controller = ScannerController()
    controller.onCode = onCode
    return controller
  }

  func updateUIViewController(_ controller: ScannerController, context: Context) {}

  final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .black
      guard let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input) else { return }
      session.addInput(input)
      let output = AVCaptureMetadataOutput()
      guard session.canAddOutput(output) else { return }
      session.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main)
      output.metadataObjectTypes = [.qr]
      let layer = AVCaptureVideoPreviewLayer(session: session)
      layer.videoGravity = .resizeAspectFill
      view.layer.addSublayer(layer)
      preview = layer
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      let session = self.session
      DispatchQueue.global(qos: .userInitiated).async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      let session = self.session
      DispatchQueue.global(qos: .userInitiated).async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
      guard !delivered,
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let value = object.stringValue, !value.isEmpty else { return }
      delivered = true
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      onCode?(value)
    }
  }
}
