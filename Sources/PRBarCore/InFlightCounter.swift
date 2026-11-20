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

/// Operaciones que no pueden correr dos veces a la vez con la misma clave (publicar el review de un draft desde la
/// ventana y desde `prbar` a la vez daría dos reviews en GitHub).
@MainActor
public final class ExclusiveRuns<Key: Hashable>: ObservableObject {
    @Published public private(set) var running: Set<Key> = []

    public init() {}

    public func contains(_ key: Key) -> Bool { running.contains(key) }

    /// Corre `body` si no hay otra con `key` en curso; si la hay, lanza `busy` sin correrlo.
    public func run<T>(_ key: Key, busy: @autoclosure () -> Error,
                       _ body: @MainActor () async throws -> T) async throws -> T {
        guard running.insert(key).inserted else { throw busy() }
        defer { running.remove(key) }
        return try await body()
    }
}
