import Foundation
import Observation
import PRBarRemoteKit

/// What the pairing session reports (spec P.11). The live implementation runs Noise IKpsk2 through the relay
/// (`RemoteClient`, plan 17); tests and the demo mode use `FakePairingService`.
public enum PairingProgress: Equatable, Sendable {
    /// Connected to the relay's pairing slot; the handshake is under way.
    case joining
    /// The 6-digit code both screens show (`SAS.display`, "123 456").
    case code(String)
    /// The Mac confirmed: what it handed over.
    case paired(PairedMac)
}

public enum PairingFailure: Error, Equatable, Sendable {
    /// The QR's 5 minutes ran out (or the slot burned after 3 tries).
    case expired
    /// Cancelled on the Mac, or the codes didn't match.
    case cancelled
    case failed(String)
}

public protocol PairingService: Sendable {
    /// Joins the slot of `qr` with this iPhone's new keys (`presencePublicKey`: the Secure Enclave key's x963).
    func join(_ qr: PairingQR, keys: StoredDeviceKeys, presencePublicKey: Data) -> AsyncThrowingStream<PairingProgress, Error>
    /// "Codes Don't Match": burns the slot.
    func cancel() async
}

/// Asks for notification permission (after pairing, never before).
public protocol NotificationPermission: Sendable {
    func request() async -> Bool
}

/// `pair:welcome`, `pair:scan`, `pair:paired` (design §pair).
@MainActor @Observable
public final class PairingModel {
    public enum Step: Equatable, Sendable {
        case welcome
        case scanning
        /// A pairing link or QR was read: the Mac and relay it points to, and the pairing it would replace. Nothing
        /// happens until the user taps Pair (crypto review L4: a link never silently replaces a pairing).
        case confirmLink(macName: String, relayHost: String, replacing: String?)
        case joining(macName: String)
        /// pair:paired: the code to compare, with "Codes Match" / "Codes Don't Match".
        case confirmCode(code: String, macName: String)
        /// "Codes Match" tapped: waiting for the Mac's confirmation.
        case waitingForMac(code: String, macName: String)
        case paired(macName: String)
    }

    public static let invalidQRMessage = "This isn't a PRBar pairing code. Scan the QR in PRBar › Settings › Pair iPhone on your Mac."
    public static let expiredMessage = "The pairing code expired. Show a new one on your Mac and scan it again."
    public static let cancelledMessage = "Pairing was cancelled. Start again from PRBar on your Mac."
    public static let mismatchMessage = "Pairing was cancelled because the codes didn't match."

    public private(set) var step: Step = .welcome
    /// Shown on `pair:welcome` after a failed attempt, or on `pair:scan` for an unreadable code.
    public private(set) var message: String?
    public private(set) var scanError: String?
    /// The last code shown (kept while waiting for the Mac and once paired).
    public private(set) var code: String?

    @ObservationIgnored private let service: any PairingService
    @ObservationIgnored private let keychain: DeviceKeychain
    @ObservationIgnored private let makePresenceKey: @Sendable () throws -> (keyData: Data, publicKey: Data)
    @ObservationIgnored private let notifications: any NotificationPermission
    @ObservationIgnored private let onPaired: @MainActor (PairedMac) -> Void
    @ObservationIgnored private var session: Task<Void, Never>?
    @ObservationIgnored private var mismatch = false
    @ObservationIgnored private var pendingQR: PairingQR?
    @ObservationIgnored private let allowInsecureRelay: Bool

    /// `allowInsecureRelayForTests`: accept a relay at an IP literal over `ws://` (the local relay of the end-to-end
    /// test). Never in the app.
    public init(service: any PairingService, keychain: DeviceKeychain,
                makePresenceKey: @escaping @Sendable () throws -> (keyData: Data, publicKey: Data),
                notifications: any NotificationPermission, allowInsecureRelayForTests: Bool = false,
                onPaired: @escaping @MainActor (PairedMac) -> Void) {
        allowInsecureRelay = allowInsecureRelayForTests
        self.service = service
        self.keychain = keychain
        self.makePresenceKey = makePresenceKey
        self.notifications = notifications
        self.onPaired = onPaired
    }

    public func startScanning() {
        message = nil
        scanError = nil
        step = .scanning
    }

    /// Cancel on `pair:scan` (also while joining: the slot is released on the Mac's side by `cancel`).
    public func cancelScanning() {
        pendingQR = nil
        if let session {
            session.cancel()
            self.session = nil
            let service = service
            Task { await service.cancel() }
        }
        step = .welcome
    }

    /// A code read by the scanner.
    public func scanned(_ text: String) {
        guard step == .scanning else { return }
        guard let qr = try? PairingQR(url: text, allowInsecure: allowInsecureRelay) else {
            scanError = Self.invalidQRMessage
            return
        }
        confirm(qr, replacing: nil)
    }

    /// `prbar://pair?…` opened from anywhere (Camera, Safari, Messages): first the confirmation screen, with a warning
    /// when it would replace the pairing with `replacing`.
    public func open(_ url: URL, replacing: String? = nil) {
        guard let qr = try? PairingQR(url: url.absoluteString, allowInsecure: allowInsecureRelay) else {
            message = Self.invalidQRMessage
            step = .welcome
            return
        }
        confirm(qr, replacing: replacing)
    }

    /// The confirmation screen's Pair.
    public func confirmPairing() {
        guard case .confirmLink = step, let qr = pendingQR else { return }
        pendingQR = nil
        join(qr)
    }

    public static func replaceWarning(_ mac: String) -> String { "This replaces your pairing with \(mac)." }

    private func confirm(_ qr: PairingQR, replacing: String?) {
        scanError = nil
        message = nil
        pendingQR = qr
        step = .confirmLink(macName: qr.macName, relayHost: qr.relayHost, replacing: replacing)
    }

    public func codesMatch() {
        guard case .confirmCode(let code, let mac) = step else { return }
        if let held {
            // The Mac confirmed first: nothing was stored until this tap (review L5).
            self.held = nil
            Task { await commit(held.mac, keys: held.keys) }
            return
        }
        step = .waitingForMac(code: code, macName: mac)
    }

    /// The Mac's confirmation, held until the user taps "Codes Match" here.
    @ObservationIgnored private var held: (mac: PairedMac, keys: StoredDeviceKeys)?

    public func codesDontMatch() async {
        held = nil
        mismatch = true
        session?.cancel()
        await service.cancel()
        finish(with: Self.mismatchMessage)
    }

    /// Waits for the running session (tests).
    public func settle() async {
        await session?.value
    }

    private func join(_ qr: PairingQR) {
        scanError = nil
        message = nil
        mismatch = false
        step = .joining(macName: qr.macName)
        session?.cancel()
        session = Task { [weak self] in await self?.run(qr) }
    }

    private func run(_ qr: PairingQR) async {
        let keys: StoredDeviceKeys
        let presencePublicKey: Data
        do {
            // New keys for every attempt: a failed or cancelled pairing leaves nothing reusable behind.
            let presence = try makePresenceKey()
            keys = StoredDeviceKeys.generate(presenceKey: presence.keyData)
            presencePublicKey = presence.publicKey
        } catch {
            finish(with: "Face ID isn't available on this iPhone, so it can't be paired.")
            return
        }
        do {
            for try await progress in service.join(qr, keys: keys, presencePublicKey: presencePublicKey) {
                guard !mismatch else { return }
                switch progress {
                case .joining:
                    step = .joining(macName: qr.macName)
                case .code(let code):
                    self.code = code
                    step = .confirmCode(code: code, macName: qr.macName)
                case .paired(let mac):
                    session = nil
                    if case .confirmCode = step {
                        // The Mac confirmed before the user compared the codes here: keep the result in memory and
                        // store it only on "Codes Match" (review L5: a malicious pairing link can't replace a pairing
                        // without a tap on this screen).
                        held = (mac, keys)
                        return
                    }
                    await commit(mac, keys: keys)
                    return
                }
            }
        } catch PairingFailure.expired {
            finish(with: Self.expiredMessage)
        } catch PairingFailure.cancelled {
            if !mismatch { finish(with: Self.cancelledMessage) }
        } catch PairingFailure.failed(let text) {
            finish(with: text)
        } catch is CancellationError {
            return
        } catch {
            finish(with: error.localizedDescription)
        }
    }

    /// Stores the pairing (only after the Mac's confirmation and the user's "Codes Match").
    private func commit(_ mac: PairedMac, keys: StoredDeviceKeys) async {
        do {
            try keychain.save(keys: keys)
            try keychain.save(mac: mac)
        } catch {
            finish(with: error.localizedDescription)
            return
        }
        step = .paired(macName: mac.macName)
        _ = await notifications.request()
        onPaired(mac)
    }

    /// Keys are only written once the Mac confirms, so a failed attempt has nothing to clean up — and must not touch
    /// an existing pairing it was going to replace.
    private func finish(with message: String) {
        self.message = message
        step = .welcome
    }
}

/// Scripted pairing for tests, previews and the demo mode.
public final class FakePairingService: PairingService, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<PairingProgress, PairingFailure>]
    private var gate: CheckedContinuation<Void, Never>?
    private var holdBeforeLast: Bool
    private let delayBeforeLast: Duration?
    public private(set) var joinedQR: PairingQR?
    public private(set) var presenceKey: Data?
    public private(set) var cancelled = false

    /// `holdBeforeLast`: wait for `release()` before the last step (as if waiting for the Mac's "Codes Match");
    /// `delayBeforeLast`: wait that long instead (the demo).
    public init(script: [Result<PairingProgress, PairingFailure>], holdBeforeLast: Bool = false,
                delayBeforeLast: Duration? = nil) {
        self.script = script
        self.holdBeforeLast = holdBeforeLast
        self.delayBeforeLast = delayBeforeLast
    }

    public func release() {
        lock.withLock {
            holdBeforeLast = false
            gate?.resume()
            gate = nil
        }
    }

    public func join(_ qr: PairingQR, keys: StoredDeviceKeys, presencePublicKey: Data) -> AsyncThrowingStream<PairingProgress, Error> {
        lock.withLock {
            joinedQR = qr
            presenceKey = presencePublicKey
        }
        let steps = lock.withLock { script }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, step) in steps.enumerated() {
                    if index == steps.count - 1, let delay = delayBeforeLast {
                        try? await Task.sleep(for: delay)
                    }
                    if index == steps.count - 1, lock.withLock({ holdBeforeLast }) {
                        await withCheckedContinuation { gate in
                            lock.withLock {
                                if holdBeforeLast { self.gate = gate } else { gate.resume() }
                            }
                        }
                    }
                    if Task.isCancelled { break }
                    switch step {
                    case .success(let progress): continuation.yield(progress)
                    case .failure(let failure):
                        continuation.finish(throwing: failure)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() async {
        lock.withLock { cancelled = true }
        release()
    }
}
