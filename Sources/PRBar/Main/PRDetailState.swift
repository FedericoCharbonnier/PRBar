import PRBarCore
import SwiftUI

/// El modo foco y el chat del detalle de una ventana (la principal tiene uno; cada ventana de PR, el suyo).
@MainActor
final class PRDetailState: ObservableObject {
    @Published var focus = FocusModeState()
}
