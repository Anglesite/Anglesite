import SwiftUI
import AVFoundation

/// Live camera QR scanner for pairing onboarding (#1431). Pure capture: every decoded string is
/// forwarded to `onCode` on the main queue; deciding whether it's a pairing code (and ignoring
/// frames after the first accepted one) is `PairingOnboardingModel`'s job. Camera *permission*
/// is also not requested here — `beginScan()` already secured it before this view is shown.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.onCode = onCode
    }

    /// Owns the `AVCaptureSession`. A view controller (not a bare `UIView`) so session start/stop
    /// rides the appearance callbacks — backgrounding the app mid-scan tears the camera down.
    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?

        private let session = AVCaptureSession()
        // Session start/stop must stay off the main thread (it blocks); one serial queue also
        // orders every start against every stop.
        private let sessionQueue = DispatchQueue(label: "io.dwk.anglesite.qr-scanner")
        private var previewLayer: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input)
            else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            previewLayer = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            for object in metadataObjects {
                guard let readable = object as? AVMetadataMachineReadableCodeObject,
                      readable.type == .qr,
                      let string = readable.stringValue
                else { continue }
                onCode?(string)
            }
        }
    }
}
