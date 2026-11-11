import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code for a pairing link, drawn with sharp pixels at any size.
struct PairingQRCodeView: View {
    let url: URL

    var body: some View {
        if let image = Self.image(for: url) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Pairing QR code")
        }
    }

    private static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
