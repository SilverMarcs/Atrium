import AVFoundation
import SwiftUI
import VisionKit

struct PairingScannerSheet: View {
    let onScan: (CompanionPairingLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraReady = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("Camera Unavailable", systemImage: "camera", description: Text(error))
                } else if cameraReady {
                    PairingCodeScanner(onScan: onScan, onError: { error = $0 })
                } else {
                    ProgressView("Opening camera…")
                }
            }
            .navigationTitle("Scan Host QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .task {
                guard DataScannerViewController.isSupported else {
                    error = "QR scanning isn’t supported on this device. Paste your host’s pairing link instead."
                    return
                }
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    error = "Allow camera access in Settings to scan your host’s QR code, or paste its pairing link."
                    return
                }
                guard DataScannerViewController.isAvailable else {
                    error = "Camera scanning is currently unavailable. Paste your host’s pairing link instead."
                    return
                }
                cameraReady = true
            }
        }
    }
}
