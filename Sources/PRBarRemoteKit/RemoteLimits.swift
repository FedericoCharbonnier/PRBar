import Foundation

/// Los topes de la Mac por teléfono (spec Q.4): un teléfono emparejado (o robado y desbloqueado) no puede inundar la
/// Mac de comandos, y un relay malicioso no puede hacerla trabajar repitiendo primeros mensajes de Noise.
public struct RemoteLimits: Equatable, Sendable {
    /// Pedidos ejecutándose a la vez por sesión (los `--wait` largos ocupan uno hasta terminar).
    public var maxConcurrentRequests: Int
    /// Pedidos (`req` y `sub`) por dispositivo: ráfaga y ritmo sostenido.
    public var requestBurst: Int
    public var requestsPerSecond: Double
    /// Handshakes de Noise KK por dispositivo (cada uno son cuatro Diffie-Hellman): ráfaga y ritmo sostenido.
    public var handshakeBurst: Int
    public var handshakesPerMinute: Double

    public init(maxConcurrentRequests: Int, requestBurst: Int, requestsPerSecond: Double, handshakeBurst: Int,
                handshakesPerMinute: Double) {
        self.maxConcurrentRequests = maxConcurrentRequests
        self.requestBurst = requestBurst
        self.requestsPerSecond = requestsPerSecond
        self.handshakeBurst = handshakeBurst
        self.handshakesPerMinute = handshakesPerMinute
    }

    /// 8 en curso; 30 pedidos de ráfaga y 5/s; 6 handshakes de ráfaga y 6/min. Una app de iPhone normal (abrir la app,
    /// suscribirse, unos toques) queda muy lejos; un bucle o un relay que repite mensajes se frena enseguida.
    public static let standard = RemoteLimits(maxConcurrentRequests: 8, requestBurst: 30, requestsPerSecond: 5,
                                              handshakeBurst: 6, handshakesPerMinute: 6)

    public static let tooManyRequestsMessage = "Too many requests from this iPhone. Wait a moment and try again."
}

/// Un balde de fichas con el reloj inyectado (los tests lo mueven a mano).
struct TokenBucket: Sendable {
    let capacity: Double
    let perSecond: Double
    private var tokens: Double
    private var updatedAt: Date

    init(capacity: Int, perSecond: Double, now: Date) {
        self.capacity = Double(max(capacity, 1))
        self.perSecond = max(perSecond, 0)
        tokens = self.capacity
        updatedAt = now
    }

    /// Gasta una ficha si hay.
    mutating func take(now: Date) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        tokens = min(capacity, tokens + elapsed * perSecond)
        updatedAt = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
