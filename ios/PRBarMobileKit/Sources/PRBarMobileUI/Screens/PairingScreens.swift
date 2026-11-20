import SwiftUI
import PRBarMobileCore

/// `pair:welcome` → `pair:scan` → `pair:paired`.
public struct PairingFlow: View {
    let model: PairingModel
    var revokedFrom: String?

    public init(model: PairingModel, revokedFrom: String? = nil) {
        self.model = model
        self.revokedFrom = revokedFrom
    }

    public var body: some View {
        switch model.step {
        case .welcome:
            PairWelcome(message: model.message ?? revokedFrom.map { "This iPhone was removed from \($0)." }) {
                model.startScanning()
            }
        case .scanning:
            PairScan(error: model.scanError, joiningMac: nil, cancel: model.cancelScanning, scanned: model.scanned)
        case .joining(let mac):
            PairScan(error: nil, joiningMac: mac, cancel: model.cancelScanning, scanned: { _ in })
        case .confirmCode(let code, let mac):
            PairPaired(macName: mac, code: code, waiting: false, match: model.codesMatch) {
                Task { await model.codesDontMatch() }
            }
        case .waitingForMac(let code, let mac):
            PairPaired(macName: mac, code: code, waiting: true, match: {}) { Task { await model.codesDontMatch() } }
        case .paired(let mac):
            PairPaired(macName: mac, code: model.code ?? "", waiting: true, match: {}, dontMatch: {})
        }
    }
}

public struct PairWelcome: View {
    let message: String?
    let scan: () -> Void

    public init(message: String?, scan: @escaping () -> Void) {
        self.message = message
        self.scan = scan
    }

    public var body: some View {
        VStack(spacing: 0) {
            VerticalScroll {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        AppTile(size: 100).shadow(color: Tokens.appTile.light.opacity(0.35), radius: 18, y: 10)
                        Text("Welcome to PRBar").font(Typo.largeTitle).foregroundStyle(Tokens.fg)
                        Text("Your Mac does the work. Your iPhone is the remote.")
                            .font(Typo.callout).foregroundStyle(Tokens.fg2)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        feature("bolt.fill", "Live from your Mac", "Reviews, CI and Claude's progress as they happen.")
                        feature("checkmark.circle", "Act from anywhere", "Review, respond, fix CI and merge with a tap.")
                        feature("lock.shield", "End-to-end encrypted",
                                "Your iPhone reaches your Mac through a relay that can’t read your data.")
                    }
                    if let message { NoticeBanner(message) }
                }
                .padding(.horizontal, 28)
                .padding(.top, 72)
            }
            VStack(spacing: 12) {
                PrimaryButton("Scan QR on your Mac", symbol: "qrcode.viewfinder", height: 56, action: scan)
                Text("On your Mac, open PRBar › Settings › Pair iPhone.")
                    .font(Typo.footnote).foregroundStyle(Tokens.fg2).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Tokens.bg2)
    }

    func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(Tokens.accentfg)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Tokens.fg)
                Text(text).font(Typo.body).foregroundStyle(Tokens.fg2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// `pair:scan`: full-screen camera with the viewfinder brackets.
public struct PairScan: View {
    let error: String?
    let joiningMac: String?
    let cancel: () -> Void
    let scanned: (String) -> Void

    public init(error: String?, joiningMac: String?, cancel: @escaping () -> Void, scanned: @escaping (String) -> Void) {
        self.error = error
        self.joiningMac = joiningMac
        self.cancel = cancel
        self.scanned = scanned
    }

    public var body: some View {
        ZStack {
            CameraLayer(scanned: scanned).ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack {
                    GlassCircleButton("xmark", label: "Cancel", tint: Tokens.white, action: cancel)
                    Spacer()
                }
                .padding(.horizontal, Metrics.gutter)
                VStack(spacing: 8) {
                    Text("Scan the QR code").font(Typo.title).foregroundStyle(.white)
                    Text("It's in PRBar › Settings › Pair iPhone on your Mac.")
                        .font(Typo.callout).foregroundStyle(.white.opacity(0.78)).multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.horizontal, 32)
                Spacer()
                ViewfinderBrackets().frame(width: 260, height: 260)
                    .overlay {
                        if joiningMac != nil { Spinner(tint: Tokens.white, size: 36) }
                    }
                Spacer()
                if let error {
                    Text(verbatim: error).font(Typo.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(12).background(Tokens.red, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
                Label(joiningMac.map { "Connecting to \($0)…" } ?? "End-to-end encrypted pairing",
                      systemImage: joiningMac == nil ? "lock.fill" : "lock.fill")
                    .font(Typo.footnoteBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .glassCapsule()
                    .padding(.bottom, 40)
            }
            .padding(.top, 12)
        }
        .background(Color.black)
        // Always over the camera: dark glass and white text.
        .environment(\.colorScheme, .dark)
    }
}

/// White rounded corner brackets (5 pt, r26).
struct ViewfinderBrackets: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let arm: CGFloat = 54
            let radius: CGFloat = 26
            Path { path in
                // Top-left
                path.move(to: CGPoint(x: 0, y: arm))
                path.addLine(to: CGPoint(x: 0, y: radius))
                path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: radius, y: 0), radius: radius)
                path.addLine(to: CGPoint(x: arm, y: 0))
                // Top-right
                path.move(to: CGPoint(x: size.width - arm, y: 0))
                path.addLine(to: CGPoint(x: size.width - radius, y: 0))
                path.addArc(tangent1End: CGPoint(x: size.width, y: 0), tangent2End: CGPoint(x: size.width, y: radius), radius: radius)
                path.addLine(to: CGPoint(x: size.width, y: arm))
                // Bottom-right
                path.move(to: CGPoint(x: size.width, y: size.height - arm))
                path.addLine(to: CGPoint(x: size.width, y: size.height - radius))
                path.addArc(tangent1End: CGPoint(x: size.width, y: size.height),
                            tangent2End: CGPoint(x: size.width - radius, y: size.height), radius: radius)
                path.addLine(to: CGPoint(x: size.width - arm, y: size.height))
                // Bottom-left
                path.move(to: CGPoint(x: arm, y: size.height))
                path.addLine(to: CGPoint(x: radius, y: size.height))
                path.addArc(tangent1End: CGPoint(x: 0, y: size.height), tangent2End: CGPoint(x: 0, y: size.height - radius),
                            radius: radius)
                path.addLine(to: CGPoint(x: 0, y: size.height - arm))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

/// `pair:paired`: the 6-digit code to compare with the Mac's.
public struct PairPaired: View {
    let macName: String
    let code: String
    let waiting: Bool
    let match: () -> Void
    let dontMatch: () -> Void

    public init(macName: String, code: String, waiting: Bool, match: @escaping () -> Void, dontMatch: @escaping () -> Void) {
        self.macName = macName
        self.code = code
        self.waiting = waiting
        self.match = match
        self.dontMatch = dontMatch
    }

    var digits: [Character] { Array(code.filter(\.isNumber)) }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                ResultBadge(symbol: "checkmark", size: 88)
                Text(verbatim: "Paired with \(macName)").font(Typo.title1).foregroundStyle(Tokens.fg)
                    .multilineTextAlignment(.center)
                Text("Check that this code matches the one on your Mac.")
                    .font(Typo.callout).foregroundStyle(Tokens.fg2).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    ForEach(Array(digits.enumerated()), id: \.offset) { index, digit in
                        Text(String(digit))
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Tokens.fg)
                            .frame(width: 44, height: 58)
                            .background(Tokens.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.leading, index == 3 ? 14 : 0)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Verification code \(digits.map(String.init).joined(separator: " "))")
                .padding(.top, 6)
                Label("Connected through an encrypted relay", systemImage: "lock.fill")
                    .font(Typo.footnote).foregroundStyle(Tokens.fg2)
            }
            .padding(.horizontal, 28)
            Spacer()
            VStack(spacing: 6) {
                if waiting {
                    HStack(spacing: 8) {
                        Spinner(tint: Tokens.accentfg)
                        Text("Confirm on your Mac").font(Typo.headline).foregroundStyle(Tokens.fg2)
                    }
                    .frame(minHeight: 56)
                } else {
                    PrimaryButton("Codes Match", height: 56, action: match)
                }
                Button(action: dontMatch) {
                    Text("Codes Don't Match").font(Typo.headline).foregroundStyle(Tokens.red)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Tokens.bg2)
    }
}
