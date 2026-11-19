import Combine
import Foundation

/// Cuántas operaciones de un tipo están en curso (p. ej. publicaciones en GitHub o Slack). Una actualización espera
/// a que lleguen a cero antes de reemplazar la app (spec D.3): cortar una publicación a la mitad puede dejarla a
/// medias o repetida.
@MainActor
public final class InFlightCounter: ObservableObject {
    @Published public private(set) var count = 0

    public init() {}

    /// Corre `body` contándolo como en curso (también si lanza).
    public func track<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        count += 1
        defer { count -= 1 }
        return try await body()
    }
}
