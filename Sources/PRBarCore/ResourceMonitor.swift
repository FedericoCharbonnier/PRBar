import Combine
import Foundation

/// CPU/RAM cada `interval` (2 s) **solo** mientras haya una vista que los muestra (el popover o la ventana Activity),
/// y el disco en segundo plano, a lo sumo cada 60 s y al terminar un trabajo (spec I, decisiones I.1.7–8).
@MainActor
public final class ResourceMonitor: ObservableObject {
    public static let diskMinInterval: TimeInterval = 60

    @Published public private(set) var usage: ResourceUsage?
    @Published public private(set) var disk: DiskUsage?
    @Published public private(set) var scanningDisk = false

    private let sampler: ProcessSampler
    private let registry: ProcessRegistry
    private let interval: Duration
    private let diskScan: @Sendable () async -> DiskUsage
    /// Después de cada cálculo de disco (el umbral, en la app).
    public var onDisk: ((DiskUsage) -> Void)?

    private var consumers: Set<String> = []
    private var samplingTask: Task<Void, Never>?
    private var previous: ProcessSample?
    private var diskTask: Task<Void, Never>?
    /// Modo de capturas: los números quedan fijos (no se muestrea ni se escanea nada real).
    private var frozen = false

    public init(sampler: ProcessSampler, registry: ProcessRegistry = .shared, interval: Duration = .seconds(2),
                diskScan: @escaping @Sendable () async -> DiskUsage) {
        self.sampler = sampler
        self.registry = registry
        self.interval = interval
        self.diskScan = diskScan
    }

    public var isSampling: Bool { samplingTask != nil }

    /// `consumer`: "popover" o "activity".
    public func setVisible(_ consumer: String, _ visible: Bool) {
        guard !frozen else { return }
        if visible { consumers.insert(consumer) } else { consumers.remove(consumer) }
        if consumers.isEmpty {
            samplingTask?.cancel()
            samplingTask = nil
            previous = nil
        } else {
            if samplingTask == nil { startSampling() }
            refreshDisk(force: false)
        }
    }

    /// Un trabajo terminó: el disco cambió. Solo recalcula si alguien lo está mirando.
    public func jobFinished() {
        guard !consumers.isEmpty else {
            disk?.scannedAt = .distantPast
            return
        }
        refreshDisk(force: true)
    }

    public func refreshDisk(force: Bool) {
        guard diskTask == nil, !frozen else { return }
        if !force, let disk, Date().timeIntervalSince(disk.scannedAt) < Self.diskMinInterval { return }
        scanningDisk = true
        let scan = diskScan
        diskTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { await scan() }.value
            guard let self else { return }
            self.disk = result
            self.scanningDisk = false
            self.diskTask = nil
            self.onDisk?(result)
        }
    }

    /// Para `prbar resources`: una muestra de menos de 3 s, o dos nuevas separadas por 1 s.
    public func freshUsage() async -> ResourceUsage {
        if let usage, Date().timeIntervalSince(usage.sampledAt) < 3 { return usage }
        let sampler = self.sampler
        let first = await Task.detached { sampler.sample() }.value
        try? await Task.sleep(for: .seconds(1))
        let second = await Task.detached { sampler.sample() }.value
        return ResourceMeter.usage(previous: first, current: second, registered: registry.byPID())
    }

    /// Para `prbar resources`: el disco si tiene menos de 60 s; si no, lo calcula ahora.
    public func freshDisk() async -> DiskUsage {
        if let disk, Date().timeIntervalSince(disk.scannedAt) < Self.diskMinInterval { return disk }
        let scan = diskScan
        let result = await Task.detached(priority: .utility) { await scan() }.value
        disk = result
        onDisk?(result)
        return result
    }

    /// Modo de capturas: números fijos, sin muestrear ni escanear.
    public func applySnapshotState(usage: ResourceUsage, disk: DiskUsage) {
        frozen = true
        samplingTask?.cancel()
        samplingTask = nil
        self.usage = usage
        self.disk = disk
    }

    private func startSampling() {
        let sampler = self.sampler
        let interval = self.interval
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) { sampler.sample() }.value
                guard let self, !Task.isCancelled else { return }
                self.usage = ResourceMeter.usage(previous: self.previous, current: sample, registered: self.registry.byPID())
                self.previous = sample
                try? await Task.sleep(for: interval)
            }
        }
    }
}

/// Avisa una vez cada vez que el total cruza el umbral hacia arriba (decisión I.1.11).
public struct DiskWarningState: Equatable, Sendable {
    private var above = false

    public init() {}

    /// `true` = hay que avisar ahora.
    public mutating func update(total: Int64, limitGB: Int?) -> Bool {
        guard let limitGB else {
            above = false
            return false
        }
        let isAbove = total > Int64(limitGB) * 1_000_000_000
        defer { above = isAbove }
        return isAbove && !above
    }
}
