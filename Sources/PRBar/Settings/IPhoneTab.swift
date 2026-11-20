import AppKit
import PRBarCore
import PRBarRemoteKit
import PRBarRemoteMac
import SwiftUI

/// Settings › iPhone (spec Q.2): cómo conseguir la app del iPhone, el acceso remoto, los iPhones emparejados y sus
/// ajustes. Cada control llama al mismo método que `prbar remote …`.
struct IPhoneTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var remote: RemoteAccessService

    @State private var sheet: IPhoneSheet?
    @State private var error: String?
    @State private var busy = false

    private var settings: RemoteSettings { configStore.config.remote }

    var body: some View {
        Form {
            installSection
            accessSection
            if settings.enabled || !remote.devices.isEmpty { devicesSection }
            optionsSection
        }
        .formStyle(.grouped)
        .sheet(item: $sheet) { which in
            switch which {
            case .enable:
                EnableRemoteSheet(model: model, initialHost: settings.relayHost ?? RemoteSettings.defaultRelayHost) {
                    sheet = nil
                }
            case .pair:
                PairIPhoneSheet(model: model, remote: remote, startsPairing: true) { sheet = nil }
            }
        }
    }

    // MARK: Get PRBar for iPhone

    /// El QR de instalación es público y permanente: nunca se muestra en la misma vista que el de emparejamiento
    /// (secreto y efímero), así que con la hoja de emparejar abierta queda oculto.
    private var installSection: some View {
        Section {
            if let url = settings.appInstallURL {
                HStack(alignment: .top, spacing: 16) {
                    if sheet == .pair {
                        Label("Hidden while pairing", systemImage: "qrcode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, height: 120)
                    } else {
                        QRCodeView(text: url.absoluteString)
                            .frame(width: 120, height: 120)
                            .accessibilityLabel("QR code to install PRBar for iPhone")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with the iPhone’s Camera to install PRBar for iPhone.")
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        HStack {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                            Button("Open Link") { NSWorkspace.shared.open(url) }
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                Label {
                    Text("The iPhone app isn’t on TestFlight yet — install it from Xcode (see docs/iphone.md).")
                } icon: {
                    Image(systemName: "iphone.badge.play")
                }
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Get PRBar for iPhone")
        } footer: {
            Text("See your PRs, get notifications and review, respond, fix CI and merge from your iPhone. This Mac does the work; the iPhone is a remote control.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Remote control

    private var accessSection: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.enabled }, set: setEnabled)) {
                Text("Allow iPhone remote control")
                Text("PRBar connects out to your relay server; no ports are opened on this Mac.")
            }
            .toggleStyle(.switch)
            .disabled(busy)
            HStack {
                statusLabel
                Spacer()
                Button("Pair iPhone…") { sheet = .pair }
                    .disabled(remote.state != .connected)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.redText)
            }
        } header: {
            Text("Remote Control")
        } footer: {
            Text("Everything between this Mac and your iPhones is end-to-end encrypted: the relay only sees encrypted data, ids and timing. Merge, push and approve need Face ID on the iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        let host = settings.relayHost ?? "the relay"
        switch remote.state {
        case .disabled:
            Label("Disabled", systemImage: "iphone.slash").foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting to \(host)…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .connected:
            let online = remote.online.count
            Label("Connected to \(host) · \(online) iPhone\(online == 1 ? "" : "s") online", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.greenText)
        case .offline(let retryAt, _):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = retryAt.map { max(0, Int($0.timeIntervalSince(context.date).rounded())) }
                Label(seconds.map { "Offline — retrying in \($0) s" } ?? "Offline", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(Theme.orangeText)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.redText)
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        Section {
            if remote.devices.isEmpty {
                Text("No paired iPhones yet. Choose Pair iPhone… and scan the code with your iPhone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(remote.devices, id: \.device.deviceId) { stored in
                deviceRow(stored)
            }
        } header: {
            Text("iPhones")
        }
    }

    private func deviceRow(_ stored: StoredDevice) -> some View {
        let device = stored.device
        let online = remote.online.contains(device.deviceId)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(online ? Theme.greenText : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(detail(stored, online: online, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if stored.notificationsOff {
                    Label("Notifications off — open PRBar on the iPhone to turn them back on", systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(Theme.orangeText)
                }
            }
            Spacer()
            Toggle("Require Face ID", isOn: Binding(
                get: { device.requirePresence },
                set: { enabled in run { _ = try await model.remoteSetPresenceRequirement(device: device.deviceId, enabled: enabled) } }
            ))
            .toggleStyle(.checkbox)
            .help("Merge, push and approve need Face ID on this iPhone.")
            Button("Revoke…") { confirmRevoke(device) }
        }
    }

    private func detail(_ stored: StoredDevice, online: Bool, now: Date) -> String {
        let paired = "Paired \(stored.device.pairedAt.formatted(.dateTime.month(.abbreviated).day()))"
        let seen = online ? "Online" : stored.lastSeen.map { "Last seen \(RelativeAge.short(from: $0, now: now)) ago" } ?? "Not seen yet"
        return "\(stored.device.model) · \(paired) · \(seen)"
    }

    // MARK: Options

    private var optionsSection: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.keepAwakeWhileCharging }, set: { on in
                run { _ = try model.remoteSetKeepAwake(enabled: on) }
            })) {
                Text("Keep this Mac awake while charging")
                Text("So your iPhone can reach it. The display still sleeps; with the lid closed and no external display, macOS sleeps anyway.")
            }
            .toggleStyle(.switch)
            Toggle(isOn: Binding(get: { settings.mailboxEnabled }, set: { on in
                run { _ = try await model.remoteSetMailbox(enabled: on) }
            })) {
                Text("Keep the last state on the relay for 7 days")
                Text("Encrypted for your iPhones only, so they show recent PRs while this Mac sleeps.")
            }
            .toggleStyle(.switch)
            HStack {
                Spacer()
                Button("Reset iPhone Access…", role: .destructive) { confirmReset() }
                    .disabled(settings.accountId == nil && remote.devices.isEmpty)
            }
        } header: {
            Text("Options")
        }
    }

    // MARK: Actions

    private func setEnabled(_ on: Bool) {
        if on {
            if settings.accountId != nil, let host = settings.relayHost {
                // Ya hay cuenta: volver a habilitar no pide el token.
                run { _ = try await model.remoteEnable(relay: host, enrollToken: "") }
            } else {
                sheet = .enable
            }
        } else {
            run { _ = try await model.remoteDisable() }
        }
    }

    private func confirmRevoke(_ device: PairedDevice) {
        ConfirmAlert.present(
            title: "Revoke \(device.name)?",
            message: "It stops working right away, even if the relay doesn’t cooperate, and has to be paired again.",
            action: "Revoke"
        ) {
            run { _ = try await model.remoteRevoke(device: device.deviceId) }
        }
    }

    private func confirmReset() {
        ConfirmAlert.present(
            title: "Reset iPhone access?",
            message: "Every paired iPhone stops working, this Mac gets new keys and a new relay account. Use it if the relay or this Mac may be compromised. You’ll need the enrollment token again.",
            action: "Reset"
        ) {
            run { _ = try await model.remoteReset() }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

enum IPhoneSheet: String, Identifiable {
    case enable, pair
    var id: String { rawValue }
}

/// Un QR dibujado módulo por módulo (nítido a cualquier tamaño), negro sobre blanco con zona silenciosa de 4.
struct QRCodeView: View {
    let text: String

    var body: some View {
        let matrix = QRCodeMatrix.make(text) ?? []
        Canvas { context, size in
            let count = matrix.count + 8
            guard count > 8 else { return }
            let module = min(size.width, size.height) / CGFloat(count)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for (y, row) in matrix.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    let rect = CGRect(x: CGFloat(x + 4) * module, y: CGFloat(y + 4) * module, width: module, height: module)
                    context.fill(Path(rect.insetBy(dx: -0.25, dy: -0.25)), with: .color(.black))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
