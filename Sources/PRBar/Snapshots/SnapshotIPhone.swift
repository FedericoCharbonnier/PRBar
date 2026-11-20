import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit
import PRBarRemoteMac

/// Settings › iPhone en el modo de capturas: estados ficticios, sin relay ni llavero (spec Q.2).
extension SnapshotFixtures {
    enum IPhoneState {
        case off, offWithLink, connected, pairingQR, pairingCode
    }

    static let iphoneInstallURL = URL(string: "https://testflight.apple.com/join/PrBar2026")!
    /// Un link de emparejamiento con la forma real pero datos inventados (no sirve para nada).
    static let iphonePairingURL = "prbar://pair?v=1&r=prbar.example.com&a=k7q2mzx4w9tcv3hb5nfy6pgd8e&p=r4t6y8u2i3o5p7a9&k=c25hcHNob3Qtb25seS1ub3QtYS1yZWFsLXNlY3JldA&m=c25hcHNob3Qtb25seS1ub3QtYS1yZWFsLWtleS0&n=Federico%E2%80%99s%20MacBook%20Pro"

    static func iphoneDevice(_ id: String, name: String, model: String, pairedDaysAgo: Double,
                             requirePresence: Bool = true) -> PairedDevice {
        PairedDevice(deviceId: id, name: name, model: model,
                     noise: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                     push: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                     presence: P256.Signing.PrivateKey().publicKey.x963Representation,
                     pairedAt: Date().addingTimeInterval(-pairedDaysAgo * 86_400), requirePresence: requirePresence)
    }

    @MainActor
    static func applyIPhone(_ model: AppModel, _ state: IPhoneState) throws {
        let enabled = state != .off && state != .offWithLink
        try model.configStore.update {
            $0.remote = RemoteSettings(enabled: enabled, relayHost: enabled ? RemoteSettings.defaultRelayHost : nil,
                                       accountId: enabled ? "k7q2mzx4w9tcv3hb5nfy6pgd8e" : nil,
                                       keepAwakeWhileCharging: enabled, mailboxEnabled: true,
                                       appInstallURL: state == .off ? nil : iphoneInstallURL)
        }
        let phone = iphoneDevice("m3n5b7v9c2x4z6l8k0j2h4g6f8", name: "Federico’s iPhone", model: "iPhone 17 Pro", pairedDaysAgo: 3)
        let work = iphoneDevice("q1w3e5r7t9y2u4i6o8p0a2s4d6", name: "Work iPhone", model: "iPhone 16", pairedDaysAgo: 12,
                                requirePresence: false)
        let devices = enabled
            ? [StoredDevice(device: phone, lastSeen: Date()),
               StoredDevice(device: work, lastSeen: Date().addingTimeInterval(-5 * 60))]
            : []
        let pairing: RemotePairingInfo? = switch state {
        case .pairingQR:
            RemotePairingInfo(pairing: "r4t6y8u2i3o5p7a9", qr: iphonePairingURL, expiresAt: Date().addingTimeInterval(272))
        case .pairingCode:
            RemotePairingInfo(pairing: "r4t6y8u2i3o5p7a9", qr: iphonePairingURL, expiresAt: Date().addingTimeInterval(240),
                              code: "482 913", deviceName: "Ana’s iPhone", model: "iPhone 17")
        default: nil
        }
        model.remoteAccess.applySnapshot(state: enabled ? .connected : .disabled, devices: devices,
                                         online: enabled ? [phone.deviceId] : [], pairing: pairing)
    }
}
