import PRBarCore
import PRBarRemoteMac
import SwiftUI

/// "Pair iPhone…" (spec Q.2 y P.11): el QR de emparejamiento (secreto, vence a los 5 min), y cuando el teléfono se une,
/// el código de 6 dígitos para comparar con "Codes Match" / "Cancel". Lo mismo que `prbar remote pair`.
struct PairIPhoneSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var remote: RemoteAccessService
    /// `false` en el modo de capturas: muestra lo que haya en `remote.pairing` sin abrir una ranura.
    let startsPairing: Bool
    let close: () -> Void

    @State private var error: String?
    @State private var working = false
    @State private var started = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair iPhone").font(.headline)
            if let pairing = remote.pairing, let code = pairing.code {
                joined(pairing, code: code)
            } else if let pairing = remote.pairing {
                waiting(pairing)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.redText)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                if remote.pairing?.code != nil {
                    Button("Codes Match") { confirm() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: remote.pairing?.pairing) { old, new in
            // Venció, se canceló desde la CLI o se abrió otra ranura: la hoja lo dice (no se queda esperando).
            if old != nil, new == nil, !working { error = "This code expired or was canceled. Close and start again." }
        }
        .task {
            guard startsPairing, !started else { return }
            started = true
            do {
                _ = try await model.remotePairStart()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func waiting(_ pairing: RemotePairingInfo) -> some View {
        VStack(spacing: 12) {
            QRCodeView(text: pairing.qr)
                .frame(width: 220, height: 220)
                .accessibilityLabel("Pairing QR code")
            Text("Scan this with PRBar on your phone (Pair › Scan).")
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(pairing.expiresAt.timeIntervalSince(context.date).rounded()))
                Text("Expires in \(seconds / 60):\(String(format: "%02d", seconds % 60)) · works once")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func joined(_ pairing: RemotePairingInfo, code: String) -> some View {
        VStack(spacing: 10) {
            Text(code)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Code \(code)")
            Text("\(pairing.deviceName ?? "An iPhone") (\(pairing.model ?? "iPhone"))")
            Text("Check that your iPhone shows the same code. If it doesn’t, cancel: someone else may have scanned the QR.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.redText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func confirm() {
        guard let pairing = remote.pairing else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                _ = try await model.remotePairConfirm(pairing: pairing.pairing, accepted: true)
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func cancel() {
        guard startsPairing, let pairing = remote.pairing else { return close() }
        Task { @MainActor in
            _ = try? await model.remotePairConfirm(pairing: pairing.pairing, accepted: false)
            close()
        }
    }
}
