import ArgumentParser
import Darwin
import Foundation
import PRBarCore

/// `prbar remote` (spec Q.3): el acceso desde el iPhone. Los mismos comandos que Settings › iPhone.
struct RemoteGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote", abstract: "Control this Mac from PRBar on your iPhone.",
        discussion: "PRBar connects out to your relay server (no open ports) and everything between the Mac and the iPhone is end-to-end encrypted. See docs/iphone.md.",
        subcommands: [RemoteStatus.self, RemoteEnable.self, RemoteDisable.self, RemotePair.self, RemoteDevices.self,
                      RemoteRevoke.self, RemoteKeepAwake.self, RemoteMailbox.self, RemoteAppLinkGroup.self, RemoteReset.self],
        defaultSubcommand: RemoteStatus.self)
}

enum RemoteRender {
    static func status(_ info: RemoteStatusInfo, _ output: Output) {
        let state: String = switch info.state {
        case "connected":
            "Connected to \(info.relayHost ?? "the relay") · \(info.devicesOnline) iPhone\(info.devicesOnline == 1 ? "" : "s") online"
        case "connecting": "Connecting to \(info.relayHost ?? "the relay")…"
        case "offline": "Offline\(info.detail.map { " — \($0)" } ?? "")"
        case "failed": "Not connected — \(info.detail ?? "error")"
        default: info.enabled ? "Enabled" : "Off"
        }
        output.line(output.paint("iPhone access: ", .bold) + state)
        var pairs: [(String, String)] = []
        if let relay = info.relayHost { pairs.append(("Relay", relay)) }
        pairs.append(("Paired iPhones", "\(info.devices)"))
        pairs.append(("Keep awake while charging", Render.onOff(info.keepAwake) + (info.keepingAwake ? " (holding)" : "")))
        pairs.append(("Mailbox (last state, 7 days)", Render.onOff(info.mailbox)))
        pairs.append(("iPhone app link", info.appInstallURL?.absoluteString ?? "none (install from Xcode, see docs/iphone.md)"))
        Render.pairs(pairs, output)
        if !info.enabled && info.relayHost == nil {
            output.line(output.paint("Turn it on with: prbar remote enable --relay \(RemoteSettings.defaultRelayHost)", .dim))
        }
    }

    static func devices(_ devices: [RemoteDeviceInfo], _ output: Output) {
        guard !devices.isEmpty else { return output.line("No paired iPhones. Pair one with: prbar remote pair") }
        output.table(["ID", "Name", "Model", "Paired", "Last seen", "Face ID", "Notifications"], devices.map { device in
            [String(device.id.prefix(8)), device.name, device.model, Render.date(device.pairedAt),
             device.online ? "online" : device.lastSeen.map(Render.age) ?? "—",
             device.requirePresence ? "required" : "off", device.notifications ? "on" : "off"]
        })
    }
}

/// Cómo `prbar remote enable` lee el token de inscripción (público para que los tests lo reemplacen). `true` = stdin.
public enum EnrollTokenInput {
    nonisolated(unsafe) public static var read: (Bool) throws -> String = { fromStdin in
        if fromStdin {
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard isatty(STDIN_FILENO) == 1 else { return "" }
        return Prompt.secret("Enrollment token (leave empty to reuse this Mac’s account): ")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct RemoteStatus: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Whether iPhone access is on, the relay and the connection.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .remoteStatus }
    func render(_ result: JSONValue, _ output: Output) throws { RemoteRender.status(try result.decode(), output) }
}

struct RemoteEnable: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Allow iPhone remote control (creates this Mac’s account on the relay).",
        discussion: "The relay only accepts new Macs with its enrollment token. PRBar asks for it without echo (or reads it from stdin with --enroll-token-stdin) and never stores it. Enabling the same relay again doesn’t need it.")
    @Option(help: "The relay server (host or https URL). Default: \(RemoteSettings.defaultRelayHost).") var relay = RemoteSettings.defaultRelayHost
    @Flag(name: .customLong("enroll-token-stdin"), help: "Read the enrollment token from stdin.") var enrollTokenStdin = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) throws -> AppCommand {
        .remoteEnable(relay: relay, enrollToken: try EnrollTokenInput.read(enrollTokenStdin))
    }
    func render(_ result: JSONValue, _ output: Output) throws { RemoteRender.status(try result.decode(), output) }
}

struct RemoteDisable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Turn iPhone access off (paired iPhones stay paired).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .remoteDisable }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("iPhone access is off.") }
}

/// `prbar remote pair`: el QR en la terminal, espera al teléfono, muestra el código y pregunta si coincide.
struct RemotePair: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair", abstract: "Pair an iPhone: shows a QR code, then asks you to compare a 6-digit code.",
        discussion: "Scan the QR with the iPhone’s Camera or with PRBar. It works once and expires in 5 minutes.")
    @OptionGroup var global: GlobalOptions

    /// Lo que va pasando (lo llena `prepare`).
    private var joined: RemotePairingInfo?

    var confirmationPolicy: ConfirmationPolicy { .always }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard output.terminal.isInteractive, !output.json else {
            throw CommandFailure(.invalidUsage, "Pairing needs a terminal to show the QR code.")
        }
        let started: RemotePairingInfo = try connection.run(.remotePairStart).decode()
        guard let matrix = QRCodeMatrix.make(started.qr) else {
            throw CommandFailure(.failed, "Couldn’t draw the QR code.")
        }
        output.line()
        QRRender.halfBlocks(matrix: matrix).forEach { output.line(output.terminal.colors ? QRRender.colored($0) : $0) }
        output.line()
        output.line("Scan this with the Camera app or with PRBar on your iPhone.")
        output.line(output.paint("Or open this link on the iPhone (it’s secret: don’t share it): \(started.qr)", .dim))
        let seconds = max(0, Int(started.expiresAt.timeIntervalSinceNow.rounded()))
        output.line("Waiting for your iPhone… (expires in \(seconds / 60):\(String(format: "%02d", seconds % 60)))")
        let interrupt = InterruptHandler(cancel: .remotePairConfirm(pairing: started.pairing, confirmed: false),
                                         connect: { try AppConnection.connect() }, err: { output.note($0) })
        defer { interrupt.remove() }
        joined = try connection.run(.remotePairWait(pairing: started.pairing)).decode()
    }

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        guard let joined, let code = joined.code else { return nil }
        output.line("\(joined.deviceName ?? "An iPhone") (\(joined.model ?? "iPhone")) wants to pair.")
        return "Does your iPhone show \(code)?"
    }

    var declinedCommand: AppCommand? { joined.map { .remotePairConfirm(pairing: $0.pairing, confirmed: false) } }

    func appCommand(confirmed: Bool) -> AppCommand {
        .remotePairConfirm(pairing: joined?.pairing ?? "", confirmed: confirmed)
    }

    func render(_ result: JSONValue, _ output: Output) throws {
        let paired: RemotePairResult = try result.decode()
        if let device = paired.device {
            output.line(output.paint("Paired \(device.name).", .green) + " It can now see your PRs and act for you; merge, push, approve and tests need Face ID.")
        } else {
            output.line("Pairing canceled.")
        }
    }
}

struct RemoteDevices: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices", abstract: "Paired iPhones, or turn Face ID on or off for one (--require-face-id).")
    @Option(name: .customLong("require-face-id"), help: "An iPhone (id, id prefix or name): set whether merge, push, approve and tests need Face ID on it.")
    var requireFaceID: String?
    @Argument(help: "With --require-face-id: on or off.") var setting: OnOff?
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if (requireFaceID == nil) != (setting == nil) {
            throw ValidationError("Use --require-face-id <iphone> on|off together.")
        }
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        if let requireFaceID, let setting {
            return .remoteSetPresenceRequirement(device: requireFaceID, enabled: setting.isOn)
        }
        return .remoteDevices
    }

    func render(_ result: JSONValue, _ output: Output) throws {
        if let setting {
            let device: RemoteDeviceInfo = try result.decode()
            output.line("Face ID for merge, push, approve and tests on \(device.name): \(setting == .on ? "required" : "off").")
        } else {
            RemoteRender.devices(try result.decode(), output)
        }
    }
}

struct RemoteRevoke: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke", abstract: "Remove a paired iPhone (it can’t connect again until you pair it).")
    @Argument(help: "The iPhone: id, id prefix or name (see prbar remote devices).") var device: String
    @OptionGroup var global: GlobalOptions
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        "Revoke \(device)? It stops working right away and has to be paired again."
    }
    func appCommand(confirmed: Bool) -> AppCommand { .remoteRevoke(device: device, confirmed: confirmed) }
    func render(_ result: JSONValue, _ output: Output) throws {
        let info: RemoteDeviceInfo = try result.decode()
        output.line("Revoked \(info.name).")
    }
}

struct RemoteKeepAwake: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep-awake", abstract: "Keep this Mac awake while charging, so the iPhone can reach it (on or off).",
        discussion: "The display can still sleep. With the lid closed and no external display, macOS sleeps anyway.")
    @Argument(help: "on or off.") var value: OnOff
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .remoteSetKeepAwake(enabled: value.isOn) }
    func render(_ result: JSONValue, _ output: Output) throws {
        output.line("Keep this Mac awake while charging: \(value.rawValue).")
    }
}

struct RemoteMailbox: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "mailbox", abstract: "Leave the last encrypted state on the relay for 7 days (on or off).",
        discussion: "So the iPhone shows recent PRs even when this Mac is asleep. Only your iPhones can decrypt it.")
    @Argument(help: "on or off.") var value: OnOff
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .remoteSetMailbox(enabled: value.isOn) }
    func render(_ result: JSONValue, _ output: Output) throws {
        output.line(value.isOn ? "Mailbox on." : "Mailbox off: the relay keeps nothing (an empty state replaces the last one).")
    }
}

struct RemoteAppLinkGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-link", abstract: "The link Settings › iPhone shows to install PRBar for iPhone.",
        subcommands: [RemoteAppLinkSet.self, RemoteAppLinkClear.self])
}

struct RemoteAppLinkSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Set the TestFlight or App Store link (https, testflight.apple.com or apps.apple.com).")
    @Argument(help: "The link, e.g. https://testflight.apple.com/join/…") var url: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .remoteSetAppLink(url: url) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved. Settings › iPhone shows its QR code.") }
}

struct RemoteAppLinkClear: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Remove the link.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .remoteSetAppLink(url: nil) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Link removed.") }
}

struct RemoteReset: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset", abstract: "New keys and a new relay account; removes every paired iPhone.",
        discussion: "For a compromised relay or a cloned Mac. Turn access on again with the enrollment token and pair again.")
    @OptionGroup var global: GlobalOptions
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        "Reset iPhone access? Every paired iPhone stops working and this Mac gets new keys."
    }
    func appCommand(confirmed: Bool) -> AppCommand { .remoteReset(confirmed: confirmed) }
    func render(_ result: JSONValue, _ output: Output) throws {
        output.line("iPhone access was reset. Turn it on again with: prbar remote enable")
    }
}
