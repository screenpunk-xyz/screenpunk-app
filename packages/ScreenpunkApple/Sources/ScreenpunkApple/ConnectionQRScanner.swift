#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Captures QR text locally. No network request or credential persistence occurs here.
public struct ConnectionQRScanner: UIViewControllerRepresentable {
    private let onResult: (String) -> Void
    private let onFailure: () -> Void
    public init(onResult: @escaping (String) -> Void, onFailure: @escaping () -> Void) { self.onResult = onResult; self.onFailure = onFailure }
    public func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(onResult: onResult, onFailure: onFailure)
    }
    public func updateUIViewController(_ controller: ScannerController, context: Context) {}
    public static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }

    public final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "screenpunk.qr-camera")
        private var preview: AVCaptureVideoPreviewLayer?
        private var finished = false
        private let onResult: (String) -> Void
        private let onFailure: () -> Void
        init(onResult: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
            self.onResult = onResult; self.onFailure = onFailure
            super.init(nibName: nil, bundle: nil)
        }
        required public init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override public func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .black
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); preview = layer
            queue.async { [self] in
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                    DispatchQueue.main.async { self.onFailure() }; return
                }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { DispatchQueue.main.async { self.onFailure() }; return }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                session.startRunning()
                DispatchQueue.main.async { self.updatePreviewOrientation() }
            }
        }
        override public func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews(); preview?.frame = view.bounds
            updatePreviewOrientation()
        }
        override public func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updatePreviewOrientation()
        }
        override public func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: { _ in self.updatePreviewOrientation() }, completion: { _ in self.updatePreviewOrientation() })
        }
        private func updatePreviewOrientation() {
            guard let orientation = view.window?.windowScene?.interfaceOrientation,
                  let connection = preview?.connection, connection.isVideoOrientationSupported else { return }
            // UIKit and AVFoundation assign different raw values to landscape orientations.
            // The preview connection is created asynchronously, so also apply after startup.
            switch orientation {
            case .portrait: connection.videoOrientation = .portrait
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            default: break
            }
        }
        func stop() { queue.async { [self] in session.stopRunning() } }
        public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !finished, let text = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            finished = true; stop(); onResult(text)
        }
    }
}
#endif
