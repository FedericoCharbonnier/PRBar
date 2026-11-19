import AppKit
import Foundation

/// Textos de "Responder" que explican qué corre y dónde (spec §14.2 y §14.5).
public enum RespondCopy {
    /// PRBar nunca toca el clone del usuario: los fixes viven en su propio worktree hasta el push.
    public static let ownWorktreeNote = "PRBar always uses its own worktree; after the push, run “git pull” in your clone."

    /// Debajo del diff cuando se cortó.
    public static let diffTruncatedNote = "The diff is very long: showing the first \(FixImplementer.maxDiffLines) lines (diff truncated; review the rest in the worktree)."

    /// El texto del alerta de confirmación del push.
    public static func pushConfirmation(account: String, worktree: String, headRef: String, sha: String) -> String {
        "PRBar will push \(sha.prefix(12)) (what you reviewed) to \(headRef) from its worktree (\(worktree)) and post "
            + "the replies as @\(account). The push runs your hooks (pre-push) in that worktree, on the code "
            + "Claude wrote. Afterwards, run “git pull” in your clone."
    }
}

/// Alerta de confirmación de una acción que no se puede deshacer (pushear, publicar, aprobar): **Return
/// cancela** (es el botón por defecto); la acción no tiene atajo y necesita un clic.
@MainActor
public enum ConfirmAlert {
    public static func make(title: String, message: String, action: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        let confirm = alert.addButton(withTitle: action)
        confirm.keyEquivalent = ""
        confirm.hasDestructiveAction = true
        return alert
    }

    /// Solo el segundo botón (la acción) confirma.
    public static func confirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }

    /// Muestra la alerta como hoja de la ventana activa (o modal si no hay) y llama a `action` solo si se confirmó.
    public static func present(title: String, message: String, action: String, perform: @escaping @MainActor () -> Void) {
        let alert = make(title: title, message: message, action: action)
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in
                if confirmed(response) { MainActor.assumeIsolated { perform() } }
            }
        } else if confirmed(alert.runModal()) {
            perform()
        }
    }
}
