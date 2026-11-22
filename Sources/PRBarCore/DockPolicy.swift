/// El ícono en el Dock (spec M.5): `.regular` mientras haya una ventana abierta (principal, de PR o Settings) o con
/// "Always show in Dock"; `.accessory` sin ventanas. Sobre otra app en pantalla completa no se pasa a `.regular`
/// (moverían al usuario de Space, `WindowSpaces`): se reintenta al salir de ese Space.
public enum DockPolicy {
    public enum Policy: Equatable, Sendable { case regular, accessory }

    /// La política a poner, o nil para dejar la actual.
    public static func policy(openWindows: Int, alwaysShowInDock: Bool, otherAppFullScreen: Bool,
                              current: Policy) -> Policy? {
        let wanted: Policy = alwaysShowInDock || openWindows > 0 ? .regular : .accessory
        guard wanted != current else { return nil }
        if wanted == .regular && otherAppFullScreen { return nil }
        return wanted
    }
}
