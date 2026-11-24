import AppKit
import Combine
import PRBarCore
import PRBarRemoteMac
import SwiftUI

struct ResolvedTools: Equatable, Sendable {
    var gh: String?
    var git: String?
    var claude: String?
}

/// GitHub rechazó (422) una review con comentarios inline: se puede reintentar con todo en el body.
struct InlineCommentsRejected: LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        "GitHub rejected the inline comments (\(underlying.localizedDescription)). You can post everything in the review body instead."
    }
}

/// Lo que `AppModel` usa por fuera de sí. `live()` es la app real; el modo de capturas (`SnapshotMode`) arma uno
/// en memoria, con APIs falsas y archivos en una carpeta temporal propia.
@MainActor
struct AppModelServices {
    var configStore: ConfigStore
    var stateStore: SnapshotStore
    var accounts: AccountProvider
    var api: any GitHubAPI
    var slack: SlackAnnouncer
    /// `nil`: no se entregan notificaciones.
    var notifications: NotificationDelivery?
    var history: ReviewHistory
    var respondHistory: RespondHistory
    var claudeSkills: ClaudeSkills
    /// `nil`: el pipeline real (`LiveReviewPipeline` / `LiveRespondPipeline`).
    var reviewPipeline: (any ReviewPipelineRunning)?
    var respondPipeline: (any RespondPipelineRunning)?
    /// `nil`: the real chat backend (`LiveChatBackend`).
    var chatBackend: (any ChatBackend)? = nil
    /// Para chequear los releases en GitHub (spec D.2). El modo de capturas nunca chequea.
    var updateTransport: any HTTPTransport = URLSessionTransport()
    /// `nil`: `instructions.json` in Application Support.
    var instructionsStore: InstructionsStore? = nil
    /// `nil`: the real instructions chat (`LiveInstructionsChatBackend`).
    var instructionsChatBackend: (any InstructionsChatBackend)? = nil
    /// `nil`: `discard-stats.json` in Application Support.
    var discardStats: DiscardStatsStore? = nil
    /// `nil`: `history/merge/` in Application Support (spec G.4).
    var mergeHistory: MergeHistory? = nil
    /// Dónde se guarda la pestaña del popover (spec H.1). `nil`: solo en memoria; lo usa el modo de capturas para no
    /// tocar el del usuario ni escribir fuera de su carpeta.
    var popoverDefaults: UserDefaults? = .standard
    /// `nil`: `usage.json` in Application Support (spec O).
    var usageLedger: UsageLedger? = nil
    /// El acceso desde el iPhone (spec Q). `nil`: sin red ni llavero (el modo de capturas).
    var remoteAccess: RemoteServiceEnvironment? = nil
    /// `nil`: `retained-worktrees.json` in Application Support (spec T.3).
    var retainedWorktrees: RetainedWorktreeStore? = nil

    static func live(runner: SystemProcessRunner) -> AppModelServices {
        let accounts = AccountProvider(runner: runner, ghPath: nil)
        let configStore = ConfigStore()
        let keychain = KeychainStore()
        // Sin provider guardado: el conector de Claude, salvo que ya haya un token de usuario (solo atributos, así
        // abrir la app no pide permiso al Llavero).
        // No con una config que no se pudo leer: guardar los defaults pisaría el archivo del usuario.
        if !configStore.config.slack.providerChosen && configStore.savesAutomatically {
            let hasToken = (try? keychain.exists(SlackAnnouncer.tokenKey)) ?? false
            do {
                try configStore.update { $0.resolveDefaultSlackProvider(hasUserToken: hasToken) }
            } catch {
                AppLog.write("Couldn't save the default Slack provider: \(error)")
            }
        }
        // La API real se arma en `rebuildSlackAPI()` cuando se conoce la ruta de claude (antes del primer refresco).
        let slack = SlackAnnouncer(api: SlackClient(), provider: configStore.config.slack.provider, secrets: keychain)
        var services = AppModelServices(
            configStore: configStore, stateStore: SnapshotStore(), accounts: accounts, api: GitHubClient(), slack: slack,
            notifications: NotificationDelivery(), history: ReviewHistory(), respondHistory: RespondHistory(),
            claudeSkills: ClaudeSkills()
        )
        services.remoteAccess = .live(macName: Host.current().localizedName ?? "Mac",
                                      appVersion: AppVersion.current())
        return services
    }
}

/// Cierra el panel del ícono (`AppModel.closePopover`).
typealias PopoverCloser = @MainActor () -> Void

@MainActor
final class AppModel: ObservableObject {
    let configStore: ConfigStore
    let prStore: PRStore
    let accounts: AccountProvider
    let api: any GitHubAPI
    let runner: SystemProcessRunner
    let slack: SlackAnnouncer
    let notifications: NotificationDelivery?
    let history: ReviewHistory
    /// Los skills que ofrece Configuración → Claude.
    let claudeSkills: ClaudeSkills
    private let reviewPipeline: (any ReviewPipelineRunning)?
    private let respondPipeline: (any RespondPipelineRunning)?
    private let chatBackendOverride: (any ChatBackend)?
    private let instructionsChatBackendOverride: (any InstructionsChatBackend)?
    /// Settings › Instructions' chat (spec E.2). `lazy` so it can capture `self` (weakly).
    private(set) lazy var instructionsChat = InstructionsChatCoordinator(
        store: instructions,
        backend: instructionsChatBackendOverride ?? LiveInstructionsChatBackend(context: { [weak self] in
            (self?.tools.claude, self?.configStore.config.claude.effectiveChatModel)
        }),
        scheduler: chatScheduler,
        repos: { [weak self] in self?.configuredRepos ?? [] },
        promptBody: { [weak self] in self?.configStore.config.claude.chatPromptBody(.instructionsChat) }
    )
    private let updateTransport: any HTTPTransport
    /// Chat turns running at once across the app (spec B.4): at most 2, one per PR.
    let chatScheduler = JobScheduler<String>(maxConcurrent: ChatCoordinator.maxConcurrentChats)
    /// The chat backend. `lazy` like the queues, so it can capture `self` (weakly).
    private(set) lazy var chatBackend: any ChatBackend = chatBackendOverride ?? LiveChatBackend(
        runner: runner, tokens: accounts, api: api,
        context: { [weak self] account, repo in self?.jobContext(account: account, repo: repo) ?? .closed }
    )
    /// One coordinator per draft (Review or Respond): reopening a window keeps the conversation and the edits.
    private var chats: [UUID: ChatCoordinator] = [:]
    /// Repos, ramas y usuarios de GitHub para los selectores de Configuración, cacheados durante la sesión.
    private(set) lazy var catalog = GitHubCatalog(api: api, tokens: accounts)
    /// Dónde corre Claude (spec J). Un solo coordinador: comparte la caché de salud de los destinos.
    let runners = RunnerCoordinator(makeHost: { try await RunnerCoordinator.liveHost($0) })
    /// La última verificación ("Test Connection") de cada destino, por nombre (Settings y `prbar runners`).
    @Published var runnerChecks: [String: RunnerHostInfo] = [:]
    /// Dónde corrió el último trabajo de cada PR ("on devbox" / "Ran on this Mac — …") y el último fallback de cada
    /// repo (el aviso de Settings › Repos). En memoria (spec J.4).
    @Published var placements = RunnerPlacements()
    /// `git --version` y `claude --version` de esta Mac (fila "This Mac" de Run On), para las rutas `tools`.
    @Published var localToolVersions: LocalToolVersions?
    /// Cola de reviews. Es `lazy` para que el pipeline y `onFinished` puedan capturar `self` (débil).
    private(set) lazy var reviews = ReviewQueue(
        pipeline: reviewPipeline ?? LiveReviewPipeline(
            runner: runner, tokens: accounts, logURLProvider: { [history] in history.logURL(for: $0) },
            context: { [weak self] account, repo in self?.jobContext(account: account, repo: repo) ?? .closed }
        ),
        onFinished: { [weak self] request, result in self?.reviewFinished(request, result) }
    )
    /// Corridas de "Responder" (spec §14), en `history/respond/`.
    let respondHistory: RespondHistory
    /// The folders kept for "Open in Terminal" (spec T.3), saved in `retainedStore`. Changed only through
    /// `AppModel+Sessions` (`setRetained`), which saves it.
    @Published var retainedWorktrees: [RetainedWorktree] = []
    let retainedStore: RetainedWorktreeStore
    /// The merged/closed check of kept folders in flight (one at a time).
    var retainedPrune: Task<Void, Never>?
    /// When each PR that left the list was last asked about (`RetainedWorktreeRules.stateCheckInterval`).
    var retainedCheckedAt: [String: Date] = [:]
    /// Which kept folders PRBar is working in, for the Terminal buttons and ⌥⌘T (`SessionBusyMonitor`).
    private(set) lazy var sessionBusy = SessionBusyMonitor(model: self)
    /// Rules, suggestion decisions and the instructions chat (spec E).
    let instructions: InstructionsStore
    /// The findings the user discards when posting (spec E.4).
    let discardStats: DiscardStatsStore
    /// Goes up when a post records discards (the suggestions change).
    @Published private(set) var discardRevision = 0
    /// Cola de "Responder" en los PRs propios con feedback. `lazy` por lo mismo que `reviews`.
    private(set) lazy var respond = RespondQueue(
        pipeline: respondPipeline ?? LiveRespondPipeline(
            runner: runner, tokens: accounts, api: api, history: respondHistory,
            context: { [weak self] account, repo in self?.jobContext(account: account, repo: repo) ?? .closed }
        ),
        history: respondHistory,
        onEvent: { [weak self] prID, phase in self?.respondEvent(prID: prID, phase: phase) },
        onRetain: { [weak self] record in self?.retainRespond(record) }
    )
    /// Actualizaciones (spec D). `lazy` por lo mismo que `reviews`: sus closures capturan `self` (débil).
    private(set) lazy var updates = UpdateController(
        configStore: configStore, transport: updateTransport, runner: runner, notifications: notifications,
        gitPath: { [weak self] in self?.tools.git },
        activeJobs: { [weak self] in self?.activeJobCount ?? 0 },
        cancelJobs: { [weak self] in self?.cancelJobsForUpdate() },
        unpushedFixes: { [weak self] in self?.respond.unpushedWork.count ?? 0 }
    )
    /// Publicaciones en GitHub (review) y Slack en curso: una actualización las espera (spec D.3). Las de Responder
    /// ya cuentan por su fase (`pushing`).
    let postings: InFlightCounter
    /// Clean Up en curso (decisión I.1.19): una actualización lo espera antes de tocar `source/` o `update-staging/`.
    let cleanups = InFlightCounter()
    /// Merges de Ready to Merge (spec F.3). `lazy` por lo mismo que `reviews`. Mientras se instala una actualización
    /// no empieza ninguno (`jobsBlockedReason`).
    private(set) lazy var merges = MergeQueue(
        api: api, tokens: accounts,
        blockedReason: { [weak self] in self?.jobsBlockedReason },
        onMerged: { [weak self] completion in self?.mergeFinished(completion) }
    )
    /// CPU/RAM/disco de PRBar (spec I). `lazy` porque su escaneo de disco lee la config y los drafts de `self`.
    private(set) lazy var resources: ResourceMonitor = makeResourceMonitor()
    /// Para avisar una vez por cruce del umbral (spec I).
    var diskWarning = DiskWarningState()
    /// Limpieza de worktrees huérfanos del arranque; cada review la espera antes de crear el suyo.
    private(set) var orphanCleanup: Task<Void, Never>?
    /// Cuándo se pidió cada review (por prID) y si la pidió un iPhone: el `ReviewRecord` y el grupo Claude.
    @Published private(set) var reviewRuns: [String: ClaudeRunInfo] = [:]
    /// Los PRs cuyo último merge lo pidió un iPhone (el registro de History lleva el ícono, spec M.4).
    var phoneMerges: Set<String> = []
    /// La ventana principal (spec M.1): sobrevive a cerrarla con ⌘W.
    let main = MainWindowState()
    /// Cuándo empezó y terminó cada etapa (Analyzing · Implementing · Running tests) del Respond / Fix CI de cada PR: la
    /// tarjeta de progreso de la pestaña. Lo llena `respondTimelineObserver` con cada cambio de fase.
    @Published private(set) var respondTimelines: [String: RespondStageTimeline] = [:]
    private var respondTimelineObserver: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    /// Chats discarded while a turn was running, until it ends (`discardChat`).
    private var retiringChats: [UUID: ChatCoordinator] = [:]
    /// El socket de `prbar` (spec C.2); `nil` en el modo de capturas o si no se pudo abrir.
    var commandServer: CommandServer?
    /// Re-renders the views that use `jobsBlockedReason` when an update starts or ends.
    private var installStateObserver: AnyCancellable?
    /// Los drafts cuyo review se está publicando (ventana o `prbar`): no se publica dos veces a la vez.
    let publishingReviews = ExclusiveRuns<UUID>()
    private var publishingObserver: AnyCancellable?
    /// Descarta las fases de merge de los PRs que ya no están en cada snapshot nuevo (spec F.8.10), aunque el refresco
    /// de después del merge no haya podido correr.
    private var mergePruneObserver: AnyCancellable?
    /// Con cada snapshot, el PR de la ventana principal pasa a su sección (`MainWindowState.reconcile`).
    private var mainSectionObserver: AnyCancellable?
    /// Una sesión de merge por PR (ventana, chat y registro del historial; spec G, `AppModel+Merge`).
    var mergeSessions: [String: MergeSession] = [:]
    /// Los merges hechos desde PRBar y sus chats (spec G.4).
    let mergeHistory: MergeHistory
    /// La pestaña elegida del popover (spec H).
    let popoverTab: PopoverTabState
    /// Abre el panel de la barra de menú (`StatusItemController.show`); `false` si no pudo. Lo pone `AppDelegate`.
    var showPopover: (() -> Bool)?
    /// Cierra el panel (lo asigna `AppDelegate`): una alerta desde el panel lo cierra antes (`confirmFromPopover`).
    var closePopover: PopoverCloser?
    /// La fila elegida con ↑/↓ en el popover.
    let popoverRows = PopoverRowSelection()
    /// Claude's usage, one entry per run (spec O). Written from any thread by `ClaudeUsageCenter`'s observer.
    let usageLedger: UsageLedger
    /// Goes up when a Claude run is recorded (Activity and History refresh their costs).
    @Published var usageRevision = 0
    /// The snapshot mode's "running" tasks' Claude usage (`liveClaudeUsage`); empty in the real app.
    var snapshotLiveUsage: [ProcessActivity: ClaudeUsage] = [:]
    /// El acceso desde el iPhone (spec Q). `lazy` porque guarda `self` como sus acciones y su config.
    private(set) lazy var remoteAccess = RemoteAccessService(settings: self, environment: remoteEnvironment)
    let remoteEnvironment: RemoteServiceEnvironment
    /// Avisos de cambios para el feed del iPhone y los chats que miran los teléfonos (AppModel+Remote).
    var remoteObservers: [AnyCancellable] = []
    /// Por id de la sesión del chat (no por la dirección del objeto, que se puede reusar; L8). Se borra al descartarlo.
    var remoteChatWatchers: [UUID: AnyCancellable] = [:]
    var remoteSystem: RemoteSystemObservers?

    @Published private(set) var tools = ResolvedTools()
    @Published private(set) var toolsResolved = false
    @Published private(set) var ghAccounts: [GHAccount] = []
    @Published private(set) var accountsError: String?
    @Published var settingsError: String?
    @Published private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    /// El usuario negó las notificaciones en Ajustes del Sistema (se muestra un aviso en Configuración).
    @Published private(set) var notificationsDenied = false
    /// Sube cada vez que cambia el historial de reviews (para recargar la ventana de Historial).
    @Published var historyRevision = 0 { didSet { publishedReviewIndex = nil } }
    /// The latest published review per PR (`publishedReviewRecord`), built on first use and dropped whenever the
    /// history changes; `publishNow` updates it in place.
    private var publishedReviewIndex: PublishedReviewIndex?
    /// Reviews publicados desde la ventana o la CLI, por id de draft: una ventana abierta pasa a "publicado".
    @Published private(set) var publishedReviews: [UUID: PublishedReview] = [:]

    /// La app real: arranca la búsqueda de herramientas, las cuentas, las notificaciones y el refresco.
    convenience init() {
        let runner = SystemProcessRunner()
        self.init(services: .live(runner: runner), runner: runner, startsServices: true)
    }

    /// Con `startsServices == false` no arranca nada (ni refresco, ni herramientas, ni notificaciones, ni limpieza de
    /// worktrees) y no se engancha a `WindowPresenter`: es lo que usa el modo de capturas.
    init(services: AppModelServices, runner: SystemProcessRunner = SystemProcessRunner(), startsServices: Bool) {
        let notifications = services.notifications
        let configStore = services.configStore
        let slack = services.slack
        let postings = InFlightCounter()
        self.postings = postings
        self.runner = runner
        self.accounts = services.accounts
        self.api = services.api
        self.configStore = configStore
        self.notifications = notifications
        self.slack = slack
        self.history = services.history
        self.respondHistory = services.respondHistory
        self.retainedStore = services.retainedWorktrees ?? RetainedWorktreeStore()
        self.retainedWorktrees = retainedStore.load()
        self.instructions = services.instructionsStore ?? InstructionsStore()
        self.discardStats = services.discardStats ?? DiscardStatsStore()
        self.mergeHistory = services.mergeHistory ?? MergeHistory()
        self.usageLedger = services.usageLedger ?? UsageLedger()
        self.remoteEnvironment = services.remoteAccess
            ?? .offline(directory: FileManager.default.temporaryDirectory.appendingPathComponent("prbar-remote-\(UUID().uuidString)"),
                        appVersion: "0")
        self.claudeSkills = services.claudeSkills
        self.reviewPipeline = services.reviewPipeline
        self.respondPipeline = services.respondPipeline
        self.chatBackendOverride = services.chatBackend
        self.instructionsChatBackendOverride = services.instructionsChatBackend
        self.updateTransport = services.updateTransport
        self.popoverTab = PopoverTabState(store: services.popoverDefaults)
        self.prStore = PRStore(
            builder: SnapshotBuilder(api: services.api, tokens: services.accounts),
            configStore: configStore,
            stateStore: services.stateStore,
            onChange: { previous, next in
                notifications?.deliver(
                    NotificationPlanner.plan(previous: previous, current: next, settings: configStore.config.notifications)
                )
                Task { await postings.track { await slack.process(snapshot: next, config: configStore.config) } }
            }
        )
        installStateObserver = updates.session.$state.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }
        publishingObserver = publishingReviews.$running.sink { [weak self] _ in self?.objectWillChange.send() }
        respondTimelineObserver = respond.$phases.combineLatest(respond.$runningTests)
            .sink { [weak self] phases, runningTests in self?.noteRespondStages(phases, runningTests: runningTests) }
        mergePruneObserver = prStore.$snapshot.dropFirst().compactMap { $0 }.sink { [weak self] snapshot in
            self?.merges.prune(keeping: Set(snapshot.items.map(\.id)))
            self?.reviews.dropOutdatedPublished(
                heads: Dictionary(snapshot.items.map { ($0.id, $0.pr.headOid) }, uniquingKeysWith: { first, _ in first }))
            self?.updateMergeSessions(snapshot)
            self?.pruneRetainedWorktrees(snapshot)
        }
        mainSectionObserver = prStore.$snapshot.compactMap { $0 }.sink { [weak self] snapshot in
            self?.main.reconcile(with: snapshot)
        }
        guard startsServices else { return }
        // Every `claude -p` of the app goes to the ledger (spec O.4.2).
        let ledger = usageLedger
        ClaudeUsageCenter.shared.setObserver { [weak self] entry in
            ledger.append(entry)
            Task { @MainActor in self?.usageRevision += 1 }
        }
        startCommandServer()
        startRemoteAccess()
        WindowPresenter.shared.openSettings = { [weak self] in self?.openSettings() }
        WindowPresenter.shared.navigate = { [weak self] in self?.navigate(to: $0) }
        WindowPresenter.shared.openMainWindow = { [weak self] in self?.openMainWindow() }
        WindowPresenter.shared.checkForUpdates = { [weak self] in self?.checkForUpdatesFromMenu() }
        WindowPresenter.shared.availableUpdate = { [weak self] in self?.updates.available?.version.description }
        WindowPresenter.shared.alwaysShowInDock = { [weak self] in self?.configStore.config.alwaysShowInDock ?? false }
        WindowCommandCenter.shared.refreshPRs = { [weak self] in
            guard let self else { return }
            Task { await self.prStore.refresh() }
        }
        notifications?.onOpen = { [weak self] target in self?.openNotificationTarget(target) }
        // Al salir se cancela todo (`cancelEverythingForQuit`; `AppDelegate` además espera a que terminen los procesos
        // y mata los que no). Los worktrees que queden los borra la limpieza de huérfanos del próximo arranque, salvo
        // los que tienen trabajo sin pushear.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelEverythingForQuit()
                // The usage ledger writes in the background: whatever is pending reaches the disk before quitting.
                self?.usageLedger.flush()
            }
        }
        // En segundo plano y sin esperar a nadie: cada host que responde limpia lo que quedó de antes (J.7.16).
        startRemoteOrphanCleanup()
        Task { await bootstrap() }
    }

    /// Al salir: corta el socket y el acceso remoto y cancela reviews, Responder, chats y el chat de instrucciones (el
    /// runner manda SIGTERM al grupo de procesos de cada uno). Se puede llamar más de una vez.
    func cancelEverythingForQuit() {
        stopCommandServer()
        stopRemoteAccess()
        reviews.cancelAll()
        respond.cancelAll()
        // A turn that was running stays `pending` in its record and reopens as "Interrupted" (spec B.9).
        chatScheduler.cancelAll()
        for chat in runningChats { chat.stop() }
        instructionsChat.stop()
    }

    /// Modo de capturas: herramientas y cuentas como si ya se hubieran encontrado, sin correr `gh` ni buscar nada.
    func applySnapshotState(tools: ResolvedTools, ghAccounts: [GHAccount], launchAtLogin: Bool) {
        self.tools = tools
        toolsResolved = true
        self.ghAccounts = ghAccounts
        accountsError = nil
        launchAtLoginEnabled = launchAtLogin
    }

    private func bootstrap() async {
        await resolveTools()
        activateReviewReactionsAtLaunch()
        await reloadAccounts()
        notifications?.requestAuthorization()
        prStore.start()
        // La versión nueva recién instalada borra la anterior y muestra "Updated to …" (spec D.3, paso 6).
        if let installed = updates.finishPendingInstall() { openUpdateWindow(.installed(installed)) }
        updates.startAutomaticChecks()
    }

    func resolveTools() async {
        let locator = ToolLocator(runner: runner)
        let overrides = configStore.config.toolPaths
        tools = ResolvedTools(
            gh: await locator.locate("gh", override: overrides.gh),
            git: await locator.locate("git", override: overrides.git),
            claude: await locator.locate("claude", override: overrides.claude)
        )
        accounts.ghPath = tools.gh
        toolsResolved = true
        rebuildSlackAPI()
        // La limpieza de huérfanos corre una vez, apenas hay git: al arrancar o, si no estaba, cuando el usuario
        // configura su ruta.
        startOrphanCleanup()
    }

    func reloadAccounts() async {
        do {
            ghAccounts = try await accounts.listAccounts()
            accountsError = nil
        } catch {
            ghAccounts = []
            accountsError = error.localizedDescription
        }
    }

    func updateConfig(refresh: Bool = true, _ mutate: (inout AppConfig) -> Void) {
        let runnersBefore = configStore.config.runners
        do {
            try configStore.update(mutate)
            runnersChanged(from: runnersBefore)
            settingsError = nil
            if refresh { Task { await prStore.refresh() } }
        } catch {
            settingsError = "Couldn’t save settings: \(error.localizedDescription)"
            AppLog.write(settingsError ?? "")
        }
    }

    func setSlackEnabled(_ enabled: Bool) {
        updateSlackConfig { $0.setSlackEnabled(enabled, now: Date()) }
    }

    /// Cambios de configuración de Slack (interruptor, canal, plantillas): se guardan y se vuelve a correr
    /// el plan con el último snapshot, así los issues no quedan viejos hasta el próximo refresco.
    func updateSlackConfig(_ mutate: (inout AppConfig) -> Void) {
        updateConfig(refresh: false, mutate)
        reprocessSlack()
    }

    /// Servidores MCP que el conector de Slack de Claude niega (spec §17.5), compartidos entre corridas.
    private let connectorServers = ConnectorServerList(url: ConnectorServerList.defaultURL)

    /// Arma la API de Slack del provider elegido: la Web API con el token, o el conector de Slack de Claude.
    func rebuildSlackAPI() {
        let provider = configStore.config.slack.provider
        let api: SlackAPI
        switch provider {
        case .userToken:
            api = SlackClient()
        case .claudeConnector:
            if let claude = tools.claude {
                let runner = ClaudeConnectorRunner(
                    runner: runner, claudePath: claude,
                    environment: ClaudeRunner.environment(toolPaths: [claude]),
                    workingDirectory: AppPaths.slackConnectorDir, logURL: AppPaths.slackConnectorLog,
                    servers: connectorServers
                )
                api = ClaudeConnectorSlackAPI(runner: runner)
            } else {
                api = UnavailableSlackAPI(error: toolsResolved ? .toolNotFound("claude") : .slack("connector_unavailable"))
            }
        }
        slack.use(api, provider: provider)
    }

    func setSlackProvider(_ provider: SlackProvider) {
        guard configStore.config.slack.provider != provider else { return }
        updateConfig(refresh: false) { $0.setSlackProvider(provider, now: Date()) }
        rebuildSlackAPI()
        reprocessSlack()
    }

    func setSlackToggle(_ toggle: SlackToggle, _ on: Bool) {
        updateSlackConfig { $0.setSlackToggle(toggle, on, now: Date()) }
    }

    /// Configs de antes de las reacciones (spec §17.2): con Slack encendido y conectado, las reacciones a reviews
    /// arrancan ahora, sin retroactividad.
    private func activateReviewReactionsAtLaunch() {
        let settings = configStore.config.slack
        guard settings.enabled, slack.isConnected, settings.reviewReactionsEnabledAt == nil,
              settings.anyReviewReactionEnabled else { return }
        updateConfig(refresh: false) { _ = $0.activateReviewReactionsIfNeeded(now: Date()) }
    }

    /// Guarda (o borra, con `nil`) el token de usuario. Un token nuevo donde no había corta el backlog.
    func saveSlackToken(_ token: String?) throws {
        if try slack.saveToken(token) {
            updateConfig(refresh: false) { $0.slackTokenAdded(now: Date()) }
        }
        reprocessSlack()
    }

    func reprocessSlack() {
        let snapshot = prStore.snapshot
        let config = configStore.config
        Task { await postings.track { await slack.reprocess(snapshot: snapshot, config: config) } }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            updateConfig(refresh: false) { $0.launchAtLogin = enabled }
        } catch {
            settingsError = "Couldn’t change the login item: \(error.localizedDescription)"
        }
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    func refreshNotificationPermission() async {
        notificationsDenied = await notifications?.isDenied() ?? false
    }

    /// Guarda la ruta personalizada de una herramienta (vacía = detectar sola) y vuelve a buscarlas todas.
    func setToolPath(_ path: String, for keyPath: WritableKeyPath<ToolPaths, String?>) async {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let value = trimmed.isEmpty ? nil : trimmed
        if configStore.config.toolPaths[keyPath: keyPath] != value {
            updateConfig(refresh: false) { $0.toolPaths[keyPath: keyPath] = value }
        }
        await resolveTools()
        await prStore.refresh()
    }

    func validateRepoPath(_ path: String, repo: RepoRef) async -> String? {
        guard let git = tools.git else { return PRBarError.toolNotFound("git").localizedDescription }
        return await RepoPathValidator.validate(path: path, repo: repo, runner: runner, gitPath: git)
    }

    // MARK: Reviews

    /// Spec §11: al arrancar se borran los worktrees y refs que haya dejado una ejecución anterior.
    /// Corre en su propia tarea para no demorar el primer refresco.
    private func startOrphanCleanup() {
        guard orphanCleanup == nil, let git = tools.git else { return }
        let repos = configStore.config.accounts.flatMap(\.repos).filter { !($0.localPath ?? "").isEmpty }
        let localPaths = Array(Set(repos.compactMap(\.localPath)))
        // Worktrees de Responder: en la carpeta de worktrees de cada repo (sin repetir clone + carpeta).
        var respondDirs: [(localPath: String, worktreeDir: String?)] = []
        for repo in repos {
            guard let localPath = repo.localPath else { continue }
            let dir = repo.worktreeDir?.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = (localPath, dir?.isEmpty == false ? dir : nil)
            if !respondDirs.contains(where: { $0.localPath == entry.0 && $0.worktreeDir == entry.1 }) { respondDirs.append(entry) }
        }
        let manager = WorktreeManager(runner: runner, gitPath: git)
        let legacy = WorktreeManager(runner: runner, gitPath: git, root: AppPaths.legacyWorktreesDir)
        let resolver = WorktreeResolver(runner: runner, gitPath: git)
        let respondOrphans = respondDirs
        // The folders kept for "Open in Terminal" (spec T.3) on this Mac stay, with their refs.
        let kept = Set(retainedWorktrees.filter { $0.location.runner == nil }.map(\.location.directory))
        orphanCleanup = Task.detached(priority: .utility) {
            for (localPath, worktreeDir) in respondOrphans {
                await resolver.cleanupOrphans(localPath: localPath, worktreeDir: worktreeDir, keeping: kept)
            }
            // Después: borra las refs `refs/prbar/*` que queden y las carpetas de contexto (`*.respond-context`).
            await manager.cleanupOrphans(localPaths: localPaths, keeping: kept)
            await legacy.cleanupOrphans(localPaths: localPaths, keeping: kept)
        }
        retrySupersededRetained()
    }

    func startReview(_ item: ClassifiedPR) {
        // The button is disabled while an update installs (`jobsBlockedReason`); nothing new starts.
        guard jobsBlockedReason == nil else { return }
        guard toolsResolved else {
            reviews.markFailed(prID: item.id, message: "Still looking for git and claude. Try again in a few seconds.")
            return
        }
        // Un repo que corre en un host no necesita claude en esta Mac (sí git: el diff y el chat lo usan acá).
        if let missing = missingLocalTool(account: item.account, repo: item.pr.repo) {
            reviews.markFailed(prID: item.id, message: PRBarError.toolNotFound(missing).localizedDescription)
            return
        }
        // Un review anterior terminado (failed/ready/published) se reemplaza por el nuevo. Un `ready` sin publicar
        // queda `abandoned` en el historial: ya no se puede reabrir para publicar.
        if case .ready(let previous)? = reviews.phases[item.id] {
            discardChat(draftID: previous.id)
            do {
                try history.markAbandoned(id: previous.id)
            } catch {
                AppLog.write("History: couldn't mark the review of \(item.pr.repo.fullName)#\(item.pr.number) as abandoned: \(error)")
            }
            historyRevision += 1
        }
        reviews.dismiss(prID: item.id)
        reviewRuns[item.id] = ClaudeRunInfo(startedAt: Date(), requestedOnPhone: CommandOrigin.current.isPhone)
        let ignorePaths = repoConfig(account: item.account, repo: item.pr.repo)?.ignorePaths ?? []
        reviews.enqueue(ReviewRequest(item: item, localPath: localPath(for: item), baseRef: item.pr.baseRef,
                                      ignorePaths: ignorePaths))
        // 👀 en el mensaje del PR en Slack (spec §17.2); no bloquea la review y sus errores van a los issues de Slack.
        let config = configStore.config
        Task { await postings.track { await slack.reviewStarted(item: item, config: config) } }
    }

    func cancelReview(prID: String) {
        reviews.cancel(prID: prID)
        reviewRuns[prID] = nil
    }

    /// Descarta el review del PR. Uno listo sin publicar queda `abandoned` en el historial (como al reemplazarlo en
    /// `startReview`): ahora también lo puede descartar la CLI (`prbar review dismiss`).
    func dismissReview(prID: String) {
        if case .ready(let draft)? = reviews.phases[prID] {
            discardChat(draftID: draft.id)
            do {
                try history.markAbandoned(id: draft.id)
            } catch {
                AppLog.write("History: couldn't mark the review of \(prID) as abandoned: \(error)")
            }
            historyRevision += 1
        }
        reviews.dismiss(prID: prID)
    }

    /// `localPath` del repo del item en la config de su cuenta (`nil` = review solo con el diff).
    func localPath(for item: ClassifiedPR) -> String? {
        localPath(account: item.account, repo: item.pr.repo)
    }

    func localPath(account: String, repo: RepoRef) -> String? {
        guard let path = repoConfig(account: account, repo: repo)?.localPath, !path.isEmpty else { return nil }
        return path
    }

    func repoConfig(account: String, repo: RepoRef) -> RepoConfig? {
        configStore.config.repoConfig(account: account, repo: repo)
    }

    private func reviewFinished(_ request: ReviewRequest, _ result: Result<ReviewDraft, Error>) {
        resources.jobFinished()
        let item = request.item
        let run = reviewRuns.removeValue(forKey: item.id)
        let startedAt = run?.startedAt ?? Date()
        var record: ReviewRecord
        switch result {
        case .success(let draft):
            record = ReviewRecord(draft: draft, startedAt: startedAt, finishedAt: Date(), status: .ready,
                                  sessions: draft.sessions.isEmpty ? nil : draft.sessions)
            if let location = draft.retainedLocation {
                retain(RetainedWorktree(prID: item.id, account: item.account, repo: item.pr.repo, number: item.pr.number,
                                        job: .review, recordID: draft.id, location: location, sessions: draft.sessions,
                                        retainedAt: Date()))
            }
        case .failure(let error):
            var draft = ReviewDraft(
                prID: item.id, repo: item.pr.repo, number: item.pr.number, title: item.pr.title, url: item.pr.url,
                author: item.pr.author, headOid: item.pr.headOid, account: item.account, summary: "", items: []
            )
            // El log de Claude se nombra con el id del draft que iba a salir: se reusa para que el
            // historial (`history.logURL(for: record.id)`) apunte al log real.
            if let logURL = (error as? ReviewFailure)?.logURL,
               let id = UUID(uuidString: logURL.deletingPathExtension().lastPathComponent) {
                draft.id = id
            }
            record = ReviewRecord(
                draft: draft, startedAt: startedAt, finishedAt: Date(), status: .failed, errorMessage: error.localizedDescription
            )
            if let sessions = (error as? ReviewFailure)?.sessions, !sessions.isEmpty { record.sessions = sessions }
        }
        if run?.requestedOnPhone == true { record.requestedOnPhone = true }
        do {
            try history.save(record)
        } catch {
            AppLog.write("History: couldn't save the review of \(item.pr.repo.fullName)#\(item.pr.number): \(error)")
        }
        historyRevision += 1

        let keptCount: Int? = if case .success(let draft) = result { draft.keptCount } else { nil }
        if let notification = NotificationPlanner.reviewFinished(
            prID: item.id, repo: item.pr.repo, number: item.pr.number, keptCount: keptCount, recordID: record.id,
            settings: configStore.config.notifications
        ) {
            notifications?.deliver([notification])
        }
    }

    /// La pestaña Review del PR en la ventana principal (spec M.4): muestra lo que haya (Start Review, el progreso, el
    /// editor o la review publicada).
    func openReview(prID: String) {
        navigate(to: .pr(prID: prID, tab: .review))
    }

    /// El último registro publicado del PR (la pestaña Review de un PR con la review ya publicada).
    /// Called from view bodies: reads an in-memory index, not the history folder.
    func publishedReviewRecord(prID: String) -> ReviewRecord? {
        if let publishedReviewIndex { return publishedReviewIndex.record(prID: prID) }
        let index = PublishedReviewIndex(records: history.all())
        publishedReviewIndex = index
        return index.record(prID: prID)
    }

    /// Publica la review en GitHub (spec §8.7). Si algo falla se lanza el error y no se toca nada:
    /// la ventana conserva la selección y lo editado para reintentar.
    ///
    /// Con `allInBody`, o si el PR cambió desde la review (el diff actual no es el que vio Claude), todos los
    /// hallazgos van al body. Si GitHub rechaza con 422 una review con comentarios inline se lanza
    /// `InlineCommentsRejected`, para ofrecer reintentar con `allInBody`.
    func publish(
        draft: ReviewDraft, selected: [SelectedComment], general: String, event: ReviewEvent, allInBody: Bool = false,
        userDiscarded: [ReviewItem] = []
    ) async throws -> PublishedReview {
        try await postings.track {
            try await publishNow(draft: draft, selected: selected, general: general, event: event, allInBody: allInBody,
                                 userDiscarded: userDiscarded)
        }
    }

    /// Publica lo elegido en la ventana de Review (o con `prbar review …`): el `reviewEdits` del coordinador del draft.
    /// `only`: ids de hallazgos a publicar en vez de la selección (sin cambiarla); `withComments: false` publica solo
    /// el veredicto (y no cuenta como descartar hallazgos, spec E.4). Si el PR cambió desde la review, todo va al
    /// cuerpo. Mientras publica, el chat queda bloqueado; después, de solo lectura (spec B.2). La publicación corre en
    /// su propia `Task`: si quien la pidió se va (la CLI se desconecta), no se corta a la mitad. Si ya se está
    /// publicando el mismo draft (la ventana y `prbar` a la vez), falla sin publicar (`publishingReviews`).
    func publishReview(draft: ReviewDraft, event: ReviewEvent, only: Set<String>? = nil, withComments: Bool = true,
                       allInBody: Bool = false) async throws -> PublishedReview {
        let chat = reviewChat(for: draft)
        let edits = chat.reviewEdits
        let comments = withComments ? edits.comments(of: draft, only: only) : []
        let general = withComments ? edits.generalComment : ""
        // Lo que el usuario eligió no publicar: los que mantuvo el filtro, no ocultos y fuera de lo publicado.
        let discarded: [ReviewItem] = if !withComments {
            []
        } else if let only {
            draft.items.filter { $0.keep && !$0.isHidden && !only.contains($0.id) }
        } else {
            edits.userDiscarded(of: draft)
        }
        let result = try await publishingReviews.run(
            draft.id, busy: CommandFailure(.invalidState, "This review is already being posted.")
        ) {
            chat.setLock("Posting the review…")
            defer { chat.setLock(nil) }
            return try await Task { @MainActor in
                try await self.publish(draft: draft, selected: comments, general: general, event: event,
                                       allInBody: allInBody || self.isOutdated(draft), userDiscarded: discarded)
            }.value
        }
        publishedReviews[draft.id] = result
        chat.markReadOnly()
        return result
    }

    private func publishNow(
        draft: ReviewDraft, selected: [SelectedComment], general: String, event: ReviewEvent, allInBody: Bool,
        userDiscarded: [ReviewItem]
    ) async throws -> PublishedReview {
        let token = try await accounts.token(for: draft.account)
        let lineMap: DiffLineMap
        if allInBody || isOutdated(draft) {
            lineMap = DiffLineMap(files: [])
        } else {
            lineMap = DiffLineMap(files: try await api.pullRequestFiles(repo: draft.repo, number: draft.number, token: token))
        }
        let submission = try ReviewPublisher.build(
            draft: draft, selected: selected, generalComment: general, event: event, lineMap: lineMap
        )
        let url: URL
        do {
            url = try await api.submitReview(repo: draft.repo, number: draft.number, submission: submission, token: token)
        } catch where ReviewPublisher.canRetryInBody(after: error, submission: submission) {
            throw InlineCommentsRejected(underlying: error)
        }
        // The head now, not the draft's: a review posted from an outdated draft is still the current one until
        // another commit arrives.
        reviews.markPublished(prID: draft.prID, url: url, headOid: currentItem(draft.prID)?.pr.headOid ?? draft.headOid)

        // La review ya está en GitHub: de acá en adelante un error solo se loguea.
        let now = Date()
        let texts = selected.compactMap { comment -> (String, String)? in
            let text = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (comment.finding.id, text)
        }
        let generalText = general.trimmingCharacters(in: .whitespacesAndNewlines)
        var record = history.record(id: draft.id) ?? ReviewRecord(draft: draft, startedAt: now, status: .ready)
        record.status = .published
        record.published = Dictionary(texts, uniquingKeysWith: { first, _ in first })
        record.generalComment = generalText.isEmpty ? nil : generalText
        record.action = ReviewRecord.Action(event)
        record.reviewURL = url
        record.finishedAt = now
        do {
            try history.save(record)
        } catch {
            AppLog.write("History: couldn't save the posting of \(draft.repo.fullName)#\(draft.number): \(error)")
        }
        // Bumping the revision drops the index; the one we had stays valid with this record added.
        var index = publishedReviewIndex
        historyRevision += 1
        index?.note(record)
        publishedReviewIndex = index
        // Spec E.4: what the user chose not to post feeds the suggestions. Never blocks the post.
        if !userDiscarded.isEmpty {
            do {
                try discardStats.record(items: userDiscarded, draft: draft, now: now)
                discardRevision += 1
            } catch {
                AppLog.write("Couldn't save the discarded findings of \(draft.repo.fullName)#\(draft.number): \(error)")
            }
        }
        Task { await prStore.refresh() }
        return PublishedReview(url: url, action: record.action, submission: submission, commentCount: texts.count, publishedAt: now)
    }

    /// `true` si el PR recibió commits después de la review (según el último snapshot).
    func isOutdated(_ draft: ReviewDraft) -> Bool {
        guard let current = prStore.snapshot?.items.first(where: { $0.id == draft.prID }) else { return false }
        return current.pr.headOid != draft.headOid
    }

    /// History en la ventana principal (spec M.4); con `selecting`, ese registro elegido.
    func openHistory(selecting recordID: UUID? = nil) {
        navigate(to: .history(recordID: recordID))
    }

    /// "Abrir para publicar" desde el historial: vuelve a dejar el draft listo y abre su ventana de Review.
    func reopenFromHistory(_ draft: ReviewDraft) {
        reviews.restore(draft)
        openReview(prID: draft.prID)
    }

    // MARK: Chat

    var chatEnabled: Bool { configStore.config.claude.chatEnabled }

    /// Why a chat that runs on this Mac (the instructions chat) can't run, with the same reasons as the Review
    /// button; nil = it can.
    var chatUnavailableReason: String? { chatUnavailableReason(runsOnHost: false) }

    /// The same for a PR chat: one that runs on a host (spec J) doesn't need claude on this Mac, only git.
    func chatUnavailableReason(for chat: ChatCoordinator) -> String? {
        chatUnavailableReason(runsOnHost: chatHost(chat) != nil)
    }

    private func chatUnavailableReason(runsOnHost: Bool) -> String? {
        if let jobsBlockedReason { return jobsBlockedReason }
        guard toolsResolved else { return "Still looking for git and claude. Try again in a few seconds." }
        if let missing = LocalTools.missing(git: tools.git, claude: tools.claude, runsOnHost: runsOnHost) {
            return PRBarError.toolNotFound(missing).localizedDescription
        }
        return nil
    }

    private func currentPR(_ prID: String) -> PullRequest? {
        prStore.snapshot?.items.first { $0.id == prID }?.pr
    }

    /// The Review window's coordinator. The conversation and the edits come from history (they're saved on each turn).
    /// El chat de un draft si ya existe (sin crearlo): el ⌘Z de la pestaña.
    func existingChat(draftID: UUID) -> ChatCoordinator? { chats[draftID] }

    func reviewChat(for draft: ReviewDraft) -> ChatCoordinator {
        if let chat = chats[draft.id] { return chat }
        let stored = history.record(id: draft.id)?.draft ?? draft
        let history = self.history
        let chat = ChatCoordinator(
            subject: .review(draft), session: stored.chat ?? ChatSession(prID: draft.prID, kind: .review),
            reviewEdits: stored.edits, backend: chatBackend, scheduler: chatScheduler,
            context: { [weak self] in
                ChatContext(pr: self?.currentPR(draft.prID), localPath: self?.localPath(account: draft.account, repo: draft.repo),
                            respondResult: nil, canEditFiles: false, logURL: history.logURL(for: draft.id),
                            rules: self?.instructions.rules ?? [],
                            promptBody: self?.configStore.config.claude.chatPromptBody(.reviewChat))
            },
            hooks: ChatHooks(persist: { [weak self] chat in self?.saveReviewChat(draft, chat) },
                             saveRule: { [weak self] proposal in
                                 guard let self else { throw RuleError.unavailable }
                                 return try self.saveProposedRule(proposal)
                             })
        )
        chats[draft.id] = chat
        watchChatForPhones(chat, prID: draft.prID)
        return chat
    }

    private func saveReviewChat(_ draft: ReviewDraft, _ chat: ChatCoordinator) {
        guard var record = history.record(id: draft.id) else { return }
        record.draft.chat = chat.session
        record.draft.edits = chat.reviewEdits
        do {
            try history.save(record)
        } catch {
            AppLog.write("History: couldn't save the chat of \(draft.repo.fullName)#\(draft.number): \(error)")
        }
        historyRevision += 1
    }

    /// Los chats (Review o Respond) con un turno corriendo o en cola: cuentan como trabajos al actualizar (spec D.3).
    var runningChats: [ChatCoordinator] {
        (Array(chats.values) + mergeSessions.values.compactMap(\.chat) + retiringChats.values).filter(\.isRunning)
    }

    /// The chat's worktree goes away with its review or respond (spec B.5). A running turn is stopped first (M9); until
    /// it really ends the chat stays in `retiringChats`, so quitting, updating and Activity still see it.
    func discardChat(draftID: UUID) {
        retiringChats = retiringChats.filter { $0.value.isRunning }
        guard let chat = chats.removeValue(forKey: draftID) else { return }
        remoteChatWatchers[chat.session.id] = nil
        if chat.isRunning { retiringChats[draftID] = chat }
        chat.discard()
    }

    /// The Respond window's coordinator: the decisions start as saved (or Claude's), and the conversation comes from
    /// the record.
    func respondChat(for draft: RespondDraft) -> ChatCoordinator {
        if let chat = chats[draft.id] { return chat }
        let prID = draft.prID
        let record = respond.records[prID].flatMap { $0.id == draft.id ? $0 : nil }
        let saved = record?.selections ?? [:]
        let selections = Dictionary(uniqueKeysWithValues: draft.items.map { item in
            (item.id, saved[item.id] ?? RespondSelection.defaults(for: item))
        })
        let logURL = respondHistory.logURL(for: draft.id)
        let chat = ChatCoordinator(
            subject: .respond(draft), session: record?.chat ?? ChatSession(prID: prID, kind: .respond),
            selections: selections, backend: chatBackend, scheduler: chatScheduler,
            context: { [weak self] in
                self?.respondChatContext(draft)
                    ?? ChatContext(pr: nil, localPath: nil, respondResult: nil, canEditFiles: false, logURL: logURL)
            },
            hooks: ChatHooks(
                persist: { [weak self] chat in
                    self?.respond.setChat(prID: prID, draftID: draft.id, chat: chat.session)
                    self?.respond.updateSelections(prID: prID, draftID: draft.id, selections: chat.selections)
                },
                runningChanged: { [weak self] running in self?.respond.setChatRunning(running, prID: prID) },
                resultChanged: { [weak self] result in self?.respond.replaceResult(prID: prID, draftID: draft.id, result: result) },
                saveRule: { [weak self] proposal in
                    guard let self else { throw RuleError.unavailable }
                    return try self.saveProposedRule(proposal)
                }
            )
        )
        chats[draft.id] = chat
        watchChatForPhones(chat, prID: prID)
        return chat
    }

    /// Claude may edit the worktree only in `readyToPush` (after implementing, before pushing): PRBar commits what it
    /// changes and the diff above Push shows it (plan decision 6).
    private func respondChatContext(_ draft: RespondDraft) -> ChatContext {
        let record = respond.records[draft.prID].flatMap { $0.id == draft.id ? $0 : nil }
        var canEditFiles = false
        if case .readyToPush(let current, _)? = respond.phases[draft.prID], current.id == draft.id, record?.pushed != true {
            canEditFiles = true
        }
        return ChatContext(pr: currentPR(draft.prID), localPath: draft.worktree.localPath, respondResult: record?.result,
                           canEditFiles: canEditFiles, logURL: respondHistory.logURL(for: draft.id),
                           rules: instructions.rules, promptBody: configStore.config.claude.chatPromptBody(.respondChat))
    }

    // MARK: Instructions

    /// The repos of the enabled accounts (`owner/name`), sorted. Rules can only be for one of these.
    var configuredRepos: [String] {
        var repos: [String] = []
        for repo in configStore.config.accounts.filter(\.enabled).flatMap(\.repos) where !repos.contains(repo.id) {
            repos.append(repo.id)
        }
        return repos.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var rules: [Rule] { instructions.rules }

    /// The suggestions to show (spec E.4); with `repo`, only those that apply to it (its own and the global ones).
    func ruleSuggestions(for repo: RepoRef? = nil) -> [RuleSuggestion] {
        let all = RuleSuggestions.compute(events: discardStats.all(), rules: instructions.rules,
                                          decisions: instructions.file.suggestionDecisions, configuredRepos: configuredRepos)
        guard let repo else { return all }
        return all.filter { $0.scope.covers(repo) }
    }

    /// "Create Rule": a rule for Review with `text` (the proposed one if nil), remembering its category.
    @discardableResult
    func acceptSuggestion(_ id: String, text: String? = nil) throws -> Rule {
        guard let suggestion = ruleSuggestions().first(where: { $0.id == id }) else { throw RuleError.notFound }
        return try addRule(text ?? suggestion.text, scope: suggestion.scope, appliesTo: [.review], source: .suggestion,
                           category: suggestion.category)
    }

    /// "Not Now": hides it for 30 days.
    func snoozeSuggestion(_ id: String) throws {
        try instructions.decideSuggestion(id, never: false, until: Date().addingTimeInterval(RuleSuggestions.snooze))
    }

    /// "Never".
    func neverSuggest(_ id: String) throws {
        try instructions.decideSuggestion(id, never: true, until: nil)
    }

    /// A rule Claude proposed in a PR chat, saved because the user pressed Save (spec E.3).
    func saveProposedRule(_ proposal: RuleProposal) throws -> UUID {
        try addRule(proposal.text, scope: proposal.scope, appliesTo: proposal.appliesTo, source: .prChat).id
    }

    @discardableResult
    func addRule(_ text: String, scope: RuleScope, appliesTo: Set<RuleStage>, source: RuleSource = .manual,
                 category: FindingCategory? = nil) throws -> Rule {
        try instructions.addRule(text, scope: try configuredScope(scope), appliesTo: appliesTo, source: source, category: category)
    }

    func editRule(_ id: UUID, text: String? = nil, scope: RuleScope? = nil, appliesTo: Set<RuleStage>? = nil) throws {
        try instructions.editRule(id, text: text, scope: try scope.map(configuredScope), appliesTo: appliesTo)
    }

    func removeRule(_ id: UUID) throws {
        try instructions.removeRule(id)
    }

    func setRuleEnabled(_ id: UUID, _ enabled: Bool) throws {
        try instructions.setRuleEnabled(id, enabled)
    }

    /// A repo scope must be a configured repo; it's saved with the configured name.
    private func configuredScope(_ scope: RuleScope) throws -> RuleScope {
        guard case .repo(let name) = scope else { return scope }
        guard let match = configuredRepos.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw RuleError.unknownRepo(name)
        }
        return .repo(match)
    }

    // MARK: Responder

    /// Por qué no se puede responder el feedback de este PR (`nil` = se puede).
    func respondUnavailableReason(_ item: ClassifiedPR) -> String? {
        if let jobsBlockedReason { return jobsBlockedReason }
        // Un repo que corre en un host no necesita carpeta local: el análisis arma su worktree allá (spec J).
        return localPath(for: item) == nil && runnerDestination(account: item.account, repo: item.pr.repo) == nil
            ? "Choose the local folder for \(item.pr.repo.name) in Settings → Repos to respond with Claude."
            : nil
    }

    /// Analiza el feedback sin resolver del PR (spec §14). Un registro anterior terminado (listo, publicado o
    /// fallido) se reemplaza, con su worktree y su chat; uno con trabajo sin pushear no (la cola lo ignora).
    func startRespond(_ item: ClassifiedPR) {
        guard respondUnavailableReason(item) == nil, respondSlotConflictReason(item.id, starting: .feedback) == nil else { return }
        let localPath = localPath(for: item)
        let worktreeDir = repoConfig(account: item.account, repo: item.pr.repo)?.worktreeDir
        let previous = respond.records[item.id]?.draft
        // La corrida anterior se reemplaza: su chat se va con su worktree (M5).
        if respond.analyze(item, localPath: localPath, worktreeDir: worktreeDir), let previous {
            discardChat(draftID: previous.id)
        }
    }

    func cancelRespond(prID: String) {
        respond.cancel(prID: prID)
    }

    /// "Dismiss" de la fila: con trabajo sin pushear pregunta antes de borrarlo (M11).
    func confirmDismissRespond(prID: String) {
        guard respond.unpushedWork.contains(prID) else { return dismissRespond(prID: prID) }
        if confirmFromPopover(title: RespondDiscardCopy.title,
                              message: RespondDiscardCopy.message(worktree: respond.records[prID]?.draft.worktree.path),
                              action: "Discard") {
            dismissRespond(prID: prID)
        }
    }

    /// Una confirmación pedida desde el panel (que está a nivel de menú y taparía la alerta, y se cierra con cualquier
    /// clic afuera): se cierra el panel y la alerta va al frente, en el Space del usuario, como la de salir.
    func confirmFromPopover(title: String, message: String, action: String) -> Bool {
        closePopover?()
        NSApp.activate()
        let alert = ConfirmAlert.make(title: title, message: message, action: action)
        alert.window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        return ConfirmAlert.confirmed(alert.runModal())
    }

    /// "Analyze Again" / "Fix CI Again" con trabajo sin pushear: pregunta, lo descarta y vuelve a empezar.
    func discardAndRestartRespond(_ item: ClassifiedPR, mode: RespondMode) {
        let restart = { [weak self] in
            guard let self else { return }
            if self.respond.unpushedWork.contains(item.id) {
                if let draft = self.respond.records[item.id]?.draft { self.discardChat(draftID: draft.id) }
                self.respond.dismiss(prID: item.id)
            }
            if mode == .ciFix { self.startCIFix(item) } else { self.startRespond(item) }
        }
        guard respond.unpushedWork.contains(item.id) else { return restart() }
        ConfirmAlert.present(title: RespondDiscardCopy.title,
                             message: RespondDiscardCopy.message(worktree: respond.records[item.id]?.draft.worktree.path),
                             action: "Discard and Start Over", perform: restart)
    }

    func dismissRespond(prID: String) {
        if let draft = respond.records[prID]?.draft { discardChat(draftID: draft.id) }
        respond.dismiss(prID: prID)
        respondTimelines[prID] = nil
    }

    /// Anota en el reloj de etapas de cada PR su fase de ahora. Una corrida nueva (vuelve a analizar después de haber
    /// terminado de analizar) empieza un reloj nuevo.
    private func noteRespondStages(_ phases: [String: RespondPhase], runningTests: Set<String>, now: Date = Date()) {
        var timelines = respondTimelines
        for prID in Set(phases.keys).union(runningTests) {
            var timeline = timelines[prID] ?? RespondStageTimeline()
            switch phases[prID] {
            case .queued?, .preparing?, .analyzing?:
                // "Queued to post…" (ya con resultado) no es una corrida nueva.
                if timeline.ends[.analyzing] != nil, respond.records[prID]?.result == nil { timeline = RespondStageTimeline() }
            default: break
            }
            timeline.note(phase: phases[prID], runningTests: runningTests.contains(prID), at: now)
            timelines[prID] = timeline
        }
        if timelines != respondTimelines { respondTimelines = timelines }
    }

    /// Lo elegido para el análisis `draft` (ventana, chat o CLI): las `selections` de su coordinador.
    func respondSelections(for draft: RespondDraft) -> [String: RespondSelection] {
        respondChat(for: draft).selections
    }

    func updateRespondSelection(_ draft: RespondDraft, itemID: String, _ mutate: (inout RespondSelection) -> Void) {
        guard let item = draft.items.first(where: { $0.id == itemID }) else { return }
        let chat = respondChat(for: draft)
        var selection = chat.selections[itemID] ?? RespondSelection.defaults(for: item)
        mutate(&selection)
        chat.selections[itemID] = selection
    }

    /// "Reset to Claude’s Suggestions".
    func resetRespondSelections(_ draft: RespondDraft) {
        respondChat(for: draft).selections = Dictionary(uniqueKeysWithValues: draft.items.map {
            ($0.id, RespondSelection.defaults(for: $0))
        })
    }

    /// "Post N Replies" sin fixes (ventana) o `prbar respond reply-only`.
    func publishRespondReplies(prID: String) {
        guard let draft = respond.records[prID]?.draft else { return }
        respond.publishRepliesOnly(prID: prID, selections: respondSelections(for: draft))
    }

    /// El `testCommand` del repo del draft (`nil` = sin botón "Correr tests").
    func testCommand(for draft: RespondDraft) -> String? {
        repoConfig(account: draft.account, repo: draft.repo)?.testCommand
    }

    /// Corre los tests del repo en el worktree. Solo desde la ventana, cuando el usuario lo pide después del diff.
    func runRespondTests(prID: String) {
        guard jobsBlockedReason == nil, let draft = respond.records[prID]?.draft, let command = testCommand(for: draft) else { return }
        respond.runTests(prID: prID, testCommand: command)
    }

    /// What "Push and Reply" would do now (spec E.5).
    func respondPushGate(prID: String) -> RespondPushGate {
        guard let record = respond.records[prID], let result = record.result else { return .ready }
        return RespondPushGate.evaluate(result: result, testCommand: testCommand(for: record.draft),
                                        runTestsBeforePush: configStore.config.claude.respond.runTestsBeforePush,
                                        pushed: record.pushed)
    }

    /// Push and reply, running the tests first if the settings ask for it. Returns what it did: `.testsFailed` means it
    /// didn't push (the window offers "Push Anyway", which calls this with `ignoringFailedTests`).
    @discardableResult
    /// Throws if the tests that must run first can't start now (a chat turn or another job on the PR): nothing is
    /// pushed, and the window says so.
    /// `ignoringFailedTests`: "Push Anyway", which for a Fix CI also pushes when its failing checks pass now (spec K.6.6).
    func pushRespond(prID: String, ignoringFailedTests: Bool = false) throws -> RespondPushGate {
        let gate = respondPushGate(prID: prID)
        switch gate {
        case .ready:
            respond.publish(prID: prID, ignoringCI: ignoringFailedTests)
        case .runTests:
            guard let draft = respond.records[prID]?.draft, let command = testCommand(for: draft),
                  respond.pushAfterTests(prID: prID, testCommand: command) else {
                throw PRBarError.respond(RespondCopy.testsDidNotStart)
            }
        case .testsFailed:
            if ignoringFailedTests { respond.publish(prID: prID, ignoringCI: true) }
        }
        return gate
    }

    /// Abre el Respond o el Fix CI del PR en su pestaña de la ventana principal (spec M.4).
    func openRespond(prID: String) {
        navigate(to: .pr(prID: prID, tab: respond.mode(of: prID) == .ciFix ? .fixCI : .respond))
    }

    /// Cada etapa terminada de `RespondQueue`: recarga el historial, avisa y, si se publicó, refresca los PRs.
    private func respondEvent(prID: String, phase: RespondPhase) {
        historyRevision += 1
        if !phase.isActive { resources.jobFinished() }
        let draft = respond.records[prID]?.draft
        let event: NotificationPlanner.RespondEvent?
        let isCI = respond.mode(of: prID) == .ciFix
        switch phase {
        // Fix CI (spec K.6.7): nothing to choose in `ready` (the fix starts on its own).
        case .ready where isCI:
            event = nil
        case .readyToPush where isCI && respond.isReportingCIBlock(prID):
            event = .ciFixNotPushed
        case .readyToPush(_, let result) where isCI:
            event = result.tests == nil ? .ciFixReady(commits: RespondCounts.commits(result)) : nil
        case .done where isCI:
            event = .ciFixPushed
            Task { await prStore.refresh() }
        case .failed where isCI:
            event = .ciFixFailed
        case .ready(let ready):
            event = .analysisReady(count: ready.items.count)
        case .readyToPush(_, let result):
            // Con tests es el resultado de "Correr tests", que el usuario pidió con la ventana abierta.
            event = result.tests == nil ? .fixesReady(commits: RespondCounts.commits(result)) : nil
        case .done(let record):
            event = .published(replies: record.posted.count, pushed: record.pushed && (record.result.map(RespondCounts.commits) ?? 0) > 0)
            Task { await prStore.refresh() }
        case .failed:
            event = .failed
        default:
            event = nil
        }
        guard let event else { return }
        let ref = draft.map { ($0.repo, $0.number) }
            ?? prStore.snapshot?.items.first { $0.id == prID }.map { ($0.pr.repo, $0.pr.number) }
        guard let (repo, number) = ref, let notification = NotificationPlanner.respondFinished(
            prID: prID, repo: repo, number: number, event: event, settings: configStore.config.notifications
        ) else { return }
        notifications?.deliver([notification])
    }

    func openSettings() {
        WindowPresenter.shared.present(
            id: "settings", title: "Settings", size: SettingsWindow.savedTab.contentSize,
            options: WindowOptions(
                autosaveName: "SettingsWindow", miniaturizable: false, resizable: true, allowsTabbing: false, kind: .utility,
                toolbarStyle: .preference, minContentSize: SettingsWindow.minContentSize,
                maxContentSize: SettingsWindow.maxContentSize
            )
        ) {
            SettingsWindow.makeController(model: self)
        }
    }
}

/// La API de Slack mientras no se puede usar el conector de Claude (p. ej. no se encontró `claude`).
private struct UnavailableSlackAPI: SlackAPI {
    let error: PRBarError

    func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String { throw error }
    func authTest(token: String) async throws -> SlackIdentity { throw error }
    func channels(token: String) async throws -> SlackChannelList { throw error }
    func history(channel: String, oldest: Date, token: String) async throws -> [SlackMessage] { throw error }
    func threadReplies(channel: String, ts: String, token: String) async throws -> [SlackMessage] { throw error }
    func addReaction(channel: String, ts: String, name: String, token: String) async throws { throw error }
}
