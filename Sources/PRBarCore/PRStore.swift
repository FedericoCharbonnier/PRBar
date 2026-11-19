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

    public func refresh() async {
        guard !isRefreshing else { return }
        if let until = snapshot?.rateLimitedUntil, until > now() { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previous = snapshot
        let next = await builder.build(config: configStore.config, previous: previous)
        snapshot = next
        stateStore.save(next)
        onChange(previous, next)
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
