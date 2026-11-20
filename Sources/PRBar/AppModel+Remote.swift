import Foundation
import PRBarCore

/// El acceso desde el iPhone (spec Q.3). Lo conecta `RemoteAccessService` (Plan 18, Tasks 2–8).
extension AppModel: RemoteActions {
    private var unavailable: CommandFailure { CommandFailure(.invalidState, "iPhone access isn’t available in this build.") }

    func remoteStatus() -> RemoteStatusInfo {
        RemoteStatusInfo(enabled: false, relayHost: nil, state: "disabled", devices: 0, devicesOnline: 0, keepAwake: false,
                         keepingAwake: false, mailbox: true, appInstallURL: nil, accountPrefix: nil)
    }
    func remoteEnable(relay: String, enrollToken: String) async throws -> RemoteStatusInfo { throw unavailable }
    func remoteDisable() async throws -> RemoteStatusInfo { throw unavailable }
    func remotePairStart() async throws -> RemotePairingInfo { throw unavailable }
    func remotePairWait(pairing: String, events: CommandEventSink) async throws -> RemotePairingInfo { throw unavailable }
    func remotePairConfirm(pairing: String, accepted: Bool) async throws -> RemotePairResult { throw unavailable }
    func remoteDevices() -> [RemoteDeviceInfo] { [] }
    func remoteRevoke(device: String) async throws -> RemoteDeviceInfo { throw unavailable }
    func remoteSetKeepAwake(enabled: Bool) throws -> RemoteStatusInfo { throw unavailable }
    func remoteReset() async throws -> RemoteStatusInfo { throw unavailable }
    func remoteSetPresenceRequirement(device: String, enabled: Bool) async throws -> RemoteDeviceInfo { throw unavailable }
    func remoteSetMailbox(enabled: Bool) async throws -> RemoteStatusInfo { throw unavailable }
    func remoteSetAppLink(url: String?) throws -> RemoteStatusInfo { throw unavailable }
}
