import PRBarCore

extension AppModel {
    /// Abre el socket de `prbar`. Cada comando corre en el main actor con los mismos métodos que usa la UI.
    func startCommandServer() {
        let server = CommandServer(socketURL: AppPaths.socketFile, appVersion: appVersion) { [weak self] command, events in
            guard let self else { return .failure(CommandFailure(.failed, "PRBar is quitting.")) }
            return await self.handleCommand(command, events: events)
        }
        do {
            try server.start()
            commandServer = server
        } catch {
            AppLog.write("Couldn’t open the prbar socket: \(error.localizedDescription)")
        }
    }

    func handleCommand(_ command: AppCommand, events: @escaping CommandEventSink) async -> Result<JSONValue, CommandFailure> {
        // Solo el nombre: los argumentos pueden llevar un token (`slack token set`).
        AppLog.write("prbar: \(command.name.rawValue)")
        return await CommandDispatcher.run(command, on: self, events: events)
    }

    func stopCommandServer() {
        commandServer?.stop()
        commandServer = nil
    }
}
