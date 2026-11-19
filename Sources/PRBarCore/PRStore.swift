import Foundation

@MainActor
public final class PRStore: ObservableObject {
    @Published public private(set) var snapshot: Snapshot?
    @Published public private(set) var isRefreshing = false

    private let builder: SnapshotBuilder
    private let configStore: ConfigStore
    private let stateStore: SnapshotStore
    private let now: () -> Date
    private let onChange: @MainActor (Snapshot?, Snapshot) -> Void
    private var loop: Task<Void, Never>?

    public init(
        builder: SnapshotBuilder,
        configStore: ConfigStore,
        stateStore: SnapshotStore = SnapshotStore(),
        now: @escaping () -> Date = { Date() },
        onChange: @escaping @MainActor (Snapshot?, Snapshot) -> Void
    ) {
        self.builder = builder
        self.configStore = configStore
        self.stateStore = stateStore
        self.now = now
        self.onChange = onChange
        self.snapshot = stateStore.load()
    }

    /// Quienes esperan que termine el refresco en curso (`refreshNow`).
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Refresca, salvo que ya haya un refresco en curso (entonces vuelve enseguida) o dure un rate limit.
    public func refresh() async {
        guard !isRefreshing else { return }
        if let until = snapshot?.rateLimitedUntil, until > now() { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.resume() }
        }

        let previous = snapshot
        let next = await builder.build(config: configStore.config, previous: previous)
        snapshot = next
        stateStore.save(next)
        onChange(previous, next)
    }

    /// Un refresco que empieza después de este pedido (p. ej. tras un merge): si hay uno en curso (que pudo empezar
    /// antes), lo espera y refresca de nuevo; si mientras tanto empezó otro, alcanza con esperarlo. Durante un rate
    /// limit no refresca.
    public func refreshNow() async {
        if isRefreshing { await waitForCurrentRefresh() }
        if isRefreshing {
            await waitForCurrentRefresh()
            return
        }
        await refresh()
    }

    private func waitForCurrentRefresh() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let minutes = max(1, self.configStore.config.refreshIntervalMinutes)
                try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }
}
