import PRBarCore
import SwiftUI

/// "Allow iPhone remote control" la primera vez (spec Q.2): el relay y su token de inscripción, que se usa una vez y no
/// se guarda (como `prbar remote enable`).
struct EnableRemoteSheet: View {
    @ObservedObject var model: AppModel
    let initialHost: String
    let close: () -> Void

    @State private var host = ""
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    private var hostOK: Bool { RemoteSettings.normalizedRelayHost(host) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow iPhone Remote Control").font(.headline)
            Text("PRBar creates this Mac’s account on your relay server. The relay only accepts new Macs with its enrollment token; PRBar uses it once and doesn’t keep it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Relay server", text: $host, prompt: Text(RemoteSettings.defaultRelayHost))
                SecureField("Enrollment token", text: $token, prompt: Text("From the relay’s .env (RELAY_ENROLL_TOKEN)"))
            }
            .formStyle(.columns)
            Group {
                if !host.isEmpty, !hostOK {
                    Text("Use the relay’s host name, like \(RemoteSettings.defaultRelayHost) (https only).")
                } else if let error {
                    Text(error)
                } else {
                    Text("The relay never sees your PRs or code: everything is end-to-end encrypted.")
                }
            }
            .font(.caption)
            .foregroundStyle(error == nil && (host.isEmpty || hostOK) ? Color.secondary : Theme.redText)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Enable") { enable() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !hostOK || token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if host.isEmpty { host = initialHost } }
    }

    private func enable() {
        error = nil
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                _ = try await model.remoteEnable(relay: host, enrollToken: token)
                token = ""
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
