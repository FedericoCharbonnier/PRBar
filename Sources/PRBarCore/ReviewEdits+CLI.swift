import Foundation

/// Lo que la CLI necesita del estado de la ventana de Review (`ReviewEdits`, plan 6): referirse a un hallazgo por
/// `#N` o por id, editar sin marcar como editado un texto igual al original, "Select All" y publicar con `--only`.
extension ReviewEdits {
    /// `"3"` (#N, la numeración de la ventana y del chat) o el id (`"f2"`, `"c1"`) → el ítem con el título editado.
    public func item(_ reference: String, in draft: ReviewDraft) -> ReviewItem? {
        let items = items(of: draft)
        if let number = Int(reference) {
            return items.indices.contains(number - 1) ? items[number - 1] : nil
        }
        return items.first { $0.id == reference }
    }

    /// El ítem tal como vino (sin el título editado): el draft o lo que agregó el chat.
    private func original(_ id: String, in draft: ReviewDraft) -> ReviewItem? {
        (draft.items + added).first { $0.id == id }
    }

    public mutating func setBody(_ text: String, for id: String, in draft: ReviewDraft) {
        guard let item = original(id, in: draft) else { return }
        bodies[id] = text == item.finding.body ? nil : text
    }

    public mutating func setTitle(_ text: String, for id: String, in draft: ReviewDraft) {
        guard let item = original(id, in: draft) else { return }
        titles[id] = text == item.finding.title ? nil : text
    }

    /// "Select All" de la ventana: suma los que mantuvo el filtro y no ocultan las opciones del review (y los que
    /// agregó el chat); los descartados u ocultos que ya estaban elegidos siguen elegidos.
    public mutating func selectAllKept(in draft: ReviewDraft) {
        selected.formUnion(items(of: draft).filter { $0.keep && !$0.isHidden }.map(\.id))
    }

    /// Lo que se publica: con `only`, esos ids (en el orden de la ventana) en vez de la selección.
    public func comments(of draft: ReviewDraft, only: Set<String>?) -> [SelectedComment] {
        guard let only else { return selectedComments(of: draft) }
        return items(of: draft).filter { only.contains($0.id) }.map { SelectedComment(finding: $0.finding, body: body(of: $0)) }
    }
}

/// `prbar respond select <pr> <n|id>`: un comentario del análisis por su posición (desde 1, la de la ventana y del
/// chat) o por su id (`thread:…`, `review:…`).
public enum RespondItemReference {
    public static func itemID(_ reference: String, in draft: RespondDraft) -> String? {
        if let number = Int(reference) {
            return draft.items.indices.contains(number - 1) ? draft.items[number - 1].id : nil
        }
        return draft.items.first { $0.id == reference }?.id
    }
}
