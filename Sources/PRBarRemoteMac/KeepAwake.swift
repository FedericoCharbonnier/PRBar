import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// De dónde saca la Mac la energía (protocolo para testear sin hardware).
public protocol PowerSourceReading: AnyObject {
    var isOnACPower: Bool { get }
    /// Avisa cuando cambia la fuente (en el hilo principal).
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
}

/// Toma y suelta la aserción que impide que la Mac duerma por inactividad.
public protocol SleepAssertionTaking: AnyObject {
    func take(name: String) -> UInt32?
    func release(_ id: UInt32)
}

/// "Keep this Mac awake while charging" (spec Q.1): con acceso remoto habilitado y en corriente toma
/// `PreventUserIdleSystemSleep` (la pantalla igual se apaga); en batería o al deshabilitar la suelta. Nunca dos a la vez.
@MainActor
public final class KeepAwake {
    public static let assertionName = "PRBar: iPhone remote access"

    private let power: any PowerSourceReading
    private let assertions: any SleepAssertionTaking
    private var wanted = false
    private var held: UInt32?
    private var observing = false

    public init(power: any PowerSourceReading, assertions: any SleepAssertionTaking) {
        self.power = power
        self.assertions = assertions
    }

    public var isHolding: Bool { held != nil }

    /// `enabled`: acceso remoto habilitado y el ajuste prendido.
    public func update(enabled: Bool) {
        wanted = enabled
        if enabled && !observing {
            observing = true
            power.startObserving { [weak self] in self?.apply() }
        }
        apply()
    }

    /// Lo llama el aviso de cambio de fuente.
    public func apply() {
        let hold = wanted && power.isOnACPower
        if hold, held == nil {
            held = assertions.take(name: Self.assertionName)
        } else if !hold, let id = held {
            assertions.release(id)
            held = nil
        }
    }
}

/// La fuente real: `IOPSGetProvidingPowerSourceType` y el aviso de IOKit.
public final class IOKitPowerSource: PowerSourceReading {
    private var source: CFRunLoopSource?
    private var callback: (@MainActor () -> Void)?

    public init() {}

    public var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        guard source == nil else { return }
        callback = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.callback?() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}

/// La aserción real (`IOPMAssertionCreateWithName`).
public final class IOKitSleepAssertion: SleepAssertionTaking {
    public init() {}

    public func take(name: String) -> UInt32? {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        return status == kIOReturnSuccess ? id : nil
    }

    public func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}
