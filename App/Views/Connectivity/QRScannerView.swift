//
//  QRScannerView.swift
//  ReTripper
//
//  Live AVFoundation camera QR code scanner for motorcycle Tripper Dash pairing.
//  Includes camera permission management, preview layer, and high-contrast reticle.
//

import SwiftUI
import AVFoundation
import AudioToolbox

struct QRScannerView: View {
    let onCodeScanned: (String) -> Void
    @State private var cameraPermission: AVAuthorizationStatus = .notDetermined
    @State private var hasDetectedCode: Bool = false

    var body: some View {
        ZStack {
            if cameraPermission == .authorized {
                CameraPreviewRepresentable { code in
                    guard !hasDetectedCode else { return }
                    hasDetectedCode = true
                    onCodeScanned(code)
                }
                .ignoresSafeArea()

                // High-contrast viewfinder reticle
                VStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.apexRed, lineWidth: 3)
                            .frame(width: 240, height: 240)
                            .background(Color.black.opacity(0.15))

                        VStack(spacing: 8) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 40))
                                .foregroundColor(Theme.apexRed)
                            Text("Align Tripper Dash QR")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                    Spacer()
                }
            } else if cameraPermission == .denied || cameraPermission == .restricted {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.textTertiary)
                    Text("Camera Access Restricted")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Please enable camera access in iOS Settings to scan the dashboard QR code, or paste the payload text below.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(height: 220)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.apexRed)
                    Text("Requesting camera access...")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(height: 220)
            }
        }
        .onAppear {
            checkCameraPermission()
        }
    }

    private func checkCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        self.cameraPermission = status
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraPermission = granted ? .authorized : .denied
                }
            }
        }
    }
}

// MARK: - UIKit Camera Preview Representable
struct CameraPreviewRepresentable: UIViewControllerRepresentable {
    let onCodeFound: (String) -> Void

    func makeUIViewController(context: Context) -> CameraScannerViewController {
        let controller = CameraScannerViewController()
        controller.onCodeFound = onCodeFound
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraScannerViewController, context: Context) {}
}

class CameraScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeFound: ((String) -> Void)?
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCaptureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func setupCaptureSession() {
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
        guard let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else { return }

        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            return
        }

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        self.previewLayer = layer
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           metadataObject.type == .qr,
           let stringValue = metadataObject.stringValue {
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            onCodeFound?(stringValue)
        }
    }
}
