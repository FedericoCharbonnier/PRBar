import SwiftUI

#if os(iOS) && canImport(VisionKit)
import VisionKit

/// The live camera for `pair:scan`: VisionKit's data scanner reading QR codes only.
struct CameraLayer: UIViewControllerRepresentable {
    let scanned: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            let fallback = UIViewController()
            fallback.view.backgroundColor = .black
            return fallback
        }
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: false,
                                                isGuidanceEnabled: false, isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.scanned = scanned
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        (controller as? DataScannerViewController)?.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var scanned: (String) -> Void
        private var last: String?

        init(scanned: @escaping (String) -> Void) {
            self.scanned = scanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue, text != last {
                    last = text
                    scanned(text)
                }
            }
        }
    }
}
#else
/// No camera outside iPhone (snapshots): a dark backdrop.
struct CameraLayer: View {
    let scanned: (String) -> Void
    var body: some View {
        LinearGradient(colors: [Color(white: 0.18), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
    }
}
#endif
