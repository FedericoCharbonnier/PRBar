import Foundation
import PRBarCore

enum UpdatePolicyTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func check(
        installed: String = "1.2.0", settings: UpdateSettings = UpdateSettings(),
        notifications: NotificationSettings = NotificationSettings(), manual: Bool = false,
        transport: HTTPTransport = FakeTransport([(200, [:], releaseJSON(tag: "v1.3.0"))])
    ) async -> UpdateCheckReport {
        await UpdateChecker(transport: transport, repo: "a/b").check(
            installed: SemanticVersion(installed)!, settings: settings, notifications: notifications, manual: manual, now: now
        )
    }

    static let cases: [TestCase] = [
        TestCase("update policy: toca chequear según el intervalo") {
            var settings = UpdateSettings()
            try expect(UpdatePolicy.isCheckDue(settings, now: now))
            settings.lastCheckAt = now.addingTimeInterval(-23 * 3600)
            try expect(!UpdatePolicy.isCheckDue(settings, now: now))
            settings.lastCheckAt = now.addingTimeInterval(-24 * 3600)
            try expect(UpdatePolicy.isCheckDue(settings, now: now))
            settings.lastCheckAt = now.addingTimeInterval(3600)   // el reloj volvió para atrás
            try expect(UpdatePolicy.isCheckDue(settings, now: now))
            settings.checkIntervalHours = 0
            settings.lastCheckAt = nil
            try expect(!UpdatePolicy.isCheckDue(settings, now: now))
        },
        TestCase("update policy: versión nueva → se ofrece y se notifica una vez") {
            let report = await check()
            let release = report.offered
            try expectEqual(release?.version, SemanticVersion(1, 3, 0))
            guard case .available(let available) = report.outcome else { throw TestFailure(description: "\(report.outcome)") }
            try expectEqual(available.tag, "v1.3.0")
            try expectEqual(report.notification?.title, "PRBar 1.3.0 is available")
            try expectEqual(report.notification?.body, "Faster refresh")
            try expectEqual(report.notification?.updateVersion, "1.3.0")
            try expectEqual(report.settings.notifiedVersion, "1.3.0")
            try expectEqual(report.settings.lastCheckAt, now)
            try expectEqual(report.visibleError, nil)
        },
        TestCase("update policy: misma versión o más vieja → al día") {
            for installed in ["1.3.0", "1.4.0"] {
                let report = await check(installed: installed)
                try expectEqual(report.outcome, .upToDate(installed: SemanticVersion(installed)!))
                try expectEqual(report.offered, nil)
                try expectEqual(report.notification, nil)
                try expectEqual(report.settings.lastCheckAt, now)
            }
        },
        TestCase("update policy: sin releases → al día") {
            let report = await check(transport: FakeTransport([(404, [:], "{}")]))
            try expectEqual(report.outcome, .upToDate(installed: SemanticVersion(1, 2, 0)))
            try expectEqual(report.offered, nil)
        },
        TestCase("update policy: versión salteada → no se ofrece sola; a mano sí, sin notificar") {
            var settings = UpdateSettings()
            settings.skippedVersion = "1.3.0"
            let automatic = await check(settings: settings)
            guard case .available = automatic.outcome else { throw TestFailure(description: "\(automatic.outcome)") }
            try expectEqual(automatic.offered, nil)
            try expectEqual(automatic.notification, nil)
            try expectEqual(automatic.settings.notifiedVersion, nil)
            let manual = await check(settings: settings, manual: true)
            try expectEqual(manual.offered?.version, SemanticVersion(1, 3, 0))
            try expectEqual(manual.notification, nil)
        },
        TestCase("update policy: salteada una vieja, sale otra → se ofrece") {
            var settings = UpdateSettings()
            settings.skippedVersion = "v1.2.5"
            let report = await check(settings: settings)
            try expectEqual(report.offered?.version, SemanticVersion(1, 3, 0))
            try expect(report.notification != nil)
        },
        TestCase("update policy: ya notificada → se ofrece sin volver a notificar") {
            var settings = UpdateSettings()
            settings.notifiedVersion = "1.3.0"
            let report = await check(settings: settings)
            try expectEqual(report.offered?.version, SemanticVersion(1, 3, 0))
            try expectEqual(report.notification, nil)
        },
        TestCase("update policy: chequeo manual → no notifica") {
            let report = await check(manual: true)
            try expectEqual(report.offered?.version, SemanticVersion(1, 3, 0))
            try expectEqual(report.notification, nil)
            try expectEqual(report.settings.notifiedVersion, nil)
        },
        TestCase("update policy: notificaciones apagadas → no notifica ni marca notificada") {
            var notifications = NotificationSettings()
            notifications.enabled = false
            let report = await check(notifications: notifications)
            try expectEqual(report.offered?.version, SemanticVersion(1, 3, 0))
            try expectEqual(report.notification, nil)
            try expectEqual(report.settings.notifiedVersion, nil)
        },
        TestCase("update policy: error de red silencioso en el automático, visible en el manual") {
            let automatic = await check(transport: OfflineTransport())
            guard case .failed(let message) = automatic.outcome else { throw TestFailure(description: "\(automatic.outcome)") }
            try expect(message.hasPrefix("Couldn't check for updates"), message)
            try expectEqual(automatic.visibleError, nil)
            try expectEqual(automatic.offered, nil)
            try expectEqual(automatic.settings, UpdateSettings())
            let manual = await check(manual: true, transport: OfflineTransport())
            try expectEqual(manual.visibleError, message)
        },
        TestCase("update policy: la notificación de actualización") {
            let planned = NotificationPlanner.updateAvailable(makeRelease("1.3.0", notes: "# Title"), settings: NotificationSettings())
            try expectEqual(planned?.kind, .updateAvailable)
            try expectEqual(planned?.body, "Open PRBar to update.")
            try expectEqual(planned?.identifier, "updateAvailable:1.3.0:group")
            try expectEqual(planned?.url, nil)
            var off = NotificationSettings()
            off.enabled = false
            try expect(NotificationPlanner.updateAvailable(makeRelease("1.3.0"), settings: off) == nil)
        },
    ]
}
