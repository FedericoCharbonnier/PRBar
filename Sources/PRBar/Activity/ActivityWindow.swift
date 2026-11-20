import AppKit
import PRBarCore
import SwiftUI

/// Provisorio: la ventana PRBar Activity llega en la Task 10.
struct ActivityWindow: View {
    static let size = NSSize(width: 720, height: 560)
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: ResourceMonitor
    var body: some View { Text("Activity") }
}
