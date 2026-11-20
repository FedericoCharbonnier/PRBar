import Foundation
import PRBarCore

enum UpdatePromptTests {
    static let cases: [TestCase] = [
        TestCase("update prompt: sin versión ofrecida ni instalación no hay botón") {
            try expectEqual(UpdatePrompt(availableVersion: nil, isInstalling: false), nil)
        },
        TestCase("update prompt: con una versión ofrecida, \"Update\" habilitado y la versión en el tooltip") {
            let prompt = try UpdatePrompt(availableVersion: "1.3.0", isInstalling: false).unwrap("prompt")
            try expectEqual(prompt, .available(version: "1.3.0"))
            try expectEqual(prompt.title, "Update")
            try expectEqual(prompt.help, "PRBar 1.3.0 is available — Update")
            try expect(prompt.isEnabled)
        },
        TestCase("update prompt: instalando gana sobre la oferta y deshabilita el botón") {
            for version in ["1.3.0", nil] {
                let prompt = try UpdatePrompt(availableVersion: version, isInstalling: true).unwrap("prompt")
                try expectEqual(prompt, .installing)
                try expectEqual(prompt.title, "Updating…")
                try expectEqual(prompt.help, "Updating PRBar…")
                try expect(!prompt.isEnabled)
            }
        },
        TestCase("update prompt: el ítem del menú de la app") {
            try expectEqual(UpdatePrompt.menuTitle(availableVersion: nil), "Check for Updates…")
            try expectEqual(UpdatePrompt.menuTitle(availableVersion: "1.3.0"), "Update to PRBar 1.3.0…")
        },
        TestCase("update prompt: la descripción de VoiceOver del ícono de la barra de menú") {
            try expectEqual(UpdatePrompt.statusItemAccessibilityLabel(state: "3 PRs need your action", prompt: nil),
                            "PRBar, 3 PRs need your action")
            try expectEqual(UpdatePrompt.statusItemAccessibilityLabel(state: "1 PR needs your action",
                                                                      prompt: .available(version: "1.3.0")),
                            "PRBar, 1 PR needs your action, update available")
            try expectEqual(UpdatePrompt.statusItemAccessibilityLabel(state: "offline", prompt: .installing),
                            "PRBar, offline, updating")
        },
    ]
}
