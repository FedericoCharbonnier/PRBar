import CryptoKit
import Foundation
import PRBarRemoteKit
import PRBarWire

enum SealedTests {
    typealias Priv = Curve25519.KeyAgreement.PrivateKey

    /// RFC 9180 A.2.3: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305, modo Auth. Copiado de
    /// https://raw.githubusercontent.com/cfrg/draft-irtf-cfrg-hpke/master/test-vectors.json (mode 2, kem 0x20, kdf 1,
    /// aead 3), que coincide con el apéndice del RFC.
    enum RFC9180 {
        static let info = "4f6465206f6e2061204772656369616e2055726e"
        static let skRm = "3ca22a6d1cda1bb9480949ec5329d3bf0b080ca4c45879c95eddb55c70b80b82"
        static let pkSm = "f0f4f9e96c54aeed3f323de8534fffd7e0577e4ce269896716bcb95643c8712b"
        static let enc = "f7674cc8cd7baa5872d1f33dbaffe3314239f6197ddf5ded1746760bfc847e0e"
        static let encryptions: [(aad: String, ct: String, pt: String)] = [
            ("436f756e742d30",
             "ab1a13c9d4f01a87ec3440dbd756e2677bd2ecf9df0ce7ed73869b98e00c09be111cb9fdf077347aeb88e61bdf",
             "4265617574792069732074727574682c20747275746820626561757479"),
            ("436f756e742d31",
             "3265c7807ffff7fdace21659a2c6ccffee52a26d270c76468ed74202a65478bfaedfff9c2b7634e24f10b71016",
             "4265617574792069732074727574682c20747275746820626561757479"),
            ("436f756e742d32",
             "3aadee86ad2a05081ea860033a9d09dbccb4acac2ded0891da40f51d4df19925f7a767b076a5cbc9355c8fd35e",
             "4265617574792069732074727574682c20747275746820626561757479"),
        ]
    }

    static func hex(_ text: String) throws -> Data {
        guard let data = Data(hexString: text) else { throw TestFailure(description: "hex inválido") }
        return data
    }

    static func payload(body: String = "Approved by Ana", title: String = "acme/web#12") -> PushPayload {
        PushPayload(id: UUID(uuidString: "6F1D8C2E-0B7A-4E55-9C61-3A2B9E0F4D11")!, createdAt: Date(timeIntervalSince1970: 1_800_000_000), kind: "approved", title: title, body: body,
                    threadId: "t", pr: "acme/web#12", deepLink: "prbar://pr/acme/web/12", badge: 3)
    }

    static let cases: [TestCase] = [
        TestCase("sealed: vector RFC 9180 A.2.3 (modo auth) abre con CryptoKit") {
            var recipient = try HPKE.Recipient(
                privateKey: Priv(rawRepresentation: hex(RFC9180.skRm)), ciphersuite: SealedEnvelope.suite,
                info: hex(RFC9180.info), encapsulatedKey: hex(RFC9180.enc),
                authenticatedBy: Curve25519.KeyAgreement.PublicKey(rawRepresentation: hex(RFC9180.pkSm)))
            for e in RFC9180.encryptions {
                try expectEqual(try recipient.open(try hex(e.ct), authenticating: try hex(e.aad)), try hex(e.pt))
            }
        },
        TestCase("sealed: push ida y vuelta (base64url); otro remitente, otro info o un byte cambiado fallan") {
            let mac = Priv(), device = Priv(), other = Priv()
            let info = SealedInfo.push(account: "acct", device: "dev1")
            let envelope = try payload().sealedForPush(from: mac, to: device.publicKey, info: info)
            let field = Base64URL.encode(envelope)
            try expectEqual(try PushPayload.open(pushField: field, by: device, from: mac.publicKey, info: info), payload())
            try expect((try? PushPayload.open(pushField: field, by: device, from: other.publicKey, info: info)) == nil)
            try expect((try? PushPayload.open(pushField: field, by: device, from: mac.publicKey,
                                               info: SealedInfo.push(account: "acct", device: "dev2"))) == nil)
            var raw = envelope
            raw[raw.startIndex + 40] ^= 1
            try expect((try? PushPayload.open(pushField: Base64URL.encode(raw), by: device, from: mac.publicKey,
                                               info: info)) == nil)
            // base64 estándar con relleno no es el formato del relay.
            if envelope.base64EncodedString() != field {
                try expect((try? PushPayload.open(pushField: envelope.base64EncodedString(), by: device,
                                                   from: mac.publicKey, info: info)) == nil)
            }
            // Un sobre de otro remitente que dice ser de la Mac no abre.
            let forged = try payload().sealedForPush(from: other, to: device.publicKey, info: info)
            try expect((try? PushPayload.open(pushField: Base64URL.encode(forged), by: device, from: mac.publicKey,
                                               info: info)) == nil)
        },
        TestCase("sealed: push largo se corta con … y el texto plano rellenado no pasa de 2048; relleno a 256") {
            let mac = Priv(), device = Priv()
            let info = SealedInfo.push(account: "a", device: "d")
            let long = payload(body: String(repeating: "ñandú ", count: 2_000))
            let envelope = try long.sealedForPush(from: mac, to: device.publicKey, info: info)
            try expect(envelope.count <= 32 + 2_048 + 16, "\(envelope.count)")
            try expectEqual(PushPayload.maxPlaintext, 2_048)
            let opened = try PushPayload.open(pushField: Base64URL.encode(envelope), by: device, from: mac.publicKey,
                                              info: info)
            try expect(opened.body.hasSuffix("…") && opened.body.count > 100 && long.body.hasPrefix(opened.body.dropLast()))
            try expectEqual(opened.title, long.title)
            // Lo justo: con un carácter más no entraría.
            var longer = opened
            longer.body = String(long.body.prefix(opened.body.count)) + "…"
            try expect(Padding.pad(try CommandProtocol.encoder.encode(longer), to: 256).count > 2_048)
            // Título enorme también se corta.
            let huge = payload(body: "x", title: String(repeating: "t", count: 5_000))
            let hugeEnvelope = try huge.sealedForPush(from: mac, to: device.publicKey, info: info)
            let opened2 = try PushPayload.open(pushField: Base64URL.encode(hugeEnvelope), by: device, from: mac.publicKey,
                                               info: info)
            try expect(opened2.title.hasSuffix("…") && opened2.body.isEmpty)
            // El largo del sobre es 32 + múltiplo de 256 + 16.
            let short = try payload().sealedForPush(from: mac, to: device.publicKey, info: info)
            try expectEqual((short.count - 48) % 256, 0)
            // Un campo más largo que el tope ni se intenta abrir.
            let tooLong = Base64URL.encode(Data(count: 32 + 2_048 + 16 + 256))
            try expect((try? PushPayload.open(pushField: tooLong, by: device, from: mac.publicKey, info: info)) == nil)
        },
        TestCase("sealed: relleno ida y vuelta y rechazos") {
            for n in [0, 1, 251, 252, 253, 1000] {
                let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0) })
                let padded = Padding.pad(data, to: 256)
                try expectEqual(padded.count % 256, 0)
                try expectEqual(try Padding.unpad(padded), data)
            }
            var bad = Padding.pad(Data([1, 2, 3]), to: 256)
            bad[bad.startIndex + 100] = 1
            try expect((try? Padding.unpad(bad)) == nil)                     // relleno no cero
            try expect((try? Padding.unpad(Data([0, 0, 1, 0]))) == nil)      // largo mayor que lo que hay
        },
        TestCase("sealed: buzón con rev; uno menor es rollback, otra ranura no abre") {
            let mac = Priv(), device = Priv()
            let blob = MailboxBlob(slot: "home", rev: 7, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   data: Data("{\"x\":1}".utf8))
            let sealed = try blob.seal(from: mac, to: device.publicKey, account: "a", device: "d")
            try expectEqual(try MailboxBlob.open(sealed, by: device, from: mac.publicKey, account: "a", device: "d",
                                                 slot: "home", minimumRev: 7), blob)
            do {
                _ = try MailboxBlob.open(sealed, by: device, from: mac.publicKey, account: "a", device: "d", slot: "home",
                                         minimumRev: 8)
                throw TestFailure(description: "aceptó un rev viejo")
            } catch let error as SealedError {
                try expectEqual(error, .rollback)
            }
            try expect((try? MailboxBlob.open(sealed, by: device, from: mac.publicKey, account: "a", device: "d",
                                              slot: "other", minimumRev: 0)) == nil)
        },
        TestCase("sealed: un blob del buzón de más de 7 días (o del futuro) no abre (revisión M2)") {
            let mac = Priv(), device = Priv()
            let created = Date(timeIntervalSince1970: 1_800_000_000)
            let sealed = try MailboxBlob(slot: "home", rev: 7, createdAt: created, data: Data("{}".utf8))
                .seal(from: mac, to: device.publicKey, account: "a", device: "d")
            func open(at now: Date) throws -> MailboxBlob {
                try MailboxBlob.open(sealed, by: device, from: mac.publicKey, account: "a", device: "d", slot: "home",
                                     minimumRev: 0, now: now)
            }
            try expectEqual(try open(at: created.addingTimeInterval(6 * 24 * 3600)).rev, 7)
            for now in [created.addingTimeInterval(7 * 24 * 3600 + 1), created.addingTimeInterval(-3600)] {
                do {
                    _ = try open(at: now)
                    throw TestFailure(description: "abrió un blob vencido")
                } catch let error as SealedError {
                    try expectEqual(error, .stale)
                }
            }
        },
        TestCase("sealed: identificadores de push opacos y estables") {
            let mac = Priv(), device = Priv(), device2 = Priv()
            let a = try PushIdentifiers(macSeal: mac, devicePush: device.publicKey)
            let b = try PushIdentifiers(devicePush: device, macSeal: mac.publicKey)
            let c = try PushIdentifiers(macSeal: mac, devicePush: device2.publicKey)
            try expectEqual(a.collapse(kind: "approved", pr: "o/r#1"), b.collapse(kind: "approved", pr: "o/r#1"))
            try expectEqual(a.thread(pr: "o/r#1"), b.thread(pr: "o/r#1"))
            try expect(a.collapse(kind: "approved", pr: "o/r#1") != c.collapse(kind: "approved", pr: "o/r#1"))
            try expect(a.collapse(kind: "approved", pr: "o/r#1") != a.collapse(kind: "approvedo", pr: "/r#1"))
            try expectEqual(a.collapse(kind: "k", pr: "p").count, 64)
            try expectEqual(a.thread(pr: "p").count, 32)
            try expect(a.collapse(kind: "k", pr: "p").allSatisfy { "0123456789abcdef".contains($0) })
        },
    ]
}
