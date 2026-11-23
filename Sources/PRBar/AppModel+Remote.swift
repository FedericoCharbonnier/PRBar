import AppKit
import Combine
import Network
import PRBarCore
import PRBarRemoteMac

/// `AppConfig.remote` para el servicio del iPhone.
extension AppModel: RemoteSettingsStore {
    var remoteSettings: RemoteSettings { configStore.config.remote }

    func updateRemoteSettings(_ mutate: (inout RemoteSettings) -> Void) throws {
        try configStore.update { mutate(&$0.remote) }
        objectWillChange.send()
    }
}

/// Avisos del sistema que el acceso remoto necesita: despertar, dormir y cambios de red (spec Q.1).
@MainActor
final class RemoteSystemObservers {
    private var tokens: [NSObjectProtocol] = []
    private let monitor = NWPathMonitor()

    init(service: RemoteAccessService) {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak service] _ in
            Task { @MainActor in await service?.retryNow() }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak service] _ in
            // Se corta ordenado: el relay marca la Mac offline enseguida (y no a los 20 s del ping).
            Task { @MainActor in await service?.stop() }
        })
        var lastStatus: NWPath.Status?
        monitor.pathUpdateHandler = { [weak service] path in
            let status = path.status
            Task { @MainActor in
                defer { lastStatus = status }
                guard status == .satisfied, lastStatus != nil, lastStatus != status else { return }
                await service?.retryNow()
            }
        }
        monitor.start(queue: .main)
    }

    func cancel() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        monitor.cancel()
    }
}

extension AppModel {
    /// Arranca el servicio (si está habilitado se conecta) y lo engancha a los cambios de la app.
    func startRemoteAccess() {
        let service = remoteAccess
        service.actions = self
        // Clones, worktrees y runners de la config: no salen hacia el teléfono (revisión M1).
        service.redactionInputs = { [weak self] in
            guard let config = self?.configStore.config else { return ([], []) }
            return (config.remoteRedactionFolders, config.remoteRedactionHosts)
        }
        // El feed recalcula cuando cambia algo que muestran sus tópicos (agrupado en el servicio).
        let changes: [AnyPublisher<Void, Never>] = [
            objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            prStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            reviews.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            respond.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            merges.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        remoteObservers.append(Publishers.MergeMany(changes).sink { [weak service] in service?.stateChanged() })
        // Lo que ve Settings › iPhone.
        remoteObservers.append(service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        // Las notificaciones de la Mac también van a los iPhones.
        notifications?.onDeliver = { [weak self] planned in self?.pushToPhones(planned) }
        remoteSystem = RemoteSystemObservers(service: service)
        service.start()
    }

    func stopRemoteAccess() {
        remoteSystem?.cancel()
        Task { await remoteAccess.stop() }
    }

    private func pushToPhones(_ planned: [PlannedNotification]) {
        guard !planned.isEmpty, remoteSettings.enabled else { return }
        Task {
            let badge = try? await status().badgeCount
            remoteAccess.push(planned, badge: badge)
        }
    }

    /// Un chat que corre en la Mac: sus pedazos van a los teléfonos que miran `pr:<id>` (`chatDelta`, spec P.6).
    func watchChatForPhones(_ chat: ChatCoordinator, prID: String) {
        let key = chat.session.id
        guard remoteChatWatchers[key] == nil else { return }
        var last = ""
        remoteChatWatchers[key] = chat.stream.$partialText.removeDuplicates().sink { [weak self] text in
            defer { last = text }
            guard let self, text.count > last.count, text.hasPrefix(last),
                  let delta = self.remoteAccess.chatDeltaText(previous: last, current: text) else { return }
            self.remoteAccess.chatDelta(pr: prID, text: delta)
        }
    }
}

/// Los comandos `remote*` (spec Q.3): el mismo servicio para la UI, `prbar` y el iPhone.
extension AppModel: RemoteActions {
    func remoteStatus() -> RemoteStatusInfo { remoteAccess.status() }
    func remoteEnable(relay: String, enrollToken: String) async throws -> RemoteStatusInfo {
        try await remoteAccess.enable(relay: relay, enrollToken: enrollToken)
    }
    func remoteDisable() async throws -> RemoteStatusInfo { try await remoteAccess.disable() }
    func remotePairStart() async throws -> RemotePairingInfo { try await remoteAccess.pairStart() }
    func remotePairWait(pairing: String, events: CommandEventSink) async throws -> RemotePairingInfo {
        try await remoteAccess.pairWait(pairing: pairing, events: events)
    }
    func remotePairConfirm(pairing: String, accepted: Bool) async throws -> RemotePairResult {
        try await remoteAccess.pairConfirm(pairing: pairing, accepted: accepted)
    }
    func remoteDevices() -> [RemoteDeviceInfo] { remoteAccess.deviceList() }
    func remoteRevoke(device: String) async throws -> RemoteDeviceInfo { try await remoteAccess.revoke(device) }
    func remoteSetKeepAwake(enabled: Bool) throws -> RemoteStatusInfo { try remoteAccess.setKeepAwake(enabled) }
    func remoteReset() async throws -> RemoteStatusInfo { try await remoteAccess.reset() }
    func remoteSetPresenceRequirement(device: String, enabled: Bool) async throws -> RemoteDeviceInfo {
        try await remoteAccess.setPresenceRequirement(device, enabled: enabled)
    }
    func remoteSetMailbox(enabled: Bool) async throws -> RemoteStatusInfo { try await remoteAccess.setMailbox(enabled) }
}
