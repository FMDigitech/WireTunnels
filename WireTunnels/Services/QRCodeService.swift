import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Encodes/decodes WireGuard config text as a QR code, entirely via CoreImage —
/// no third-party dependency needed for either direction.
enum QRCodeService {
    private static let context = CIContext()

    static func generate(from text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        // The raw filter output is only a few dozen pixels per side — scale up
        // with nearest-neighbor sampling so the modules stay crisp.
        let scale: CGFloat = 10
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
    }

    static func decode(from image: NSImage) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let ciImage = CIImage(data: tiffData)
        else { return nil }

        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) ?? []
        for case let feature as CIQRCodeFeature in features {
            if let message = feature.messageString, !message.isEmpty {
                return message
            }
        }
        return nil
    }
}
