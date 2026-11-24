//
//  DashTextScannerView.swift
//  ReTripper
//
//  Reads the Tripper Dash Wi-Fi network name with the camera (Apple Live Text / VisionKit).
//  The dash shows its network name as text (e.g. "RE_MVWW_260317") after the joystick is
//  held for 3 seconds; it does not show a QR code. A standard Wi-Fi QR code is also accepted.
//  Recognition runs on the device; nothing is uploaded.
//

import SwiftUI
import VisionKit
import AudioToolbox

/// What the camera found.
enum DashScanResult: Equatable {
    case networkName(String)
    case wifiQR(ssid: String, password: String?)
}

struct DashTextScannerView: View {
    let onFound: (DashScanResult) -> Void

    var body: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            DataScannerRepresentable(onFound: onFound)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Theme.textTertiary)
                Text("Camera text scanning isn't available")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(DataScannerViewController.isSupported
                     ? "Allow camera access for ReTripper in iPhone Settings, or type the name shown on the dash in 'Enter Name'."
                     : "This iPhone can't read text with the camera. Type the name shown on the dash in 'Enter Name'.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onFound: (DashScanResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text(), .barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning && !context.coordinator.finished {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (DashScanResult) -> Void
        var finished = false

        init(onFound: @escaping (DashScanResult) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            inspect(allItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            inspect(allItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            inspect([item], scanner: dataScanner)
        }

        private func inspect(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !finished else { return }
            for item in items {
                switch item {
                case .barcode(let code):
                    if let payload = code.payloadStringValue,
                       let wifi = DashboardPairingText.parseWiFiPayload(payload) {
                        finish(.wifiQR(ssid: wifi.ssid, password: wifi.password), scanner: scanner)
                        return
                    }
                case .text(let text):
                    if let name = DashboardPairingText.extractSSID(from: text.transcript) {
                        finish(.networkName(name), scanner: scanner)
                        return
                    }
                @unknown default:
                    continue
                }
            }
        }

        private func finish(_ result: DashScanResult, scanner: DataScannerViewController) {
            finished = true
            scanner.stopScanning()
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            onFound(result)
        }
    }
}
