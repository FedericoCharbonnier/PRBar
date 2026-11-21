import Foundation
import PRBarCore
import PRBarRemoteFixtures
import PRBarRemoteKit
import PRBarRemoteMac

// `prbar-remote-fixture`: los vectores cruzados de la web y una Mac simulada para su e2e (spec web W.9, plan 20 A3).
//
//   prbar-remote-fixture vectors <dir>
//   prbar-remote-fixture serve --relay ws://127.0.0.1:<port> --enroll-token <t> --state <dir> [--web-origin <origin>]
//
// `serve` imprime una línea JSON por evento en stdout y lee comandos de stdin (ver `FixtureServer.help`). Solo datos
// ficticios (`FixtureActions`); las claves de la Mac viven en memoria (cada corrida es una Mac nueva).

enum FixtureServer {
    static let usage = """
    usage:
      prbar-remote-fixture vectors <dir>
      prbar-remote-fixture serve --relay ws://127.0.0.1:<port> --enroll-token <token> --state <dir> [--web-origin <origin>]
    """

    static let help = """
    stdin commands: pair | confirm | cancel | notify <kind> | devices | revoke | state | quit
    notify kinds: \(NotificationKind.allCases.map(\.rawValue).joined(separator: ", "))
    """

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    /// Una línea JSON en stdout (con las claves ordenadas), enseguida.
    static func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    static func options(_ arguments: ArraySlice<String>) -> [String: String] {
        var out: [String: String] = [:]
        var rest = arguments
        while let key = rest.popFirst() {
            guard key.hasPrefix("--"), let value = rest.popFirst() else { fail(usage) }
            out[String(key.dropFirst(2))] = value
        }
        return out
    }

    @MainActor
    static func main(_ arguments: [String]) async {
        let args = arguments.dropFirst()
        switch args.first {
        case "vectors":
            guard args.count == 2 else { fail(usage) }
            do {
                let names = try await WebVectors.write(to: URL(fileURLWithPath: args[args.startIndex + 1]))
                print("wrote \(names.joined(separator: ", "))")
            } catch {
                fail("vectors failed: \(error)")
            }
        case "serve":
            let opts = options(args.dropFirst())
            guard let relay = opts["relay"], let token = opts["enroll-token"], let state = opts["state"] else { fail(usage) }
            await serve(relay: relay, token: token, state: URL(fileURLWithPath: state), webOrigin: opts["web-origin"])
        default:
            fail(usage)
        }
    }

    // MARK: serve

    /// `ws://host:port` → (`host:port`, inseguro) y el origen de la web que sirve ese relay (`http://host:port`).
    static func parseRelay(_ text: String) -> (host: String, insecure: Bool, origin: String) {
        for (scheme, insecure, web) in [("ws://", true, "http://"), ("wss://", false, "https://")] where text.hasPrefix(scheme) {
            var host = String(text.dropFirst(scheme.count))
            if host.hasSuffix("/") { host.removeLast() }
            return (host, insecure, web + host)
        }
        fail("--relay must be ws://host:port or wss://host")
    }

    @MainActor
    static func serve(relay: String, token: String, state: URL, webOrigin: String?) async {
        let (host, insecure, defaultOrigin) = parseRelay(relay)
        let origin = webOrigin ?? defaultOrigin
        let env = RemoteServiceEnvironment(
            keys: RemoteKeyStore(secrets: MemorySecretStore()),
            devices: RemoteDeviceStore(directory: state.appendingPathComponent("remote")),
            enroller: URLSessionRelayEnroller(allowInsecureForTests: insecure),
            linkFactory: { host in WebSocketRelayLink.factory(host: host, allowInsecureTransportForTests: insecure) },
            macName: "Fixture Mac", appVersion: "1.9.0",
            tune: { config in
                config.webOrigin = origin
                config.backoff = { _ in .milliseconds(200) }
                config.pushTimeout = .seconds(5)
            },
            connectBackoff: { _ in .milliseconds(200) }, mailboxInterval: .seconds(5), feedDebounce: .milliseconds(50),
            activityInterval: .seconds(2), allowInsecureForTests: insecure)
        let service = RemoteAccessService(settings: MemoryRemoteSettingsStore(), environment: env)
        let actions = FixtureActions()
        service.actions = actions
        actions.onChange = { [weak service, weak actions] in
            service?.stateChanged()
            if let actions { emit(snapshot(actions, event: "changed")) }
        }
        actions.onChatText = { [weak service] pr, text in service?.chatDelta(pr: pr, text: text) }
        actions.onSetPresence = { [weak service] device, enabled in
            guard let service else { throw CommandFailure(.cancelled, "Quitting.") }
            return try await service.setPresenceRequirement(device, enabled: enabled)
        }
        do {
            _ = try await service.enable(relay: host, enrollToken: token)
        } catch {
            emit(["event": "error", "message": "enable: \(error.localizedDescription)"])
            exit(1)
        }
        let deadline = Date().addingTimeInterval(20)
        while service.state != .connected {
            guard Date() < deadline else {
                emit(["event": "error", "message": "couldn’t connect to \(host)"])
                exit(1)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        emit(["event": "ready", "relay": host, "webOrigin": origin, "account": service.settings.accountId ?? "",
              "help": help])

        var pairing: String?
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let words = line.split(separator: " ").map(String.init)
                guard let command = words.first else { continue }
                do {
                    switch command {
                    case "pair":
                        let info = try await service.pairStart()
                        pairing = info.pairing
                        emit(["event": "pairing", "url": info.qr, "pairing": info.pairing,
                              "expiresAt": ISO8601DateFormatter().string(from: info.expiresAt)])
                        Task { @MainActor in
                            do {
                                let joined = try await service.pairWait(pairing: info.pairing, events: { _ in })
                                emit(["event": "sas", "code": (joined.code ?? "").replacingOccurrences(of: " ", with: ""),
                                      "device": joined.deviceName ?? "", "model": joined.model ?? ""])
                            } catch {
                                emit(["event": "pairingEnded", "message": error.localizedDescription])
                            }
                        }
                    case "confirm", "cancel":
                        guard let id = pairing else { throw CommandFailure(.invalidState, "No pairing is open.") }
                        let result = try await service.pairConfirm(pairing: id, accepted: command == "confirm")
                        pairing = nil
                        if let device = result.device {
                            emit(["event": "paired", "device": device.name, "id": device.id, "model": device.model])
                        } else {
                            emit(["event": "pairingCancelled"])
                        }
                    case "notify":
                        guard words.count == 2, let kind = NotificationKind(rawValue: words[1]) else {
                            throw CommandFailure(.invalidUsage, "notify <kind>: \(help)")
                        }
                        let notification = PlannedNotification(kind: kind, title: "Ready to Merge",
                                                               body: "api#322 · Make payment retries idempotent", url: nil,
                                                               prID: FixtureActions.mergePR, mergePRID: FixtureActions.mergePR)
                        service.push([notification], badge: 1)
                        emit(["event": "push", "kind": kind.rawValue, "devices": service.devices.count])
                    case "devices":
                        emit(["event": "devices", "devices": service.deviceList().map {
                            ["id": $0.id, "name": $0.name, "online": $0.online, "notifications": $0.notifications,
                             "requirePresence": $0.requirePresence]
                        }])
                    case "revoke":
                        for device in service.deviceList() { _ = try await service.revoke(device.id) }
                        emit(["event": "revoked"])
                    case "state":
                        emit(snapshot(actions, event: "state"))
                    case "quit":
                        await service.stop()
                        emit(["event": "bye"])
                        exit(0)
                    default:
                        throw CommandFailure(.invalidUsage, "unknown command “\(command)”. \(help)")
                    }
                } catch {
                    emit(["event": "error", "message": error.localizedDescription])
                }
            }
        } catch {
            emit(["event": "error", "message": "stdin: \(error.localizedDescription)"])
        }
        // stdin cerrado: se termina como con `quit`.
        await service.stop()
        exit(0)
    }

    /// Lo que pasó en la Mac simulada (para que el e2e verifique un merge o un approve).
    @MainActor
    static func snapshot(_ actions: FixtureActions, event: String) -> [String: Any] {
        ["event": event, "merged": actions.merged, "approved": actions.approved, "pushed": actions.pushed,
         "included": actions.included, "calls": actions.calls]
    }
}

await FixtureServer.main(CommandLine.arguments)
