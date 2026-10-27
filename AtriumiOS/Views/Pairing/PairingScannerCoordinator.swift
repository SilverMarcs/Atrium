import VisionKit

@MainActor
final class PairingScannerCoordinator: NSObject, DataScannerViewControllerDelegate {
    private let onScan: (CompanionPairingLink) -> Void
    private let onError: (String) -> Void
    private(set) var hasScanned = false

    init(onScan: @escaping (CompanionPairingLink) -> Void, onError: @escaping (String) -> Void) {
        self.onScan = onScan
        self.onError = onError
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            guard !hasScanned, case .barcode(let barcode) = item,
                  let value = barcode.payloadStringValue,
                  let url = URL(string: value),
                  let link = CompanionPairingLink(url: url) else { continue }
            hasScanned = true
            dataScanner.stopScanning()
            onScan(link)
            return
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        dataScanner.stopScanning()
        onError("Camera scanning is currently unavailable. Paste your host’s pairing link instead.")
    }
}
