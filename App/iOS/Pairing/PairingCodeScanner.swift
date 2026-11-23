import SwiftUI
import Vision
import VisionKit

struct PairingCodeScanner: UIViewControllerRepresentable {
    let onScan: (PairingLink) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> PairingScannerCoordinator {
        PairingScannerCoordinator(onScan: onScan, onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            recognizesMultipleItems: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.hasScanned else { return }
        do {
            try scanner.startScanning()
        } catch {
            let onError = onError
            Task { @MainActor in onError(error.localizedDescription) }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: PairingScannerCoordinator) {
        scanner.stopScanning()
    }
}
